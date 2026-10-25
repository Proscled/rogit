--!strict
-- RoGit Studio plugin. Talks to `rogit serve` on this computer, like the Rojo plugin talks to `rojo serve`.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local ReflectionService = game:GetService("ReflectionService")
local RunService = game:GetService("RunService")
local SerializationService = game:GetService("SerializationService")

if not RunService:IsEdit() then
	return
end

local BASE = "http://127.0.0.1:34875"
local TAG = "RoGitId"
local POLL_SECONDS = 2
-- rogit serve stores each part at part * 3 MiB, so parts must be exactly 4 MiB of base64.
local PART_CHARS = 4 * 1024 * 1024
-- Services whose contents are saved in place files. RoGit only looks inside these.
local SERVICES = {
	"Workspace", "Lighting", "MaterialService", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService",
	"ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "TextChatService",
	"Chat", "LocalizationService", "TestService", "SocialService", "VoiceChatService",
}

type Game = { name: string, universe_id: number, main_place_id: number }
type Branch = { name: string, created: number, has_starting_point: boolean }
type State = {
	connected: boolean,
	folder: string?,
	game: Game?,
	rojo: any,
	branches: { Branch },
	branch: Branch?,
	isMain: boolean?,
	experience: string?,
	busy: string?,
	notice: string?,
	problem: string?,
}

local state: State = { connected = false, branches = {} }

-- Talking to rogit serve ---------------------------------------------------------------------------

local function request(method: string, path: string, body: any?, raw: string?): (boolean, any)
	local options: any = { Url = BASE .. path, Method = method }
	if raw ~= nil then
		options.Body = raw
		options.Headers = { ["Content-Type"] = "text/plain" }
	elseif body ~= nil then
		options.Body = HttpService:JSONEncode(body)
		options.Headers = { ["Content-Type"] = "application/json" }
	end
	local ok, response = pcall(HttpService.RequestAsync, HttpService, options)
	if not ok then
		return false, nil
	end
	local decoded, value = pcall(HttpService.JSONDecode, HttpService, response.Body)
	if not decoded then
		return false, "rogit serve sent an unexpected reply."
	end
	if not response.Success then
		return false, value.error or ("rogit serve answered HTTP " .. response.StatusCode .. ".")
	end
	return true, value
end

-- IDs ----------------------------------------------------------------------------------------------

local ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local random = Random.new()

local function newId(length: number): string
	local chars = table.create(length)
	for i = 1, length do
		local n = random:NextInteger(1, #ID_CHARS)
		chars[i] = string.sub(ID_CHARS, n, n)
	end
	return table.concat(chars)
end

-- Collects the objects RoGit tracks: everything saved in the place except scripts, Folders that
-- contain a script anywhere inside, and whatever Rojo syncs.
local function trackedObjects(rojoPaths: { [string]: boolean }): ({ Instance }, number)
	local list: { Instance } = {}
	local visited = 0

	local function visit(parent: Instance, path: string): boolean
		local hasScript = false
		for _, child in parent:GetChildren() do
			visited += 1
			if visited % 10000 == 0 then
				task.wait()
			end
			local childPath = path .. "/" .. child.Name
			if child:IsA("LuaSourceContainer") then
				hasScript = true
			elseif child.Archivable and not rojoPaths[childPath] then
				local mark = #list
				table.insert(list, child)
				if visit(child, childPath) then
					hasScript = true
					if child:IsA("Folder") then
						for i = #list, mark + 1, -1 do
							list[i] = nil
						end
					end
				end
			end
		end
		return hasScript
	end

	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service and not rojoPaths[service.Name] then
			visit(service, service.Name)
		end
	end
	return list, visited
end

-- Gives every tracked object without an ID a short hidden one. Copies made with Ctrl+D share an ID, so
-- repeats get a new one. Records a single undo step, and only when something changes.
local function tagObjects(rojo: any): { tagged: number, added: number, skipped: number, seconds: number }
	local started = os.clock()
	if rojo == nil or rojo.all then
		return { tagged = 0, added = 0, skipped = 0, seconds = 0 }
	end
	local rojoPaths: { [string]: boolean } = {}
	for _, path in rojo.paths do
		rojoPaths[path] = true
	end
	local objects, visited = trackedObjects(rojoPaths)
	local seen: { [string]: boolean } = {}
	local missing: { Instance } = {}
	for _, object in objects do
		local id = object:GetAttribute(TAG)
		if type(id) == "string" and id ~= "" and not seen[id] then
			seen[id] = true
		else
			table.insert(missing, object)
		end
	end
	local added = 0
	if #missing > 0 then
		local recording = ChangeHistoryService:TryBeginRecording("RoGitTags", "RoGit IDs")
		for _, object in missing do
			if pcall(object.SetAttribute, object, TAG, newId(10)) then
				added += 1
			end
		end
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
	end
	local tagged = #objects - #missing + added
	return { tagged = tagged, added = added, skipped = visited - tagged, seconds = os.clock() - started }
end

-- Copying a place ----------------------------------------------------------------------------------

local function encode(value: any): any
	local t = typeof(value)
	if t == "boolean" or t == "number" or t == "string" then
		return { t = t, v = value }
	elseif t == "Color3" then
		return { t = t, v = { value.R, value.G, value.B } }
	elseif t == "Vector3" then
		return { t = t, v = { value.X, value.Y, value.Z } }
	elseif t == "Vector2" then
		return { t = t, v = { value.X, value.Y } }
	elseif t == "CFrame" then
		return { t = t, v = { value:GetComponents() } }
	elseif t == "EnumItem" then
		return { t = t, v = value.Value }
	elseif t == "UDim" then
		return { t = t, v = { value.Scale, value.Offset } }
	elseif t == "NumberRange" then
		return { t = t, v = { value.Min, value.Max } }
	elseif t == "BrickColor" then
		return { t = t, v = value.Number }
	end
	return nil
end

-- A service's own settings. Studio doesn't let plugins read some of them; those keep Roblox's defaults.
local function serviceSettings(service: Instance): { [string]: any }
	local settingsOut = {}
	for _, info in ReflectionService:GetPropertiesOfClass(service.ClassName) do
		if info.Serialized and info.Name ~= "Name" then
			local ok, value = pcall(function()
				return (service :: any)[info.Name]
			end)
			if ok then
				settingsOut[info.Name] = encode(value)
			end
		end
	end
	return settingsOut
end

local function sendParts(capture: string, service: string, text: string)
	local count = math.max(1, math.ceil(#text / PART_CHARS))
	local pending, failure = count, nil
	for i = 1, count do
		local part = string.sub(text, (i - 1) * PART_CHARS + 1, i * PART_CHARS)
		task.spawn(function()
			local ok, reply = request("POST", string.format("/api/upload?capture=%s&file=%s&part=%d", capture, service, i - 1), nil, part)
			if not ok then
				failure = reply or "Lost the connection to rogit serve."
			end
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait()
	end
	if failure then
		error(failure, 0)
	end
end

-- Copies every saved service (its children in Roblox's binary format, plus its settings) to rogit serve.
local function copyPlace(capture: string): any
	local services = {}
	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if not (ok and service) then
			continue
		end
		local children = {}
		for _, child in service:GetChildren() do
			if child.Archivable then
				table.insert(children, child)
			end
		end
		if #children > 0 then
			local serialized, data = pcall(SerializationService.SerializeInstancesAsync, SerializationService, children)
			if not serialized then
				error(string.format("Studio couldn't copy %s: %s", name, tostring(data)), 0)
			end
			sendParts(capture, name, buffer.tostring(EncodingService:Base64Encode(data)))
		end
		local attributes = {}
		for key, value in service:GetAttributes() do
			attributes[key] = encode(value)
		end
		table.insert(services, { name = service.Name, className = service.ClassName, settings = serviceSettings(service), attributes = attributes })
	end
	return { services = services }
end

-- Panel --------------------------------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("RoGit")
local toggle = toolbar:CreateButton("RoGit", "Open the RoGit panel", "")
toggle.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"RoGitPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 300, 260, 180)
)
widget.Title = "RoGit"
toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggle:SetActive(widget.Enabled)
end)

local root = Instance.new("ScrollingFrame")
root.Size = UDim2.fromScale(1, 1)
root.BorderSizePixel = 0
root.ScrollBarThickness = 6
root.CanvasSize = UDim2.new()
root.AutomaticCanvasSize = Enum.AutomaticSize.Y
root.Parent = widget

local padding = Instance.new("UIPadding")
for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
	(padding :: any)[side] = UDim.new(0, 12)
end
padding.Parent = root

local function list(parent: Instance, gap: number, horizontal: boolean?)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, gap)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = parent
end
list(root, 8)

local themed: { [Instance]: { [string]: Enum.StudioStyleGuideColor } } = {}
local function theme(object: Instance, colors: { [string]: Enum.StudioStyleGuideColor })
	themed[object] = colors
end

local function label(parent: Instance, order: number, size: number, bold: boolean, color: Enum.StudioStyleGuideColor): TextLabel
	local text = Instance.new("TextLabel")
	text.LayoutOrder = order
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(1, 0, 0, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextSize = size
	text.FontFace = Font.fromEnum(if bold then Enum.Font.BuilderSansBold else Enum.Font.BuilderSans)
	text.Parent = parent
	theme(text, { TextColor3 = color })
	return text
end

local function button(parent: Instance, order: number, text: string, primary: boolean): TextButton
	local b = Instance.new("TextButton")
	b.LayoutOrder = order
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Size = UDim2.new(0, 0, 0, 28)
	b.AutoButtonColor = true
	b.TextSize = 14
	b.FontFace = Font.fromEnum(Enum.Font.BuilderSansBold)
	b.Text = text
	local inner = Instance.new("UIPadding")
	inner.PaddingLeft, inner.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
	inner.Parent = b
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = b
	b.Parent = parent
	theme(b, if primary
		then { BackgroundColor3 = Enum.StudioStyleGuideColor.DialogMainButton, TextColor3 = Enum.StudioStyleGuideColor.DialogMainButtonText }
		else { BackgroundColor3 = Enum.StudioStyleGuideColor.Button, TextColor3 = Enum.StudioStyleGuideColor.ButtonText })
	return b
end

local status = label(root, 1, 16, true, Enum.StudioStyleGuideColor.MainText)
local detail = label(root, 2, 14, false, Enum.StudioStyleGuideColor.SubText)
local problem = label(root, 3, 14, false, Enum.StudioStyleGuideColor.ErrorText)
local initButton = button(root, 4, "Init", true)

local newRow = Instance.new("Frame")
newRow.LayoutOrder = 5
newRow.BackgroundTransparency = 1
newRow.Size = UDim2.new(1, 0, 0, 28)
newRow.Parent = root
list(newRow, 8, true)
local nameBox = Instance.new("TextBox")
nameBox.LayoutOrder = 1
nameBox.Size = UDim2.new(1, -110, 1, 0)
nameBox.PlaceholderText = "branch-name"
nameBox.Text = ""
nameBox.ClearTextOnFocus = false
nameBox.TextSize = 14
nameBox.TextXAlignment = Enum.TextXAlignment.Left
nameBox.FontFace = Font.fromEnum(Enum.Font.BuilderSans)
nameBox.Parent = newRow
local boxPadding = Instance.new("UIPadding")
boxPadding.PaddingLeft = UDim.new(0, 8)
boxPadding.Parent = nameBox
local boxCorner = Instance.new("UICorner")
boxCorner.CornerRadius = UDim.new(0, 4)
boxCorner.Parent = nameBox
theme(nameBox, { BackgroundColor3 = Enum.StudioStyleGuideColor.InputFieldBackground, TextColor3 = Enum.StudioStyleGuideColor.MainText, PlaceholderColor3 = Enum.StudioStyleGuideColor.DimmedText })
local newButton = button(newRow, 2, "New branch", true)

local branchesTitle = label(root, 6, 14, true, Enum.StudioStyleGuideColor.MainText)
branchesTitle.Text = "Branches"
local branchList = Instance.new("Frame")
branchList.LayoutOrder = 7
branchList.BackgroundTransparency = 1
branchList.Size = UDim2.new(1, 0, 0, 0)
branchList.AutomaticSize = Enum.AutomaticSize.Y
branchList.Parent = root
list(branchList, 6)

local function paint()
	local studioTheme = settings().Studio.Theme :: StudioTheme
	root.BackgroundColor3 = studioTheme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
	for object, colors in themed do
		if object.Parent then
			for property, color in colors do
				(object :: any)[property] = studioTheme:GetColor(color)
			end
		else
			themed[object] = nil
		end
	end
end
settings().Studio.ThemeChanged:Connect(paint)

local function formatTime(seconds: number): string
	return DateTime.fromUnixTimestamp(seconds):FormatLocalTime("lll", "en-us")
end

local shownBranches = ""
local openBranch: (string) -> ()

local function renderBranches()
	local key = ""
	for _, branch in state.branches do
		key ..= branch.name .. ","
	end
	if key == shownBranches then
		return
	end
	shownBranches = key
	for _, child in branchList:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for index, branch in state.branches do
		local row = Instance.new("Frame")
		row.LayoutOrder = index
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 28)
		row.Parent = branchList
		local name = label(row, 1, 14, false, Enum.StudioStyleGuideColor.MainText)
		name.Size = UDim2.new(1, -70, 1, 0)
		name.AutomaticSize = Enum.AutomaticSize.None
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = branch.name .. "  ·  " .. formatTime(branch.created)
		local open = button(row, 2, "Open", false)
		open.AnchorPoint = Vector2.new(1, 0)
		open.Position = UDim2.fromScale(1, 0)
		open.Activated:Connect(function()
			openBranch(branch.name)
		end)
	end
	paint()
end

local function render()
	local isMain = state.game ~= nil and game.GameId == (state.game :: Game).universe_id
		and game.PlaceId == (state.game :: Game).main_place_id
	local showInit, showMain = false, false
	if state.busy then
		status.Text = "Working…"
		detail.Text = state.busy
	elseif not state.connected then
		status.Text = "Not connected"
		detail.Text = "Run `rogit serve` in your project folder, for example in VS Code's terminal."
	elseif state.branch then
		local branch = state.branch :: Branch
		status.Text = "Branch · " .. branch.name
		detail.Text = if branch.has_starting_point
			then "Started from main on " .. formatTime(branch.created) .. ". Build your update here and save the file with Ctrl+S."
			else "Recording the starting point…"
	elseif state.game and isMain then
		status.Text = "Main · " .. (state.game :: Game).name
		detail.Text = state.notice or "Make a branch to build an update without touching main."
		showMain = true
	elseif state.game then
		status.Text = "Connected · " .. (state.folder or "")
		detail.Text = "This project folder belongs to " .. (state.game :: Game).name .. ". Open its start place to use RoGit."
	elseif game.PlaceId == 0 or game.GameId == 0 then
		status.Text = "Connected · " .. (state.folder or "")
		detail.Text = "Open your published game's start place to set up RoGit."
	elseif state.isMain == nil then
		status.Text = "Connected · " .. (state.folder or "")
		detail.Text = "Checking this place…"
	elseif state.isMain then
		status.Text = "Connected · " .. (state.folder or "")
		detail.Text = "Set up RoGit for " .. (state.experience or "this game") .. "? Init gives every object in this "
			.. "place a small hidden ID (an attribute). Scripts and Rojo's folders are left alone. Save main afterwards to keep the IDs."
		showInit = true
	else
		status.Text = "Connected · " .. (state.folder or "")
		detail.Text = "This isn't the start place of " .. (state.experience or "this game")
			.. ". Open the start place to set up RoGit."
	end
	problem.Text = state.problem or ""
	problem.Visible = state.problem ~= nil
	initButton.Visible = showInit
	newRow.Visible = showMain and not state.busy
	branchesTitle.Visible = showMain and #state.branches > 0
	branchList.Visible = branchesTitle.Visible
	renderBranches()
	paint()
end

-- Actions ------------------------------------------------------------------------------------------

local recordingStart = false

local function run(first: string, action: () -> ())
	if state.busy then
		return
	end
	state.busy, state.problem, state.notice = first, nil, nil
	render()
	local ok, failure = pcall(action)
	state.busy = nil
	if not ok then
		state.problem = tostring(failure)
	end
	render()
end

local function step(text: string)
	state.busy = text
	render()
end

local function call(method: string, path: string, body: any?): any
	local ok, reply = request(method, path, body)
	if not ok then
		error(reply or "Lost the connection to rogit serve.", 0)
	end
	return reply
end

openBranch = function(name: string)
	local ok, reply = request("POST", "/api/branches/open", { name = name })
	state.problem = if ok then nil else (reply or "Couldn't reach rogit serve.")
	render()
end

local function refresh()
	local file = if game.PlaceId == 0 then "&file=" .. HttpService:UrlEncode(game.Name) else ""
	local ok, reply = request("GET", "/api/rogit?place=" .. string.format("%d", game.PlaceId) .. file)
	if ok and not state.connected then
		-- rogit serve (re)started, possibly in another folder: check this place again.
		state.isMain, state.problem = nil, nil
	end
	state.connected = ok
	if ok then
		state.folder = reply.project.folder
		state.game = reply.project.game
		state.rojo = reply.rojo
		state.branches = reply.branches or {}
		state.branch = reply.branch
		if not state.game and state.isMain == nil and game.PlaceId ~= 0 and game.GameId ~= 0 then
			local found, place = request("GET", string.format("/api/place?game=%d&place=%d", game.GameId, game.PlaceId))
			if found then
				state.isMain, state.experience, state.problem = place.isMain, place.experience, nil
			elseif place then
				state.problem = place
			end
		end
	end
	render()
	-- A branch that just opened for the first time: copy it once as its starting point.
	local branch = state.branch
	if branch and not branch.has_starting_point and not recordingStart then
		recordingStart = true
		run("Recording the starting point…", function()
			local capture = newId(16)
			local manifest = copyPlace(capture)
			call("POST", "/api/branches/start", { name = branch.name, capture = capture, manifest = manifest })
		end)
		recordingStart = false
	end
end

initButton.Activated:Connect(function()
	run("Checking with rogit serve…", function()
		local reply = call("POST", "/api/init", { game = game.GameId, place = game.PlaceId })
		step("Giving every object an ID…")
		local report = tagObjects(reply.rojo)
		request("POST", "/api/init/done", report)
		state.notice = string.format("Done. %d objects have an ID. Save main to keep them.", report.tagged)
	end)
	refresh()
end)

newButton.Activated:Connect(function()
	local name = string.gsub(nameBox.Text, "^%s*(.-)%s*$", "%1")
	if name == "" then
		state.problem = "Type a name for the branch first."
		render()
		return
	end
	run("Giving new objects an ID…", function()
		local report = tagObjects(state.rojo)
		step("Copying main…")
		local started = os.clock()
		local capture = newId(16)
		local manifest = copyPlace(capture)
		step("Building the branch file…")
		local reply = call("POST", "/api/branches", { name = name, capture = capture, manifest = manifest })
		nameBox.Text = ""
		state.notice = string.format("Created %s from %d objects in %.1f s. It's opening in Studio.%s", name, reply.objects,
			os.clock() - started, if report.added > 0 then string.format(" %d new objects got an ID; save main to keep them.", report.added) else "")
	end)
	refresh()
end)

render()
task.spawn(function()
	while true do
		if not state.busy then
			refresh()
		end
		task.wait(POLL_SECONDS)
	end
end)
