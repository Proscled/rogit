--!strict
-- RoGit Studio plugin. Talks to `rogit serve` on this computer, like the Rojo plugin talks to `rojo serve`.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local ReflectionService = game:GetService("ReflectionService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local CollectionService = game:GetService("CollectionService")
local SerializationService = game:GetService("SerializationService")
local StudioService = game:GetService("StudioService")

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
	review: any?,
	merge: any?,
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

-- Look ---------------------------------------------------------------------------------------------

local Color = Enum.StudioStyleGuideColor
local Modifier = Enum.StudioStyleGuideModifier
local REGULAR = Font.fromEnum(Enum.Font.BuilderSans)
local MEDIUM = Font.fromEnum(Enum.Font.BuilderSansMedium)
local BOLD = Font.fromEnum(Enum.Font.BuilderSansBold)
local GREEN = Color3.fromRGB(63, 185, 80)
local RED = Color3.fromRGB(239, 83, 80)
local AMBER = Color3.fromRGB(240, 173, 58)
local GREY = Color3.fromRGB(140, 140, 140)

-- Objects painted with Studio theme colors, repainted when the theme changes.
local themed: { [Instance]: { [string]: any } } = {}

local function themeColor(spec: any): Color3
	local studioTheme = settings().Studio.Theme :: StudioTheme
	if typeof(spec) == "table" then
		return studioTheme:GetColor(spec[1], spec[2])
	end
	return studioTheme:GetColor(spec)
end

local function paint()
	for object, colors in themed do
		if object.Parent then
			for property, spec in colors do
				(object :: any)[property] = themeColor(spec)
			end
		else
			themed[object] = nil
		end
	end
end
settings().Studio.ThemeChanged:Connect(paint)

local function new(class: string, props: { [string]: any }, colors: { [string]: any }?): any
	local object = Instance.new(class)
	local parent = props.Parent
	for key, value in props do
		if key ~= "Parent" then
			(object :: any)[key] = value
		end
	end
	if colors then
		themed[object] = colors
		for property, spec in colors do
			(object :: any)[property] = themeColor(spec)
		end
	end
	object.Parent = parent
	return object
end

local function round(parent: Instance, radius: number)
	new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function pad(parent: Instance, vertical: number, horizontal: number)
	new("UIPadding", {
		PaddingTop = UDim.new(0, vertical), PaddingBottom = UDim.new(0, vertical),
		PaddingLeft = UDim.new(0, horizontal), PaddingRight = UDim.new(0, horizontal), Parent = parent,
	})
end

local function stack(parent: Instance, gap: number, horizontal: boolean?)
	new("UIListLayout", {
		Padding = UDim.new(0, gap), SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		VerticalAlignment = if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top,
		Parent = parent,
	})
end

local function text(parent: Instance, order: number, size: number, font: Font, color: any, wrap: boolean?): TextLabel
	local colors = if typeof(color) == "Color3" then nil else { TextColor3 = color }
	local label = new("TextLabel", {
		LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = wrap ~= false, TextXAlignment = Enum.TextXAlignment.Left, TextSize = size, FontFace = font,
		RichText = true, Text = "", Parent = parent,
	}, colors)
	if typeof(color) == "Color3" then
		label.TextColor3 = color
	end
	return label
end

local function card(parent: Instance, order: number): Frame
	local frame = new("Frame", {
		LayoutOrder = order, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = parent,
	}, { BackgroundColor3 = Color.Titlebar })
	round(frame, 6)
	new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = frame }, { Color = Color.Border })
	pad(frame, 10, 12)
	stack(frame, 6)
	return frame
end

local function button(parent: Instance, order: number, label: string, primary: boolean, fullWidth: boolean?): TextButton
	local b = new("TextButton", {
		LayoutOrder = order, Text = label, TextSize = 14, FontFace = BOLD, AutoButtonColor = true, BorderSizePixel = 0,
		Size = if fullWidth then UDim2.new(1, 0, 0, 30) else UDim2.new(0, 0, 0, 28),
		AutomaticSize = if fullWidth then Enum.AutomaticSize.None else Enum.AutomaticSize.X, Parent = parent,
	}, if primary
		then { BackgroundColor3 = Color.DialogMainButton, TextColor3 = Color.DialogMainButtonText }
		else { BackgroundColor3 = Color.Button, TextColor3 = Color.ButtonText })
	round(b, 5)
	if not primary then
		new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b }, { Color = Color.ButtonBorder })
	end
	new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), Parent = b })
	return b
end

-- A small rounded badge, tinted with its own color.
local function pill(parent: Instance, order: number, label: string, color: Color3): TextLabel
	local badge = new("TextLabel", {
		LayoutOrder = order, Text = label, TextColor3 = color, BackgroundColor3 = color, BackgroundTransparency = 0.85,
		TextSize = 12, FontFace = BOLD, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 0, 20), Parent = parent,
	})
	round(badge, 10)
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = badge })
	return badge
end

local function escape(value: string): string
	return (string.gsub(value, "[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

local function formatTime(seconds: number): string
	return DateTime.fromUnixTimestamp(seconds):FormatLocalTime("lll", "en-us")
end

-- Main panel ---------------------------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("RoGit")
local toggle = toolbar:CreateButton("RoGit", "Open the RoGit panel", "")
toggle.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"RoGitPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 420, 280, 260)
)
widget.Title = "RoGit"
toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggle:SetActive(widget.Enabled)
end)

local root = new("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Parent = widget,
}, { BackgroundColor3 = Color.MainBackground, ScrollBarImageColor3 = Color.ScrollBar })
pad(root, 12, 12)
stack(root, 10)

-- Header: name and connection badge.
local header = new("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), Parent = root })
local wordmark = text(header, 1, 18, BOLD, Color.MainText, false)
wordmark.Size = UDim2.new(1, 0, 1, 0)
wordmark.AutomaticSize = Enum.AutomaticSize.None
wordmark.Text = "RoGit"
local connection = pill(header, 2, "Offline", GREY)
connection.AnchorPoint = Vector2.new(1, 0.5)
connection.Position = UDim2.new(1, 0, 0.5, 0)

-- Where you are.
local placeCard = card(root, 2)
local placeKind = text(placeCard, 1, 11, BOLD, Color.DimmedText)
local placeTitle = text(placeCard, 2, 17, BOLD, Color.MainText)
local placeDetail = text(placeCard, 3, 13, REGULAR, Color.SubText)

local message = text(root, 3, 13, MEDIUM, Color.SubText)

local initButton = button(root, 4, "Init", true, true)
local reviewButton = button(root, 5, "Review changes", true, true)
local openReviewButton = button(root, 6, "Open last review", false, true)

-- New branch (main only).
local newCard = card(root, 7)
local newTitle = text(newCard, 1, 14, BOLD, Color.MainText)
newTitle.Text = "New branch"
local newHint = text(newCard, 2, 12, REGULAR, Color.DimmedText)
newHint.Text = "Copies main as it is right now, including unsaved edits."
local newRow = new("Frame", { LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Parent = newCard })
local nameBox = new("TextBox", {
	Size = UDim2.new(1, -86, 1, 0), PlaceholderText = "branch-name", Text = "", ClearTextOnFocus = false,
	TextSize = 14, FontFace = REGULAR, TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0, Parent = newRow,
}, { BackgroundColor3 = Color.InputFieldBackground, TextColor3 = Color.MainText, PlaceholderColor3 = Color.DimmedText })
round(nameBox, 5)
new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = nameBox }, { Color = Color.InputFieldBorder })
new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = nameBox })
local createButton = button(newRow, 1, "Create", true)
createButton.AnchorPoint = Vector2.new(1, 0)
createButton.Position = UDim2.fromScale(1, 0)
createButton.AutomaticSize = Enum.AutomaticSize.None
createButton.Size = UDim2.new(0, 78, 1, 0)

-- Branch list (main only).
local branchesCard = card(root, 8)
local branchesTitle = text(branchesCard, 1, 14, BOLD, Color.MainText)
local branchRows = new("Frame", {
	LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = branchesCard,
})
stack(branchRows, 4)

local shownBranches = ""
local openBranch: (string) -> ()
local startMerge: (string) -> ()

local function renderBranches()
	local key = ""
	for _, branch in state.branches do
		key ..= branch.name .. ":" .. tostring(branch.merged) .. ","
	end
	if key == shownBranches then
		return
	end
	shownBranches = key
	for _, child in branchRows:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	branchesTitle.Text = string.format("Branches <font color=\"#8c8c8c\">%d</font>", #state.branches)
	for index, branch in state.branches do
		local row = new("Frame", { LayoutOrder = index, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = branchRows })
		local name = text(row, 1, 14, MEDIUM, Color.MainText, false)
		name.AutomaticSize = Enum.AutomaticSize.None
		name.Size = UDim2.new(1, -140, 0, 18)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = escape(branch.name)
		local made = text(row, 2, 12, REGULAR, Color.DimmedText, false)
		made.AutomaticSize = Enum.AutomaticSize.None
		made.Position = UDim2.fromOffset(0, 18)
		made.Size = UDim2.new(1, -140, 0, 16)
		made.TextTruncate = Enum.TextTruncate.AtEnd
		made.Text = if branch.merged then "Merged " .. formatTime(branch.merged) else "Made " .. formatTime(branch.created)
		local open = button(row, 3, "Open", false)
		open.AnchorPoint = Vector2.new(1, 0.5)
		open.Position = UDim2.new(1, -72, 0.5, 0)
		open.Activated:Connect(function()
			openBranch(branch.name)
		end)
		local merge = button(row, 4, "Merge", true)
		merge.AnchorPoint = Vector2.new(1, 0.5)
		merge.Position = UDim2.fromScale(1, 0.5)
		merge.AutomaticSize = Enum.AutomaticSize.None
		merge.Size = UDim2.fromOffset(66, 28)
		merge.Activated:Connect(function()
			startMerge(branch.name)
		end)
	end
end

-- Review window (a branch's changes, or a merge into main) --------------------------------------------

local MAX_REVIEW_ROWS = 400
local STATUS = {
	added = { label = "Added", color = GREEN },
	removed = { label = "Removed", color = RED },
	changed = { label = "Changed", color = AMBER },
}

local reviewWidget = plugin:CreateDockWidgetPluginGui(
	"RoGitReview",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 600, 620, 420, 300)
)
reviewWidget.Title = "RoGit · Review"

local reviewRoot = new("Frame", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = reviewWidget }, { BackgroundColor3 = Color.MainBackground })
local reviewHeader = new("Frame", {
	Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = reviewRoot,
}, { BackgroundColor3 = Color.Titlebar })
pad(reviewHeader, 12, 14)
stack(reviewHeader, 6)
local reviewTitle = text(reviewHeader, 1, 17, BOLD, Color.MainText)
local reviewSubtitle = text(reviewHeader, 2, 12, REGULAR, Color.DimmedText)
local chips = new("Frame", { LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), Parent = reviewHeader })
stack(chips, 6, true)
local addedChip = pill(chips, 1, "", GREEN)
local removedChip = pill(chips, 2, "", RED)
local changedChip = pill(chips, 3, "", AMBER)
local conflictChip = pill(chips, 4, "", RED)
local headerLine = new("Frame", { Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0, Parent = reviewRoot }, { BackgroundColor3 = Color.Border })

local reviewList = new("ScrollingFrame", {
	BorderSizePixel = 0, BackgroundTransparency = 1, ScrollBarThickness = 6, CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Parent = reviewRoot,
}, { ScrollBarImageColor3 = Color.ScrollBar })
new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = reviewList })
stack(reviewList, 0)

local footer = new("Frame", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 48), BorderSizePixel = 0, Parent = reviewRoot,
}, { BackgroundColor3 = Color.Titlebar })
new("Frame", { Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0, Parent = footer }, { BackgroundColor3 = Color.Border })
local footerHint = text(footer, 1, 12, REGULAR, Color.DimmedText, true)
footerHint.AutomaticSize = Enum.AutomaticSize.None
footerHint.Position = UDim2.fromOffset(14, 0)
footerHint.Size = UDim2.new(1, -280, 1, 0)
local refreshButton = button(footer, 2, "Refresh", false)
refreshButton.AnchorPoint = Vector2.new(1, 0.5)
refreshButton.Position = UDim2.new(1, -14, 0.5, 0)
local mergeButton = button(footer, 3, "Merge into main", true)
mergeButton.AnchorPoint = Vector2.new(1, 0.5)
mergeButton.Position = UDim2.new(1, -14, 0.5, 0)
local cancelButton = button(footer, 4, "Cancel", false)
cancelButton.AnchorPoint = Vector2.new(1, 0.5)
cancelButton.Position = UDim2.new(1, -160, 0.5, 0)

-- The list fills the space between the header and the footer.
local function layoutReview()
	local top = reviewHeader.AbsoluteSize.Y
	headerLine.Position = UDim2.fromOffset(0, top)
	reviewList.Position = UDim2.fromOffset(0, top + 1)
	reviewList.Size = UDim2.new(1, 0, 1, -(top + 1 + footer.AbsoluteSize.Y))
end
reviewHeader:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutReview)
reviewWidget:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutReview)
reviewWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	task.defer(layoutReview)
end)

-- Finds a live object by review key: RoGit ID, service, or path for untagged objects. `ids` is an optional
-- RoGitId -> object map, so repeated lookups don't scan the place each time.
local function findObject(key: string, ids: { [string]: Instance }?): Instance?
	if key == "" then
		return nil
	end
	local service = string.match(key, "^service:(.+)$")
	if service then
		local ok, found = pcall(game.GetService, game, service)
		return if ok then found else nil
	end
	local path = string.match(key, "^path:(.+)#%d+$")
	if path then
		local current: Instance? = game
		for name in string.gmatch(path, "[^/]+") do
			current = current and current:FindFirstChild(name)
		end
		return current
	end
	if ids then
		return ids[key]
	end
	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			for _, object in service:GetDescendants() do
				if object:GetAttribute(TAG) == key then
					return object
				end
			end
		end
	end
	return nil
end

local function setStyle(b: TextButton, primary: boolean)
	local colors = if primary
		then { BackgroundColor3 = Color.DialogMainButton, TextColor3 = Color.DialogMainButtonText }
		else { BackgroundColor3 = Color.Button, TextColor3 = Color.ButtonText }
	themed[b] = colors
	for property, spec in colors do
		(b :: any)[property] = themeColor(spec)
	end
end

local updateFooter: () -> ()

-- "Keep main" / "Use branch" for one conflict.
local function choice(parent: Instance, id: number)
	local holder = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Parent = parent,
	})
	stack(holder, 4, true)
	local keep = button(holder, 1, "Keep main", false)
	local use = button(holder, 2, "Use branch", false)
	for _, b in { keep, use } do
		b.Size = UDim2.new(0, 0, 0, 22)
		b.TextSize = 12
	end
	local function show()
		local picked = state.merge and state.merge.choices[id]
		setStyle(keep, picked == "main")
		setStyle(use, picked == "branch")
	end
	keep.Activated:Connect(function()
		state.merge.choices[id] = "main"
		show()
		updateFooter()
	end)
	use.Activated:Connect(function()
		state.merge.choices[id] = "branch"
		show()
		updateFooter()
	end)
	show()
end

local selectedRow: TextButton? = nil

local function detailLine(order: number, indent: number, change: any): Frame
	local line = new("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), Parent = reviewList })
	local name = text(line, 1, 12, MEDIUM, Color.DimmedText, false)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.Position = UDim2.fromOffset(indent, 0)
	name.Size = UDim2.new(0, 120, 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = escape(change.name)
	local value = text(line, 2, 12, REGULAR, Color.MainText, false)
	value.AutomaticSize = Enum.AutomaticSize.None
	value.Position = UDim2.fromOffset(indent + 126, 0)
	value.Size = UDim2.new(1, -(indent + 136 + (if change.conflict then 170 else 0)), 1, 0)
	value.TextTruncate = Enum.TextTruncate.AtEnd
	value.Text = if change.old == ""
		then escape(change.new)
		else string.format('<font color="#ef5350"><s>%s</s></font>  →  <font color="#3fb950">%s</font>', escape(change.old), escape(change.new))
	if change.conflict then
		choice(line, change.conflict)
	end
	return line
end

local function reviewRow(order: number, row: any)
	local status = STATUS[row.status]
	local indent = 10 + row.depth * 16
	local frame = new("TextButton", {
		LayoutOrder = order, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 26), Parent = reviewList,
	}, { BackgroundColor3 = { Color.Item, Modifier.Hover } })
	local details: { Frame } = {}
	local hasConflict = row.conflict ~= nil
	for _, change in row.changes do
		hasConflict = hasConflict or change.conflict ~= nil
	end
	local expanded = hasConflict or (row.status == "changed" and #row.changes <= 4)
	local chevron = text(frame, 1, 12, BOLD, Color.DimmedText, false)
	chevron.AutomaticSize = Enum.AutomaticSize.None
	chevron.Position = UDim2.fromOffset(indent, 0)
	chevron.Size = UDim2.fromOffset(12, 26)
	chevron.TextXAlignment = Enum.TextXAlignment.Center
	local icon = new("ImageLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(indent + 14, 5), Size = UDim2.fromOffset(16, 16), Parent = frame })
	local ok, image = pcall(StudioService.GetClassIcon, StudioService, row.class)
	if ok and image then
		icon.Image, icon.ImageRectOffset, icon.ImageRectSize = image.Image, image.ImageRectOffset, image.ImageRectSize
	end
	local name = text(frame, 2, 14, if status then MEDIUM else REGULAR, if status then Color.MainText else Color.SubText, false)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.Position = UDim2.fromOffset(indent + 36, 0)
	name.Size = UDim2.new(1, -(indent + 36 + 100), 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = if row.status == "removed" then "<s>" .. escape(row.name) .. "</s>" else escape(row.name)
	if status then
		local badge = pill(frame, 3, if hasConflict then "Conflict" else status.label, if hasConflict then RED else status.color)
		badge.AnchorPoint = Vector2.new(1, 0.5)
		badge.Position = UDim2.new(1, -12, 0.5, 0)
	end
	local line = 0
	for _, change in row.changes do
		-- A whole added or removed model shows its size next to its name instead of as a detail line.
		if change.name == "Contains" then
			name.Text ..= '  <font color="#8c8c8c" size="12">' .. escape(change.new) .. " inside</font>"
			continue
		end
		line += 1
		local detail = detailLine(order + math.min(line, 98), indent + 36, change)
		detail.Visible = expanded
		table.insert(details, detail)
	end
	if row.conflict then
		local detail = detailLine(order + 99, indent + 36, {
			name = "Choose", old = "", new = if row.status == "removed" then "Remove it from main?" else "Bring it back from the branch?",
			conflict = row.conflict,
		})
		table.insert(details, detail)
	end
	local function showChevron()
		chevron.Text = if #details == 0 then "" else "›"
		chevron.Rotation = if expanded then 90 else 0
	end
	showChevron()
	frame.MouseEnter:Connect(function()
		frame.BackgroundTransparency = 0
	end)
	frame.MouseLeave:Connect(function()
		if selectedRow ~= frame then
			frame.BackgroundTransparency = 1
		end
	end)
	frame.Activated:Connect(function()
		if #details > 0 then
			expanded = not expanded
			for _, detail in details do
				detail.Visible = expanded
			end
			showChevron()
		end
		if selectedRow and selectedRow ~= frame then
			selectedRow.BackgroundTransparency = 1
		end
		selectedRow = frame
		frame.BackgroundTransparency = 0
		local object = if row.status == "removed" and not state.merge then nil else findObject(row.key)
		if object then
			Selection:Set({ object })
		end
	end)
end

updateFooter = function()
	local merge = state.merge
	refreshButton.Visible = merge == nil
	mergeButton.Visible = merge ~= nil
	cancelButton.Visible = merge ~= nil
	if not merge then
		footerHint.Text = "Click a row to select it in Explorer."
		return
	end
	local open = 0
	for _, conflict in merge.plan.conflicts do
		if not merge.choices[conflict.id] then
			open += 1
		end
	end
	merge.ready = open == 0 and #merge.plan.operations > 0
	mergeButton.BackgroundTransparency = if merge.ready then 0 else 0.6
	mergeButton.AutoButtonColor = merge.ready
	footerHint.Text = if #merge.plan.operations == 0
		then "Nothing to merge: main already has everything from this branch."
		elseif open > 0 then string.format("Choose a side for %d conflict%s first.", open, if open == 1 then "" else "s")
		else "Applies as one step. Ctrl+Z undoes the whole merge."
end

local shownReview: any = nil

local function renderReview()
	local data = if state.merge then state.merge.plan else state.review
	if data == shownReview then
		return
	end
	shownReview = data
	selectedRow = nil
	for _, child in reviewList:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	updateFooter()
	if not data then
		return
	end
	local s = data.summary
	if state.merge then
		local merge = state.merge
		reviewWidget.Title = "RoGit · Merge"
		reviewTitle.Text = "Merge " .. escape(merge.branch) .. " into main"
		reviewSubtitle.Text = string.format("%s · branch as %s %s · main as it is now",
			if merge.since == "merge" then "Since the last merge" else "Since the branch started", merge.source, formatTime(merge.sourceTime))
	else
		reviewWidget.Title = "RoGit · Review"
		reviewTitle.Text = "Changes in " .. escape(if state.branch then (state.branch :: Branch).name else "branch")
		reviewSubtitle.Text = "Compared with how the branch started · " .. DateTime.now():FormatLocalTime("LT", "en-us")
	end
	addedChip.Text, removedChip.Text, changedChip.Text = "+ " .. s.added .. " added", "− " .. s.removed .. " removed", "● " .. s.changed .. " changed"
	addedChip.Visible, removedChip.Visible, changedChip.Visible = s.added > 0, s.removed > 0, s.changed > 0
	local conflicts = s.conflicts or 0
	conflictChip.Text = conflicts .. (if conflicts == 1 then " conflict" else " conflicts")
	conflictChip.Visible = conflicts > 0
	if #data.rows == 0 then
		local empty = text(reviewList, 1, 14, REGULAR, Color.SubText)
		new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingTop = UDim.new(0, 10), Parent = empty })
		empty.Text = if state.merge
			then (if state.merge.since == "merge"
				then "Nothing new to merge: main has everything from this branch's last merge."
				else "Nothing to merge: main already has everything from this branch.")
			else "No changes yet. Build something in this branch, then click Refresh."
	end
	for index, row in data.rows do
		if index > MAX_REVIEW_ROWS then
			local more = text(reviewList, index * 100, 13, REGULAR, Color.DimmedText)
			new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingTop = UDim.new(0, 8), Parent = more })
			more.Text = string.format("…and %d more rows.", #data.rows - MAX_REVIEW_ROWS + data.truncated)
			break
		end
		-- Rows are 100 apart, so each row's detail lines sort right under it.
		reviewRow(index * 100, row)
	end
	task.defer(layoutReview)
end

-- Showing state ------------------------------------------------------------------------------------

local function render()
	local g = state.game
	local isMain = g ~= nil and game.GameId == g.universe_id and game.PlaceId == g.main_place_id
	local mode = "other"
	if state.busy then
		connection.Text, connection.TextColor3, connection.BackgroundColor3 = "Working…", AMBER, AMBER
	elseif state.connected then
		connection.Text, connection.TextColor3, connection.BackgroundColor3 = "● Connected", GREEN, GREEN
	else
		connection.Text, connection.TextColor3, connection.BackgroundColor3 = "● Offline", GREY, GREY
	end
	if not state.connected and not state.busy then
		placeKind.Text, placeTitle.Text = "NOT CONNECTED", "Start rogit serve"
		placeDetail.Text = "Run <b>rogit serve</b> in your project folder, for example in VS Code's terminal."
	elseif state.branch then
		local branch = state.branch :: Branch
		mode = if branch.has_starting_point then "branch" else "other"
		placeKind.Text, placeTitle.Text = "BRANCH", escape(branch.name)
		placeDetail.Text = if branch.has_starting_point
			then "Started from main " .. formatTime(branch.created) .. ". Save with Ctrl+S as you work."
			else "Recording the starting point…"
	elseif g and isMain then
		mode = "main"
		placeKind.Text, placeTitle.Text = "MAIN", escape(g.name)
		placeDetail.Text = "Make a branch to build an update without touching main."
	elseif g then
		placeKind.Text, placeTitle.Text = "OTHER PLACE", escape(game.Name)
		placeDetail.Text = "This project belongs to " .. escape(g.name) .. ". Open its start place to use RoGit."
	elseif game.PlaceId == 0 or game.GameId == 0 then
		placeKind.Text, placeTitle.Text = "NOT SET UP", escape(state.folder or "")
		placeDetail.Text = "Open your published game's start place to set up RoGit."
	elseif state.isMain == nil then
		placeKind.Text, placeTitle.Text, placeDetail.Text = "CHECKING", escape(state.experience or game.Name), "Checking this place…"
	elseif state.isMain then
		mode = "init"
		placeKind.Text, placeTitle.Text = "SET UP", escape(state.experience or game.Name)
		placeDetail.Text = "Init gives every object in this place a small hidden ID (an attribute), so RoGit can follow it "
			.. "between branches. Scripts and Rojo's folders are left alone. Save main afterwards."
	else
		placeKind.Text, placeTitle.Text = "NOT THE START PLACE", escape(state.experience or game.Name)
		placeDetail.Text = "Open the start place of this game to set up RoGit."
	end
	if state.problem then
		message.Text, message.TextColor3 = escape(state.problem), RED
	elseif state.busy then
		message.Text, message.TextColor3 = escape(state.busy), themeColor(Color.SubText)
	else
		message.Text, message.TextColor3 = escape(state.notice or ""), themeColor(Color.SubText)
	end
	message.Visible = message.Text ~= ""
	local idle = not state.busy
	initButton.Visible = mode == "init" and idle
	newCard.Visible = mode == "main" and idle
	branchesCard.Visible = mode == "main" and #state.branches > 0
	reviewButton.Visible = mode == "branch" and idle
	openReviewButton.Visible = idle and not reviewWidget.Enabled
		and ((mode == "branch" and state.review ~= nil) or (mode == "main" and state.merge ~= nil))
	openReviewButton.Text = if state.merge then "Open merge of " .. state.merge.branch else "Open last review"
	renderBranches()
	renderReview()
end

reviewWidget:GetPropertyChangedSignal("Enabled"):Connect(render)

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

local function step(textValue: string)
	state.busy = textValue
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
	state.notice = if ok then "Opening " .. name .. " in Studio…" else nil
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
		state.notice = string.format("Done: %d objects have an ID. Save main to keep them.", report.tagged)
	end)
	refresh()
end)

local function createBranch()
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
end

createButton.Activated:Connect(createBranch)
nameBox.FocusLost:Connect(function(enter)
	if enter then
		createBranch()
	end
end)

local function runReview()
	local branch = state.branch
	if not branch then
		return
	end
	run("Giving new objects an ID…", function()
		tagObjects(state.rojo)
		step("Copying the branch…")
		local started = os.clock()
		local capture = newId(16)
		local manifest = copyPlace(capture)
		step("Comparing with the starting point…")
		local reply = call("POST", "/api/branches/review", { name = branch.name, capture = capture, manifest = manifest })
		state.review = reply.review
		state.notice = string.format("Reviewed in %.1f s.", os.clock() - started)
	end)
	reviewWidget.Enabled = state.review ~= nil
	refresh()
end

-- Merging -----------------------------------------------------------------------------------------

-- Bundle attributes (set by rogit): which operation an object belongs to, and which ones need a reference fixed.
local OP_TAG = "RoGitOp"
local REF_TAG = "RoGitRef"
-- Workspace attribute in main: the last merge of each branch, so the next merge only brings what changed after it.
local MERGES_TAG = "RoGitMerges"

local function recordMerge(branch: string, id: string)
	local ok, record = pcall(HttpService.JSONDecode, HttpService, workspace:GetAttribute(MERGES_TAG) or "{}")
	if not ok or typeof(record) ~= "table" then
		record = {}
	end
	record[branch] = id
	workspace:SetAttribute(MERGES_TAG, HttpService:JSONEncode(record))
end
-- Properties a plugin can't set directly. They change through the mesh or union APIs instead.
local MESH_DATA = {
	MeshId = true, MeshContent = true, MeshData = true, InitialSize = true, PhysicalConfigData = true, PhysicsData = true,
	CollisionFidelity = true, RenderFidelity = true, HasJointOffset = true, HasSkinnedMesh = true, JointOffset = true,
	DoubleSided = true,
}
local UNION_DATA = {
	AssetId = true, ChildData = true, MeshData = true, PhysicsData = true, PhysicalConfigData = true, InitialSize = true,
	CollisionFidelity = true, RenderFidelity = true, SmoothingAngle = true,
}

-- Saved property names that scripts know by another name.
local SCRIPT_NAMES = { WorldPivotData = "WorldPivot" }

local function decodeValue(encoded: any): any
	local t, v = encoded.t, encoded.v
	if t == "Color3" then
		return Color3.new(v[1], v[2], v[3])
	elseif t == "Vector3" then
		return Vector3.new(v[1], v[2], v[3])
	elseif t == "Vector2" then
		return Vector2.new(v[1], v[2])
	elseif t == "NumberRange" then
		return NumberRange.new(v[1], v[2])
	end
	return v
end

local function copyAttributes(from: Instance, to: Instance)
	for key in to:GetAttributes() do
		if key ~= TAG and from:GetAttribute(key) == nil then
			to:SetAttribute(key, nil)
		end
	end
	for key, value in from:GetAttributes() do
		if key ~= TAG and key ~= OP_TAG and key ~= REF_TAG then
			to:SetAttribute(key, value)
		end
	end
end

local function copyTags(from: Instance, to: Instance)
	for _, tagName in CollectionService:GetTags(to) do
		if not from:HasTag(tagName) then
			to:RemoveTag(tagName)
		end
	end
	for _, tagName in CollectionService:GetTags(from) do
		to:AddTag(tagName)
	end
end

-- Every tagged object in main, by RoGit ID.
local function idMap(): { [string]: Instance }
	local ids = {}
	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			for _, object in service:GetDescendants() do
				local id = object:GetAttribute(TAG)
				if type(id) == "string" then
					ids[id] = object
				end
			end
		end
	end
	return ids
end

local function applyOperation(op: any, templates: { [number]: Instance }, ids: { [string]: Instance }, problems: { string })
	local function find(key: string): Instance
		return findObject(key, ids) or error("Couldn't find " .. key .. " in main.", 0)
	end
	if op.kind == "set" then
		local target, template = find(op.target), templates[op.template]
		local geometry = false
		for _, property in op.properties do
			if property == "Attributes" then
				copyAttributes(template, target)
			elseif property == "Tags" then
				copyTags(template, target)
			elseif (target:IsA("MeshPart") and MESH_DATA[property]) or (target:IsA("PartOperation") and UNION_DATA[property]) then
				geometry = true
			else
				-- Some saved names differ from what scripts use.
				local name = SCRIPT_NAMES[property] or property
				local ok = pcall(function()
					(target :: any)[name] = (template :: any)[name]
				end)
				if not ok then
					table.insert(problems, target:GetFullName() .. "." .. property .. " couldn't be set")
				end
			end
		end
		for property, key in op.refs do
			(target :: any)[property] = if key == "" then nil else find(key)
		end
		if geometry then
			local ok, err = pcall(function()
				if target:IsA("MeshPart") then
					(target :: any):ApplyMesh(template)
				else
					(target :: any):SubstituteGeometry(template)
				end
			end)
			if not ok then
				table.insert(problems, target:GetFullName() .. " geometry: " .. tostring(err))
			end
		end
	elseif op.kind == "settings" then
		local service = game:GetService(op.service)
		for property, encoded in op.values do
			local ok = pcall(function()
				(service :: any)[property] = decodeValue(encoded)
			end)
			if not ok then
				table.insert(problems, op.service .. "." .. property .. " couldn't be set")
			end
		end
	elseif op.kind == "rename" then
		find(op.target).Name = op.name
	elseif op.kind == "move" then
		find(op.target).Parent = find(op.parent)
	elseif op.kind == "add" then
		local parent, object = find(op.parent), templates[op.template]
		local marked: { [string]: Instance } = {}
		for _, descendant in object:GetDescendants() do
			local marker = descendant:GetAttribute(REF_TAG)
			if marker then
				marked[marker] = descendant
				descendant:SetAttribute(REF_TAG, nil)
			end
		end
		local ownMarker = object:GetAttribute(REF_TAG)
		if ownMarker then
			marked[ownMarker] = object
			object:SetAttribute(REF_TAG, nil)
		end
		for _, fixup in op.fixups do
			local holder = marked[fixup.marker]
			if holder then
				(holder :: any)[fixup.property] = if fixup.target == "" then nil else ids[fixup.target] or findObject(fixup.target, ids)
			end
		end
		object.Parent = parent
	elseif op.kind == "remove" then
		find(op.target).Parent = nil
	end
end

local function applyMerge()
	local merge = state.merge
	if not merge or not merge.ready then
		return
	end
	reviewWidget.Enabled = false
	run("Merging " .. merge.branch .. " into main…", function()
		local plan = merge.plan
		local templates: { [number]: Instance } = {}
		if plan.bundle ~= "" then
			local data = EncodingService:Base64Decode(buffer.fromstring(plan.bundle))
			for _, object in SerializationService:DeserializeInstancesAsync(data) do
				local index = tonumber(object:GetAttribute(OP_TAG))
				if index then
					object:SetAttribute(OP_TAG, nil)
					templates[index] = object
				end
			end
		end
		local ids = idMap()
		local problems: { string } = {}
		local applied, skipped = 0, 0
		-- Removals go last, so moves and additions can still find everything they need.
		local ordered = {}
		for _, op in plan.operations do
			if op.kind ~= "remove" then
				table.insert(ordered, op)
			end
		end
		for _, op in plan.operations do
			if op.kind == "remove" then
				table.insert(ordered, op)
			end
		end
		local recording = ChangeHistoryService:TryBeginRecording("RoGitMerge", "RoGit merge " .. merge.branch)
		for _, op in ordered do
			if op.conflict and merge.choices[op.conflict] ~= "branch" then
				skipped += 1
				continue
			end
			local ok, err = pcall(applyOperation, op, templates, ids, problems)
			if ok then
				applied += 1
			else
				table.insert(problems, tostring(err))
			end
		end
		-- Recorded in the same undo step, so undoing the merge (or not saving main) forgets it too. If something
		-- couldn't be applied, the next merge starts from earlier and offers it again.
		local recorded = #problems == 0 and merge.id ~= nil
		if recorded then
			recordMerge(merge.branch, merge.id)
		end
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		request("POST", "/api/branches/merged", {
			name = merge.branch, applied = applied, skipped = skipped, failed = problems, merge = if recorded then merge.id else nil,
		})
		state.merge = nil
		state.notice = string.format("Merged %s into main: %d change%s applied%s. Save main to keep it; Ctrl+Z undoes the merge.",
			merge.branch, applied, if applied == 1 then "" else "s",
			if #problems > 0 then string.format(", %d couldn't be applied (see the rogit serve terminal)", #problems) else "")
	end)
	refresh()
end

startMerge = function(name: string)
	if state.busy then
		return
	end
	state.review = nil
	run("Giving new objects an ID…", function()
		tagObjects(state.rojo)
		step("Copying main…")
		local capture = newId(16)
		local manifest = copyPlace(capture)
		step("Comparing " .. name .. " with main…")
		local reply = call("POST", "/api/branches/merge", { name = name, capture = capture, manifest = manifest })
		state.merge = {
			branch = name, plan = reply.plan, source = reply.source, sourceTime = reply.sourceTime, since = reply.since, id = reply.merge,
			choices = {},
		}
	end)
	reviewWidget.Enabled = state.merge ~= nil
	render()
end

mergeButton.Activated:Connect(applyMerge)
cancelButton.Activated:Connect(function()
	state.merge = nil
	reviewWidget.Enabled = false
	render()
end)
reviewButton.Activated:Connect(runReview)
refreshButton.Activated:Connect(runReview)
openReviewButton.Activated:Connect(function()
	reviewWidget.Enabled = true
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
