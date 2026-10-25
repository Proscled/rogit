--!strict
-- RoGit Studio plugin. Talks to `rogit serve` on this computer, like the Rojo plugin talks to `rojo serve`.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

if not RunService:IsEdit() then
	return
end

local BASE = "http://127.0.0.1:34875"
local TAG = "RoGitId"
local POLL_SECONDS = 2
-- Services whose contents are saved in place files. RoGit only looks inside these.
local SERVICES = {
	"Workspace", "Lighting", "MaterialService", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService",
	"ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "TextChatService",
	"Chat", "LocalizationService", "TestService", "SocialService", "VoiceChatService",
}

type Game = { name: string, universe_id: number, main_place_id: number }
type State = {
	connected: boolean,
	folder: string?,
	game: Game?,
	isMain: boolean?,
	experience: string?,
	busy: string?,
	notice: string?,
	problem: string?,
}

local state: State = { connected = false }

-- Talking to rogit serve ---------------------------------------------------------------------------

local function request(method: string, path: string, body: any?): (boolean, any)
	local options: any = { Url = BASE .. path, Method = method }
	if body ~= nil then
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

-- Tagging ------------------------------------------------------------------------------------------

local ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local random = Random.new()

local function newId(): string
	local chars = table.create(10)
	for i = 1, 10 do
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

-- Gives every tracked object a short hidden ID. Copies made with Ctrl+D share an ID, so repeats get a new one.
local function tagObjects(rojo: any): { tagged: number, skipped: number, seconds: number }
	local started = os.clock()
	if rojo.all then
		return { tagged = 0, skipped = 0, seconds = 0 }
	end
	local rojoPaths: { [string]: boolean } = {}
	for _, path in rojo.paths do
		rojoPaths[path] = true
	end
	local objects, visited = trackedObjects(rojoPaths)
	local recording = ChangeHistoryService:TryBeginRecording("RoGitInit", "RoGit Init")
	local seen: { [string]: boolean } = {}
	local tagged = 0
	for _, object in objects do
		local id = object:GetAttribute(TAG)
		if type(id) ~= "string" or id == "" or seen[id] then
			id = newId()
			if not pcall(object.SetAttribute, object, TAG, id) then
				continue
			end
		end
		seen[id] = true
		tagged += 1
	end
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	return { tagged = tagged, skipped = visited - tagged, seconds = os.clock() - started }
end

-- Panel --------------------------------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("RoGit")
local toggle = toolbar:CreateButton("RoGit", "Open the RoGit panel", "")
toggle.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"RoGitPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 220, 260, 160)
)
widget.Title = "RoGit"
toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggle:SetActive(widget.Enabled)
end)

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BorderSizePixel = 0
root.Parent = widget

local padding = Instance.new("UIPadding")
for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
	(padding :: any)[side] = UDim.new(0, 12)
end
padding.Parent = root

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = root

local function label(order: number, size: number, bold: boolean): TextLabel
	local text = Instance.new("TextLabel")
	text.LayoutOrder = order
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(1, 0, 0, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextSize = size
	text.FontFace = Font.fromEnum(if bold then Enum.Font.BuilderSansBold else Enum.Font.BuilderSans)
	text.Parent = root
	return text
end

local status = label(1, 16, true)
local detail = label(2, 14, false)
local problem = label(3, 14, false)

local button = Instance.new("TextButton")
button.LayoutOrder = 4
button.Size = UDim2.new(0, 120, 0, 30)
button.AutoButtonColor = true
button.TextSize = 14
button.FontFace = Font.fromEnum(Enum.Font.BuilderSansBold)
button.Text = "Init"
button.Parent = root
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 4)
corner.Parent = button

local function paint()
	local theme = settings().Studio.Theme :: StudioTheme
	root.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
	status.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	detail.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.SubText)
	problem.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.ErrorText)
	button.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.DialogMainButton)
	button.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.DialogMainButtonText)
end
paint()
settings().Studio.ThemeChanged:Connect(paint)

local function render()
	local showInit = false
	if state.busy then
		status.Text = "Setting up…"
		detail.Text = state.busy
	elseif not state.connected then
		status.Text = "Not connected"
		detail.Text = "Run `rogit serve` in your project folder, for example in VS Code's terminal."
	elseif state.game then
		local g = state.game :: Game
		if game.GameId == g.universe_id and game.PlaceId == g.main_place_id then
			status.Text = "Main · " .. g.name
			detail.Text = state.notice or "RoGit is set up for this game."
		else
			status.Text = "Connected · " .. (state.folder or "")
			detail.Text = "This project folder belongs to " .. g.name .. ". Open its start place to use RoGit."
		end
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
	button.Visible = showInit
end

local function refresh()
	local ok, reply = request("GET", "/api/rogit?place=" .. string.format("%d", game.PlaceId))
	if ok and not state.connected then
		-- rogit serve (re)started, possibly in another folder: check this place again.
		state.isMain, state.problem = nil, nil
	end
	state.connected = ok
	if ok then
		state.folder = reply.project.folder
		state.game = reply.project.game
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
end

button.Activated:Connect(function()
	if state.busy then
		return
	end
	state.busy, state.problem, state.notice = "Checking with rogit serve…", nil, nil
	render()
	local ok, reply = request("POST", "/api/init", { game = game.GameId, place = game.PlaceId })
	if not ok then
		state.busy, state.problem = nil, reply or "Couldn't reach rogit serve."
		render()
		return
	end
	state.busy = "Tagging objects…"
	render()
	local report = tagObjects(reply.rojo)
	request("POST", "/api/init/done", report)
	state.busy = nil
	state.notice = string.format("Done. %d objects have an ID. Save main to keep them.", report.tagged)
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
