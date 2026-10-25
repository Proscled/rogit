--!strict
-- RoGit Studio plugin. Talks to `rogit serve` on this computer, like the Rojo plugin talks to `rojo serve`.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local ReflectionService = game:GetService("ReflectionService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
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

local function renderBranches()
	local key = ""
	for _, branch in state.branches do
		key ..= branch.name .. ","
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
		name.Size = UDim2.new(1, -70, 0, 18)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = escape(branch.name)
		local made = text(row, 2, 12, REGULAR, Color.DimmedText, false)
		made.AutomaticSize = Enum.AutomaticSize.None
		made.Position = UDim2.fromOffset(0, 18)
		made.Size = UDim2.new(1, -70, 0, 16)
		made.Text = "Made " .. formatTime(branch.created)
		local open = button(row, 3, "Open", false)
		open.AnchorPoint = Vector2.new(1, 0.5)
		open.Position = UDim2.fromScale(1, 0.5)
		open.Activated:Connect(function()
			openBranch(branch.name)
		end)
	end
end

-- Review window ------------------------------------------------------------------------------------

local MAX_REVIEW_ROWS = 400
local STATUS = {
	added = { label = "Added", color = GREEN },
	removed = { label = "Removed", color = RED },
	changed = { label = "Changed", color = AMBER },
}

local reviewWidget = plugin:CreateDockWidgetPluginGui(
	"RoGitReview",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 560, 620, 380, 300)
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
local headerLine = new("Frame", { Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0, Parent = reviewRoot }, { BackgroundColor3 = Color.Border })

local reviewList = new("ScrollingFrame", {
	BorderSizePixel = 0, BackgroundTransparency = 1, ScrollBarThickness = 6, CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Parent = reviewRoot,
}, { ScrollBarImageColor3 = Color.ScrollBar })
new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = reviewList })
stack(reviewList, 0)

local footer = new("Frame", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 44), BorderSizePixel = 0, Parent = reviewRoot,
}, { BackgroundColor3 = Color.Titlebar })
new("Frame", { Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0, Parent = footer }, { BackgroundColor3 = Color.Border })
local footerHint = text(footer, 1, 12, REGULAR, Color.DimmedText, false)
footerHint.AutomaticSize = Enum.AutomaticSize.None
footerHint.Position = UDim2.fromOffset(14, 0)
footerHint.Size = UDim2.new(1, -140, 1, 0)
footerHint.Text = "Click a row to select it in Explorer."
local refreshButton = button(footer, 2, "Refresh", false)
refreshButton.AnchorPoint = Vector2.new(1, 0.5)
refreshButton.Position = UDim2.new(1, -14, 0.5, 0)

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

-- Finds the live object a review row is about: by RoGit ID, by service, or by path for untagged objects.
local function findObject(key: string): Instance?
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

local selectedRow: TextButton? = nil

local function detailLine(order: number, indent: number, change: any): Frame
	local line = new("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), Parent = reviewList })
	local name = text(line, 1, 12, MEDIUM, Color.DimmedText, false)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.Position = UDim2.fromOffset(indent, 0)
	name.Size = UDim2.new(0, 120, 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = escape(change.name)
	local value = text(line, 2, 12, REGULAR, Color.MainText, false)
	value.AutomaticSize = Enum.AutomaticSize.None
	value.Position = UDim2.fromOffset(indent + 126, 0)
	value.Size = UDim2.new(1, -(indent + 136), 1, 0)
	value.TextTruncate = Enum.TextTruncate.AtEnd
	value.Text = if change.old == ""
		then escape(change.new)
		else string.format('<font color="#ef5350"><s>%s</s></font>  →  <font color="#3fb950">%s</font>', escape(change.old), escape(change.new))
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
	local expanded = row.status == "changed" and #row.changes <= 4
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
	name.Size = UDim2.new(1, -(indent + 36 + 90), 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = if row.status == "removed" then "<s>" .. escape(row.name) .. "</s>" else escape(row.name)
	if status then
		local badge = pill(frame, 3, status.label, status.color)
		badge.AnchorPoint = Vector2.new(1, 0.5)
		badge.Position = UDim2.new(1, -12, 0.5, 0)
	end
	for i, change in row.changes do
		-- A whole added or removed model shows its size next to its name instead of as a detail line.
		if change.name == "Contains" then
			name.Text ..= '  <font color="#8c8c8c" size="12">' .. escape(change.new) .. " inside</font>"
			continue
		end
		local line = detailLine(order + i, indent + 36, change)
		line.Visible = expanded
		table.insert(details, line)
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
			for _, line in details do
				line.Visible = expanded
			end
			showChevron()
		end
		if selectedRow and selectedRow ~= frame then
			selectedRow.BackgroundTransparency = 1
		end
		selectedRow = frame
		frame.BackgroundTransparency = 0
		if row.status ~= "removed" then
			local object = findObject(row.key)
			if object then
				Selection:Set({ object })
			end
		end
	end)
end

local shownReview: any = nil

local function renderReview()
	if state.review == shownReview then
		return
	end
	shownReview = state.review
	selectedRow = nil
	for _, child in reviewList:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	local review = state.review
	if not review then
		return
	end
	local s = review.summary
	reviewTitle.Text = "Changes in " .. escape(if state.branch then (state.branch :: Branch).name else "branch")
	reviewSubtitle.Text = "Compared with how the branch started · " .. DateTime.now():FormatLocalTime("LT", "en-us")
	addedChip.Text, removedChip.Text, changedChip.Text = "+ " .. s.added .. " added", "− " .. s.removed .. " removed", "● " .. s.changed .. " changed"
	addedChip.Visible, removedChip.Visible, changedChip.Visible = s.added > 0, s.removed > 0, s.changed > 0
	if #review.rows == 0 then
		local empty = text(reviewList, 1, 14, REGULAR, Color.SubText)
		new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingTop = UDim.new(0, 10), Parent = empty })
		empty.Text = "No changes yet. Build something in this branch, then click Refresh."
	end
	for index, row in review.rows do
		if index > MAX_REVIEW_ROWS then
			local more = text(reviewList, index * 100, 13, REGULAR, Color.DimmedText)
			new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingTop = UDim.new(0, 8), Parent = more })
			more.Text = string.format("…and %d more. Run <b>rogit diff %s</b> in the terminal for the full list.",
				#review.rows - MAX_REVIEW_ROWS + review.truncated, if state.branch then escape((state.branch :: Branch).name) else "")
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
	openReviewButton.Visible = mode == "branch" and idle and state.review ~= nil and not reviewWidget.Enabled
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
