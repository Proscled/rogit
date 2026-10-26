--!strict
-- RoGit Studio plugin. Talks to RoGit (`rogit serve`), which runs in the background on this computer and keeps every
-- game's branches.

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

-- This plugin's version; `rogit plugin install` (and so the installer) fills it in.
local VERSION = "__ROGIT_VERSION__"
-- RoGit takes the first free one of these ports.
local PORTS = { 34875, 34876, 34877, 34878, 34879 }
-- Where RoGit is; see findServer.
local serverBase = "http://127.0.0.1:34875"
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
type Branch = { name: string, created: number, has_starting_point: boolean, merged: number?, updated: number?, pinned: boolean? }
type State = {
	connected: boolean,
	-- The running RoGit's version, and the newest release it knows of.
	version: string?,
	latest: string?,
	game: Game?,
	-- The game of a branch file made before branch files said which game they're from, as RoGit found it.
	branchGame: number?,
	branches: { Branch },
	branch: Branch?,
	isMain: boolean?,
	experience: string?,
	busy: string?,
	notice: string?,
	problem: string?,
	-- The open window of changes: a review, merge, update, revert, restore, commit or history entry.
	view: any?,
	-- A message with buttons, for example "Archive this branch?".
	offer: any?,
	-- The branch whose extra actions (pin, archive) are showing.
	menu: string?,
	commits: { any },
	-- Everything that happened, newest first, for the graph.
	graph: { any },
	-- A branch's changes since its last commit, which of them are staged, and what they're measured from.
	changes: any?,
	staged: { [string]: boolean },
	since: any?,
	-- When unsaved work was found for this branch.
	unsaved: number?,
	-- The branch this window shows, if it was archived.
	archived: string?,
	autosaved: number?,
}

local state: State = { connected = false, branches = {}, commits = {}, graph = {}, staged = {} }

-- Talking to RoGit ---------------------------------------------------------------------------------

-- The game this window is about: the open place's game, or for a branch (a local file) the game it was made from.
local function gameId(): number
	if game.GameId ~= 0 then
		return game.GameId
	end
	local tag = workspace:GetAttribute("RoGitBranch")
	local id = if type(tag) == "string" then tonumber(string.match(tag, "^(%d+):")) else nil
	return id or state.branchGame or 0
end

-- A version ("1.2.3") as a number that sorts like the version.
local function versionRank(version: any): number
	local a, b, c = string.match(tostring(version), "^v?(%d+)%.(%d+)%.(%d+)")
	return (tonumber(a) or 0) * 1e6 + (tonumber(b) or 0) * 1e3 + (tonumber(c) or 0)
end

-- Every request says which game it's about; RoGit keeps each game's branches apart.
local function withGame(path: string): string
	return path .. (if string.find(path, "?", 1, true) then "&" else "?") .. string.format("game=%d", gameId())
end

local function request(method: string, path: string, body: any?, raw: string?): (boolean, any)
	local options: any = { Url = serverBase .. withGame(path), Method = method }
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
		return false, "RoGit sent an unexpected reply."
	end
	if not response.Success then
		return false, value.error or ("RoGit answered HTTP " .. response.StatusCode .. ".")
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

-- This Studio window, so RoGit can tell work from before it opened.
local SESSION = newId(12)
-- Every RoGit ID in this place and its object, once the project is set up. A copy made with Ctrl+D or pasted carries
-- its original's ID; with this, it gets its own right away.
local idOwners: { [string]: Instance }? = nil
-- Whether this window just opened its place (nothing to undo yet), rather than the plugin reloading in a window
-- that's been worked in. Only a window that just opened can be missing unsaved work.
local FRESH_WINDOW = not ChangeHistoryService:GetCanUndo()

-- Collects the objects RoGit tracks: everything saved in the place except scripts and Folders that contain a script
-- anywhere inside.
local function trackedObjects(): ({ Instance }, number)
	local list: { Instance } = {}
	local visited = 0

	local function visit(parent: Instance): boolean
		local hasScript = false
		for _, child in parent:GetChildren() do
			visited += 1
			if visited % 10000 == 0 then
				task.wait()
			end
			if child:IsA("LuaSourceContainer") then
				hasScript = true
			elseif child.Archivable and not child:IsA("Camera") then
				local mark = #list
				table.insert(list, child)
				if visit(child) then
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
		if ok and service then
			visit(service)
		end
	end
	return list, visited
end

-- Gives every tracked object without an ID a short hidden one. Copies made with Ctrl+D share an ID, so
-- repeats get a new one. Records a single undo step, and only when something changes.
local function tagObjects(): { tagged: number, added: number, skipped: number, seconds: number }
	local started = os.clock()
	local objects, visited = trackedObjects()
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
			local id = newId(10)
			if pcall(object.SetAttribute, object, TAG, id) then
				added += 1
				if idOwners then
					idOwners[id] = object
				end
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

-- Starts sending one service's copy in 4 MiB parts. `uploads` tracks the parts still on their way, across services.
local function sendParts(capture: string, service: string, text: string, uploads: { pending: number, failure: string? })
	for i = 1, math.max(1, math.ceil(#text / PART_CHARS)) do
		uploads.pending += 1
		local part = string.sub(text, (i - 1) * PART_CHARS + 1, i * PART_CHARS)
		task.spawn(function()
			local ok, reply = request("POST", string.format("/api/upload?capture=%s&file=%s&part=%d", capture, service, i - 1), nil, part)
			if not ok then
				uploads.failure = reply or "Lost the connection to RoGit."
			end
			uploads.pending -= 1
		end)
	end
end

-- Lists an object and everything inside it as "id|Class", in the order copies keep them (depth first), using
-- Studio's session ID for each object. rogit serve uses these to tell later changes apart.
local function walkIds(object: Instance, out: { string })
	table.insert(out, object:GetDebugId(0) .. "|" .. object.ClassName)
	for _, child in object:GetChildren() do
		if child.Archivable then
			walkIds(child, out)
		end
	end
end

-- Copies every saved service (its children in Roblox's binary format, plus its settings) to rogit serve, with every
-- object's ID when `withIds` is set.
local function copyPlace(capture: string, withIds: boolean?): any
	local services = {}
	local uploads: { pending: number, failure: string? } = { pending = 0, failure = nil }
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
			sendParts(capture, name, buffer.tostring(EncodingService:Base64Encode(data)), uploads)
		end
		local attributes = {}
		for key, value in service:GetAttributes() do
			attributes[key] = encode(value)
		end
		local entry: any = { name = service.Name, className = service.ClassName, settings = serviceSettings(service), attributes = attributes }
		if withIds then
			entry.ids = {}
			for _, child in children do
				walkIds(child, entry.ids)
			end
		end
		table.insert(services, entry)
	end
	while uploads.pending > 0 do
		task.wait()
	end
	if uploads.failure then
		error(uploads.failure, 0)
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
local AMBER = Color3.fromRGB(226, 161, 52)
local GREY = Color3.fromRGB(128, 128, 128)
local HEX = { green = "#3fb950", red = "#ef5350", amber = "#e2a134", grey = "#8c8c8c" }
-- Letters for added, removed and changed objects, like VS Code's Source Control.
local MARK = { added = { "A", GREEN }, removed = { "D", RED }, changed = { "M", AMBER } }

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

local function box(parent: Instance, order: number, gap: number, horizontal: boolean?): Frame
	local frame = new("Frame", {
		LayoutOrder = order, BackgroundTransparency = 1, Size = if horizontal then UDim2.new(0, 0, 0, 26) else UDim2.new(1, 0, 0, 0),
		AutomaticSize = if horizontal then Enum.AutomaticSize.X else Enum.AutomaticSize.Y, Parent = parent,
	})
	stack(frame, gap, horizontal)
	return frame
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

-- A one-line label that sizes to its text, for horizontal rows.
local function inlineText(parent: Instance, order: number, size: number, font: Font, color: any): TextLabel
	local label = text(parent, order, size, font, color, false)
	label.Size = UDim2.new(0, 0, 1, 0)
	label.AutomaticSize = Enum.AutomaticSize.X
	return label
end

local function clear(parent: Instance)
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

type ButtonKind = "primary" | "secondary" | "danger" | "quiet"
local BUTTON_COLORS: { [string]: { [string]: any } } = {
	primary = { BackgroundColor3 = Color.DialogMainButton, TextColor3 = Color.DialogMainButtonText },
	secondary = { BackgroundColor3 = Color.Button, TextColor3 = Color.ButtonText },
	quiet = { BackgroundColor3 = { Color.Button, Modifier.Hover }, TextColor3 = Color.SubText },
}

local function styleButton(b: TextButton, kind: ButtonKind)
	if kind == "danger" then
		themed[b] = nil
		b.BackgroundColor3, b.TextColor3 = RED, Color3.new(1, 1, 1)
	else
		local colors = BUTTON_COLORS[kind]
		themed[b] = colors
		for property, spec in colors do
			(b :: any)[property] = themeColor(spec)
		end
	end
	b.BackgroundTransparency = if kind == "quiet" then 1 else 0
	local stroke = b:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Enabled = kind == "secondary"
	end
end

local function button(parent: Instance, order: number, label: string, kind: ButtonKind, fullWidth: boolean?): TextButton
	local b = new("TextButton", {
		LayoutOrder = order, Text = label, TextSize = 13, FontFace = MEDIUM, AutoButtonColor = true, BorderSizePixel = 0,
		Size = if fullWidth then UDim2.new(1, 0, 0, 28) else UDim2.new(0, 0, 0, 26),
		AutomaticSize = if fullWidth then Enum.AutomaticSize.None else Enum.AutomaticSize.X, Parent = parent,
	})
	round(b, 4)
	new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = b }, { Color = Color.ButtonBorder })
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = b })
	styleButton(b, kind)
	if kind == "quiet" then
		b.MouseEnter:Connect(function()
			b.BackgroundTransparency = 0
		end)
		b.MouseLeave:Connect(function()
			b.BackgroundTransparency = 1
		end)
	end
	return b
end

-- A text box with a button on its right.
local function field(parent: Instance, order: number, placeholder: string, label: string): (TextBox, TextButton)
	local row = new("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), Parent = parent })
	local input = new("TextBox", {
		Size = UDim2.new(1, -80, 1, 0), PlaceholderText = placeholder, Text = "", ClearTextOnFocus = false, TextSize = 13,
		FontFace = REGULAR, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, BorderSizePixel = 0,
		Parent = row,
	}, { BackgroundColor3 = Color.InputFieldBackground, TextColor3 = Color.MainText, PlaceholderColor3 = Color.DimmedText })
	round(input, 4)
	new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = input }, { Color = Color.InputFieldBorder })
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = input })
	local b = button(row, 2, label, "primary")
	b.AutomaticSize = Enum.AutomaticSize.None
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.fromScale(1, 0)
	b.Size = UDim2.new(0, 74, 1, 0)
	return input, b
end

-- A titled group: a small capitals heading over its contents.
local function section(parent: Instance, order: number): (Frame, TextLabel, Frame)
	local frame = box(parent, order, 6)
	local heading = text(frame, 1, 11, BOLD, Color.DimmedText, false)
	local body = box(frame, 2, 2)
	return frame, heading, body
end

-- A list row that lights up under the mouse, like Studio's lists.
local function listRow(parent: Instance, order: number, height: number): TextButton
	local row = new("TextButton", {
		LayoutOrder = order, Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height), Parent = parent,
	}, { BackgroundColor3 = { Color.Item, Modifier.Hover } })
	round(row, 4)
	row.MouseEnter:Connect(function()
		row.BackgroundTransparency = 0
	end)
	row.MouseLeave:Connect(function()
		row.BackgroundTransparency = 1
	end)
	return row
end

local function escape(value: string): string
	return (string.gsub(value, "[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

local function formatTime(seconds: number): string
	return DateTime.fromUnixTimestamp(seconds):FormatLocalTime("lll", "en-us")
end

local function clock(seconds: number): string
	return DateTime.fromUnixTimestamp(seconds):FormatLocalTime("LT", "en-us")
end

local function ago(seconds: number): string
	local passed = os.time() - seconds
	if passed < 60 then
		return "just now"
	elseif passed < 3600 then
		return math.floor(passed / 60) .. " min ago"
	elseif passed < 86400 then
		return math.floor(passed / 3600) .. " h ago"
	end
	return math.floor(passed / 86400) .. " d ago"
end

-- "2 added, 1 changed", with colored numbers.
local function counts(summary: any): string
	local parts = {}
	local function add(n: number?, label: string, hex: string)
		if n and n > 0 then
			table.insert(parts, string.format('<font color="%s">%d</font> %s', hex, n, label))
		end
	end
	add(summary.added, "added", HEX.green)
	add(summary.removed, "removed", HEX.red)
	add(summary.changed, "changed", HEX.amber)
	if summary.conflicts and summary.conflicts > 0 then
		add(summary.conflicts, if summary.conflicts == 1 then "conflict" else "conflicts", HEX.red)
	end
	return if #parts == 0 then "No changes" else table.concat(parts, "   ")
end

-- Main panel ---------------------------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("RoGit")
local toggle = toolbar:CreateButton("RoGit", "Open the RoGit panel", "")
toggle.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"RoGitPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 300, 440, 260, 240)
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
stack(root, 14)

-- Where you are, and whether rogit serve is there.
local top = box(root, 1, 2)
local kindRow = new("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 14), Parent = top })
local placeKind = text(kindRow, 1, 11, BOLD, Color.DimmedText, false)
placeKind.AutomaticSize = Enum.AutomaticSize.None
placeKind.Size = UDim2.new(1, -90, 1, 0)
local connection = text(kindRow, 2, 11, MEDIUM, GREY, false)
connection.AutomaticSize = Enum.AutomaticSize.None
connection.AnchorPoint = Vector2.new(1, 0)
connection.Position = UDim2.fromScale(1, 0)
connection.Size = UDim2.new(0, 90, 1, 0)
connection.TextXAlignment = Enum.TextXAlignment.Right
local placeTitle = text(top, 2, 18, BOLD, Color.MainText, false)
placeTitle.TextTruncate = Enum.TextTruncate.AtEnd
local placeDetail = text(top, 3, 12, REGULAR, Color.SubText)
-- A newer RoGit, or RoGit and this plugin being different versions.
local updateNote = text(top, 4, 12, MEDIUM, AMBER)

-- What just happened, or what's going on, with buttons when there's something to decide.
local messageBox = box(root, 2, 8)
local message = text(messageBox, 1, 13, REGULAR, Color.SubText)
local messageActions = box(messageBox, 2, 6, true)

-- Unsaved work found when a branch opens (for example after Studio closed unexpectedly).
local unsavedCard = new("Frame", {
	LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = root,
}, { BackgroundColor3 = Color.Titlebar })
round(unsavedCard, 4)
new("UIStroke", { Thickness = 1, Color = AMBER, Transparency = 0.3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = unsavedCard })
pad(unsavedCard, 10, 10)
stack(unsavedCard, 8)
local unsavedText = text(unsavedCard, 1, 13, MEDIUM, Color.MainText)
local unsavedButtons = box(unsavedCard, 2, 6, true)
local restoreButton = button(unsavedButtons, 1, "Restore", "primary")
local dismissButton = button(unsavedButtons, 2, "Dismiss", "quiet")

local actions = box(root, 4, 6)
local initButton = button(actions, 1, "Init", "primary", true)

local newSection, newHeading, newBody = section(root, 5)
newHeading.Text = "NEW BRANCH"
local nameBox, createButton = field(newBody, 1, "branch-name", "Create")

local branchesSection, branchesHeading, branchRows = section(root, 6)

-- In a branch, like VS Code's Source Control: a message, Commit, Pull, and the changes not committed yet.
local sourceSection = box(root, 7, 6)
local commitBox = new("TextBox", {
	LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 28), PlaceholderText = "Message (Enter to commit)", Text = "", ClearTextOnFocus = false,
	TextSize = 13, FontFace = REGULAR, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	BorderSizePixel = 0, Parent = sourceSection,
}, { BackgroundColor3 = Color.InputFieldBackground, TextColor3 = Color.MainText, PlaceholderColor3 = Color.DimmedText })
round(commitBox, 4)
new("UIStroke", { Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = commitBox }, { Color = Color.InputFieldBorder })
new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = commitBox })
local commitButton = button(sourceSection, 2, "Commit", "primary", true)
local pullButton = button(sourceSection, 3, "Pull from main", "secondary", true)

-- A list of changes with a heading and small buttons on its right ("Discard all", "Stage all").
local function changeSection(order: number, actions: { string }): (Frame, TextLabel, Frame, { TextButton })
	local frame = box(root, order, 2)
	local head = new("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), Parent = frame })
	local heading = text(head, 1, 11, BOLD, Color.DimmedText, false)
	heading.AutomaticSize = Enum.AutomaticSize.None
	heading.Size = UDim2.new(1, -160, 1, 0)
	heading.TextYAlignment = Enum.TextYAlignment.Center
	local holder = box(head, 2, 0, true)
	holder.AnchorPoint = Vector2.new(1, 0.5)
	holder.Position = UDim2.fromScale(1, 0.5)
	holder.Size = UDim2.new(0, 0, 0, 20)
	local buttons = {}
	for i, action in actions do
		local b = button(holder, i, action, "quiet")
		b.Size = UDim2.new(0, 0, 0, 20)
		b.TextSize = 12
		table.insert(buttons, b)
	end
	local body = box(frame, 2, 0)
	return frame, heading, body, buttons
end
local stagedSection, stagedHeading, stagedRows, stagedButtons = changeSection(8, { "Unstage all" })
local changesSection, changesHeading, changesRows, changesButtons = changeSection(9, { "Discard all", "Stage all" })
local unstageAllButton = stagedButtons[1]
local discardAllButton, stageAllButton = changesButtons[1], changesButtons[2]

local graphSection, graphHeading, graphRows = section(root, 10)
graphHeading.Text = "GRAPH"
graphRows:FindFirstChildOfClass("UIListLayout").Padding = UDim.new(0, 0)

local render: () -> ()
local openBranch: (string) -> ()
local startMerge: (string) -> ()
local setPinned: (string, boolean) -> ()
local confirmArchive: (string) -> ()
local openHistory: (any) -> ()
local viewCommit: (any, string) -> ()
local startRevert: (any) -> ()
local selectObject: (string) -> ()
local discard: ({ string }) -> ()
local flushChanges: () -> boolean
local setStaged: ({ string }) -> ()

local shownBranches = ""

local function renderBranches()
	local key = tostring(state.menu)
	for _, branch in state.branches do
		key ..= string.format("|%s:%s:%s:%s", branch.name, tostring(branch.merged), tostring(branch.pinned), ago(branch.merged or branch.created))
	end
	if key == shownBranches then
		return
	end
	shownBranches = key
	clear(branchRows)
	branchesHeading.Text = string.format('BRANCHES  <font color="%s">%d</font>', HEX.grey, #state.branches)
	for index, branch in state.branches do
		local row = box(branchRows, index, 4)
		local line = new("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = row })
		local name = text(line, 1, 14, MEDIUM, Color.MainText, false)
		name.AutomaticSize = Enum.AutomaticSize.None
		name.Size = UDim2.new(1, -150, 0, 18)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = (if branch.pinned then "📌 " else "") .. escape(branch.name)
		local caption = text(line, 2, 12, REGULAR, Color.DimmedText, false)
		caption.AutomaticSize = Enum.AutomaticSize.None
		caption.Position = UDim2.fromOffset(0, 18)
		caption.Size = UDim2.new(1, -150, 0, 16)
		caption.TextTruncate = Enum.TextTruncate.AtEnd
		caption.Text = if branch.merged then "merged " .. ago(branch.merged) else "made " .. ago(branch.created)
		local buttons = box(line, 3, 4, true)
		buttons.AnchorPoint = Vector2.new(1, 0.5)
		buttons.Position = UDim2.fromScale(1, 0.5)
		button(buttons, 1, "Open", "secondary").Activated:Connect(function()
			openBranch(branch.name)
		end)
		button(buttons, 2, "Merge", "primary").Activated:Connect(function()
			startMerge(branch.name)
		end)
		local more = button(buttons, 3, "···", "quiet")
		more.Activated:Connect(function()
			state.menu = if state.menu == branch.name then nil else branch.name
			render()
		end)
		if state.menu == branch.name then
			local menu = box(row, 2, 4, true)
			button(menu, 1, if branch.pinned then "Unpin" else "Pin", "secondary").Activated:Connect(function()
				setPinned(branch.name, not branch.pinned)
			end)
			button(menu, 2, "Archive…", "secondary").Activated:Connect(function()
				state.menu = nil
				confirmArchive(branch.name)
			end)
		end
	end
end

local KIND_TEXT = {
	create = "Created %s", merge = "Merged %s into main", update = "Pulled main into %s", revert = "Reverted %s",
	restore = "Restored unsaved work in %s", archive = "Archived %s",
}

-- Luau allows 200 locals in one scope; sections that keep theirs to themselves live in blocks like this one.
local renderGraph: () -> ()
do
	-- The graph, like VS Code's: a lane for main and one for each branch while it exists, newest at the top.
	local LANE_COLORS = {
		Color3.fromRGB(77, 156, 255), Color3.fromRGB(229, 192, 123), Color3.fromRGB(224, 108, 159), Color3.fromRGB(209, 154, 102),
		Color3.fromRGB(86, 182, 194), Color3.fromRGB(198, 120, 221), Color3.fromRGB(152, 195, 121),
	}
	local LANE_WIDTH = 12
	local GRAPH_ROW = 26
	local MAX_LANES = 6
	local shownGraph = ""

	local function laneColor(lane: number): Color3
		return LANE_COLORS[(lane % #LANE_COLORS) + 1]
	end

	-- Each branch's lane, and the lanes in use at each row. Events are newest first; a branch's lane runs from its
	-- oldest event (usually "create") to its archive.
	local function lanes(events: { any }): ({ [string]: number }, { { [number]: boolean } }, { [string]: number })
		local born, ended = {}, {}
		for i = #events, 1, -1 do
			local event = events[i]
			if born[event.branch] == nil then
				born[event.branch] = i
			end
			if event.kind == "archive" then
				ended[event.branch] = i
			end
		end
		local laneOf, used, active = {}, {}, {}
		for i = #events, 1, -1 do
			local event = events[i]
			if born[event.branch] == i then
				local lane = 1
				while used[lane] and lane < MAX_LANES do
					lane += 1
				end
				used[lane] = true
				laneOf[event.branch] = lane
			end
			local row = {}
			for lane in used do
				row[lane] = true
			end
			active[i] = row
			if ended[event.branch] == i then
				used[laneOf[event.branch]] = nil
			end
		end
		return laneOf, active, born
	end

	local function graphLine(parent: Instance, x: number, from: number, to: number, color: Color3)
		new("Frame", {
			Position = UDim2.fromOffset(x - 1, from), Size = UDim2.fromOffset(2, to - from), BackgroundColor3 = color,
			BorderSizePixel = 0, Parent = parent,
		})
	end

	renderGraph = function()
		local events = state.graph
		local key = ""
		for _, event in events do
			key ..= event.id .. ago(event.time)
		end
		if key == shownGraph then
			return
		end
		shownGraph = key
		clear(graphRows)
		local laneOf, active, born = lanes(events)
		local widest = 0
		for _, lane in laneOf do
			widest = math.max(widest, lane)
		end
		local width = 8 + (widest + 1) * LANE_WIDTH
		local middle = GRAPH_ROW / 2
		local function x(lane: number): number
			return 8 + lane * LANE_WIDTH
		end
		for index, event in events do
			local row = listRow(graphRows, index, GRAPH_ROW)
			local lane = laneOf[event.branch] or 0
			-- Main's lane runs through every row; it starts at the oldest and ends at the newest.
			graphLine(row, x(0), if index == 1 then middle else 0, if index == #events then middle else GRAPH_ROW, laneColor(0))
			for used in active[index] do
				local from, to = 0, GRAPH_ROW
				if used == lane and born[event.branch] == index then
					to = middle -- the branch starts here
				end
				if used == lane and event.kind == "archive" then
					from = middle -- and ends here
				end
				graphLine(row, x(used), from, to, laneColor(used))
			end
			-- Branching off, merging and pulling join the branch's lane to main's.
			if event.kind == "create" or event.kind == "merge" or event.kind == "update" then
				new("Frame", {
					Position = UDim2.fromOffset(x(0), middle - 1), Size = UDim2.fromOffset(x(lane) - x(0), 2),
					BackgroundColor3 = laneColor(lane), BorderSizePixel = 0, Parent = row,
				})
			end
			local dotLane = if event.kind == "merge" then 0 else lane
			local ring = event.kind == "merge" or event.kind == "update"
			local size = if event.kind == "create" or event.kind == "archive" then 6 else 9
			local dot = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x(dotLane), middle), Size = UDim2.fromOffset(size, size),
				BackgroundColor3 = laneColor(dotLane), BorderSizePixel = 0, ZIndex = 2, Parent = row,
			}, if ring then { BackgroundColor3 = Color.MainBackground } else nil)
			round(dot, size)
			if ring then
				new("UIStroke", { Thickness = 2, Color = laneColor(dotLane), Parent = dot })
			end
			local branchText = string.format('<font color="#%s">%s</font>', laneColor(lane):ToHex(), escape(event.branch))
			local label = text(row, 1, 13, REGULAR, if event.kind == "commit" then Color.MainText else Color.SubText, false)
			label.AutomaticSize = Enum.AutomaticSize.None
			label.Position = UDim2.fromOffset(width + 2, 0)
			label.Size = UDim2.new(1, -(width + 2 + 58), 1, 0)
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.Text = if event.kind == "commit"
				then escape(event.message or "") .. "  " .. branchText
				else string.format(KIND_TEXT[event.kind] or "%s", branchText)
			local when = text(row, 2, 12, REGULAR, Color.DimmedText, false)
			when.AutomaticSize = Enum.AutomaticSize.None
			when.AnchorPoint = Vector2.new(1, 0)
			when.Position = UDim2.new(1, -4, 0, 0)
			when.Size = UDim2.new(0, 56, 1, 0)
			when.TextXAlignment = Enum.TextXAlignment.Right
			when.Text = string.gsub(ago(event.time), " ago", "")
			row.Activated:Connect(function()
				if event.has_rows then
					openHistory(event)
				elseif event.kind == "commit" then
					viewCommit({ id = event.id, message = event.message, time = event.time }, event.branch)
				end
			end)
		end
	end
end

-- What a branch's changes are measured from, in words.
local function sinceText(): string
	local since = state.since
	if since and since.kind == "commit" then
		return "“" .. since.message .. "”"
	elseif since and since.kind == "update" then
		return "the last pull from main"
	end
	return "the branch was made"
end

-- A branch's changes as a flat list (each with its parent's path), split into staged and not staged.
local function changeList(): ({ any }, { any })
	local staged, unstaged = {}, {}
	if not state.changes then
		return staged, unstaged
	end
	local names = {}
	for _, row in state.changes.rows do
		names[row.depth] = row.name
		if row.status ~= "context" then
			local path = {}
			for depth = 0, row.depth - 1 do
				table.insert(path, names[depth])
			end
			table.insert(if state.staged[row.key] then staged else unstaged, { row = row, path = table.concat(path, "/") })
		end
	end
	return staged, unstaged
end

local function stagedKeys(): { string }
	local keys = {}
	for key in state.staged do
		table.insert(keys, key)
	end
	return keys
end

-- Changes whose details are showing in the panel, by key.
local expandedChanges: { [string]: boolean } = {}
local shownChanges = ""

-- One property change under its row: "Color  91, 91, 91 → 255, 0, 0".
local function changeDetail(parent: Instance, order: number, change: any)
	local line = new("Frame", { LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), Parent = parent })
	local label = text(line, 1, 12, REGULAR, Color.SubText, false)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.Position = UDim2.fromOffset(26, 0)
	label.Size = UDim2.new(1, -30, 1, 0)
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = if change.old == ""
		then string.format('<font color="%s">%s</font>  %s', HEX.grey, escape(change.name), escape(change.new))
		else string.format(
			'<font color="%s">%s</font>  <font color="%s"><s>%s</s></font>  →  <font color="%s">%s</font>',
			HEX.grey, escape(change.name), HEX.red, escape(change.old), HEX.green, escape(change.new)
		)
end

local function changeRow(parent: Instance, order: number, item: any, isStaged: boolean)
	local row = item.row
	local frame = listRow(parent, order * 100, 24)
	local icon = new("ImageLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(16, 16), Parent = frame })
	local ok, image = pcall(StudioService.GetClassIcon, StudioService, row.class)
	if ok and image then
		icon.Image, icon.ImageRectOffset, icon.ImageRectSize = image.Image, image.ImageRectOffset, image.ImageRectSize
	end
	local name = text(frame, 1, 13, REGULAR, Color.MainText, false)
	name.AutomaticSize = Enum.AutomaticSize.None
	name.Position = UDim2.fromOffset(26, 0)
	name.Size = UDim2.new(1, -(26 + 52), 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local shown = escape(row.name)
	if row.status == "removed" then
		shown = "<s>" .. shown .. "</s>"
	end
	if item.path ~= "" then
		shown ..= string.format('  <font color="%s" size="11">%s</font>', HEX.grey, escape(item.path))
	end
	name.Text = shown
	local mark = MARK[row.status]
	if mark then
		local letter = text(frame, 2, 12, BOLD, mark[2], false)
		letter.AutomaticSize = Enum.AutomaticSize.None
		letter.AnchorPoint = Vector2.new(1, 0)
		letter.Position = UDim2.new(1, -30, 0, 0)
		letter.Size = UDim2.new(0, 14, 1, 0)
		letter.TextXAlignment = Enum.TextXAlignment.Right
		letter.Text = mark[1]
	end
	local toggle = button(frame, 3, if isStaged then "−" else "+", "quiet")
	toggle:FindFirstChildOfClass("UIPadding"):Destroy()
	toggle.AutomaticSize = Enum.AutomaticSize.None
	toggle.AnchorPoint = Vector2.new(1, 0.5)
	toggle.Position = UDim2.new(1, -2, 0.5, 0)
	toggle.Size = UDim2.fromOffset(22, 20)
	toggle.TextSize = 16
	toggle.Activated:Connect(function()
		local keys = stagedKeys()
		if isStaged then
			table.remove(keys, table.find(keys, row.key) :: number)
		else
			table.insert(keys, row.key)
		end
		setStaged(keys)
	end)
	if not isStaged then
		local discardButton = button(frame, 4, "Discard", "secondary")
		discardButton.AnchorPoint = Vector2.new(1, 0.5)
		discardButton.Position = UDim2.new(1, -26, 0.5, 0)
		discardButton.Size = UDim2.new(0, 0, 0, 20)
		discardButton.TextSize = 12
		discardButton.ZIndex = 2
		discardButton.Visible = false
		frame.MouseEnter:Connect(function()
			discardButton.Visible = true
		end)
		frame.MouseLeave:Connect(function()
			discardButton.Visible = false
		end)
		discardButton.Activated:Connect(function()
			discard({ row.key })
		end)
	end
	-- Clicking a change shows what changed under it, and selects the object in Studio.
	frame.Activated:Connect(function()
		expandedChanges[row.key] = not expandedChanges[row.key] or nil
		shownChanges = ""
		render()
		selectObject(row.key)
	end)
	if expandedChanges[row.key] then
		for i, change in row.changes do
			changeDetail(parent, order * 100 + math.min(i, 99), change)
		end
	end
end

local MAX_CHANGE_ROWS = 200
local stagedCount, unstagedCount = 0, 0

local function renderChanges()
	local key = tostring(state.changes)
	for staged in state.staged do
		key ..= "|" .. staged
	end
	if key == shownChanges then
		return
	end
	shownChanges = key
	clear(stagedRows)
	clear(changesRows)
	local staged, unstaged = changeList()
	stagedCount, unstagedCount = #staged, #unstaged
	stagedHeading.Text = string.format('STAGED CHANGES  <font color="%s">%d</font>', HEX.grey, #staged)
	changesHeading.Text = string.format('CHANGES  <font color="%s">%d</font>', HEX.grey, #unstaged)
	stageAllButton.Visible = #unstaged > 0
	discardAllButton.Visible = #unstaged > 0
	for list, items in { [stagedRows] = staged, [changesRows] = unstaged } do
		for i, item in items do
			if i > MAX_CHANGE_ROWS then
				local more = text(list, i * 100, 12, REGULAR, Color.DimmedText)
				more.Text = string.format("…and %d more.", #items - MAX_CHANGE_ROWS)
				break
			end
			changeRow(list, i, item, list == stagedRows)
		end
	end
	if #unstaged == 0 then
		local empty = text(changesRows, 1, 12, REGULAR, Color.DimmedText)
		new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingTop = UDim.new(0, 2), Parent = empty })
		empty.Text = if state.changes == nil then "Looking for changes…"
			elseif #staged > 0 then "Everything else is committed."
			else "No changes since " .. escape(sinceText()) .. "."
	end
end

-- Changes window: a branch's changes, a merge, an update or a revert, laid out like Studio's Explorer ----

local SINCE: { [string]: string }
local KINDS: { [string]: any }
local reviewWidget: DockWidgetPluginGui
local closeButton: TextButton
local applyButton: TextButton
local findObject: (string, { [string]: Instance }?) -> Instance?
local renderView: () -> ()
local showView: (any) -> ()
do
	local MAX_ROWS = 600
	local ROW_HEIGHT = 24
	local INDENT = 16
	SINCE = { start = "Since the branch started", merge = "Since the last merge", update = "Since the last update from main" }

	-- What each kind of window says and does. "Keep" leaves this place as it is; "use" takes the incoming side.
	KINDS = {
		review = { empty = "No changes yet." },
		history = { empty = "Nothing changed." },
		commit = { empty = "Nothing changed in this commit." },
		merge = {
			apply = "Merge", keep = "Keep main", use = "Use branch", remove = "Remove it from main?",
			restore = "Bring it back from the branch?", empty = "Nothing to merge: main has everything in this branch.",
		},
		update = {
			apply = "Pull", keep = "Keep branch", use = "Use main", remove = "Remove it from the branch?",
			restore = "Bring it back from main?", empty = "Already up to date with main.",
		},
		revert = { apply = "Revert", empty = "The branch already matches this commit." },
		restore = { apply = "Restore", empty = "Nothing to restore." },
	}

	reviewWidget = plugin:CreateDockWidgetPluginGui(
		"RoGitReview",
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 560, 600, 380, 280)
	)
	reviewWidget.Title = "RoGit"

	local reviewRoot = new("Frame", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = reviewWidget }, { BackgroundColor3 = Color.MainBackground })
	local reviewHeader = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = reviewRoot,
	}, { BackgroundColor3 = Color.Titlebar })
	pad(reviewHeader, 10, 12)
	stack(reviewHeader, 3)
	local viewTitle = text(reviewHeader, 1, 15, BOLD, Color.MainText, false)
	viewTitle.TextTruncate = Enum.TextTruncate.AtEnd
	local viewSubtitle = text(reviewHeader, 2, 12, REGULAR, Color.DimmedText, false)
	local viewCounts = text(reviewHeader, 3, 12, MEDIUM, Color.SubText, false)
	local headerLine = new("Frame", { Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0, Parent = reviewRoot }, { BackgroundColor3 = Color.Border })

	local list = new("ScrollingFrame", {
		BorderSizePixel = 0, BackgroundTransparency = 1, ScrollBarThickness = 6, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Parent = reviewRoot,
	}, { ScrollBarImageColor3 = Color.ScrollBar })
	new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = list })
	stack(list, 0)

	local footer = new("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 44), BorderSizePixel = 0, Parent = reviewRoot,
	}, { BackgroundColor3 = Color.Titlebar })
	new("Frame", { Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0, Parent = footer }, { BackgroundColor3 = Color.Border })
	local footerLeft = box(footer, 1, 6, true)
	footerLeft.AnchorPoint = Vector2.new(0, 0.5)
	footerLeft.Position = UDim2.new(0, 12, 0.5, 0)
	local footerText = inlineText(footerLeft, 1, 12, REGULAR, Color.DimmedText)
	local keepAllButton = button(footerLeft, 2, "", "quiet")
	local useAllButton = button(footerLeft, 3, "", "quiet")
	local footerRight = box(footer, 2, 6, true)
	footerRight.AnchorPoint = Vector2.new(1, 0.5)
	footerRight.Position = UDim2.new(1, -12, 0.5, 0)
	closeButton = button(footerRight, 1, "Cancel", "secondary")
	applyButton = button(footerRight, 2, "Merge", "primary")

	-- The list fills the space between the header and the footer.
	local function layoutReview()
		local top = reviewHeader.AbsoluteSize.Y
		headerLine.Position = UDim2.fromOffset(0, top)
		list.Position = UDim2.fromOffset(0, top + 1)
		list.Size = UDim2.new(1, 0, 1, -(top + 1 + footer.AbsoluteSize.Y))
	end
	reviewHeader:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutReview)
	reviewWidget:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutReview)
	reviewWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
		task.defer(layoutReview)
	end)

	-- Finds a live object by review key: RoGit ID, service, or path for untagged objects. `ids` is an optional
	-- RoGitId -> object map, so repeated lookups don't scan the place each time.
	findObject = function(key: string, ids: { [string]: Instance }?): Instance?
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

	type ViewRow = { row: any, frame: TextButton, details: { Frame }, chevron: TextButton, expanded: boolean, hasChildren: boolean }
	local viewRows: { ViewRow } = {}
	local selectedRow: ViewRow? = nil
	local choiceShows: { () -> () } = {}
	local shownData: any = nil
	local updateFooter: () -> ()

	-- Shows rows and detail lines the way Explorer does: a collapsed row hides everything inside it.
	local function updateVisibility()
		local hideBelow: number? = nil
		for _, v in viewRows do
			local depth = v.row.depth
			local visible = hideBelow == nil or depth <= hideBelow
			if visible then
				hideBelow = if v.expanded then nil else depth
			end
			v.frame.Visible = visible
			for _, detail in v.details do
				detail.Visible = visible and v.expanded
			end
			local canOpen = v.hasChildren or #v.details > 0
			v.chevron.Text = if canOpen then "›" else ""
			v.chevron.Rotation = if v.expanded and canOpen then 90 else 0
		end
	end

	local function paintRow(v: ViewRow, hover: boolean)
		local isSelected = selectedRow == v
		v.frame.BackgroundTransparency = if isSelected or hover then 0 else 1
		v.frame.BackgroundColor3 = themeColor({ Color.Item, if isSelected then Modifier.Selected else Modifier.Hover })
	end

	-- "Keep main" / "Use branch" (or "Keep branch" / "Use main" in an update) for one conflict.
	local function choice(parent: Instance, id: number)
		local view = state.view
		local words = KINDS[view.kind]
		local holder = box(parent, 9, 4, true)
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -10, 0.5, 0)
		holder.Size = UDim2.new(0, 0, 0, 20)
		local keep = button(holder, 1, words.keep, "secondary")
		local use = button(holder, 2, words.use, "secondary")
		for _, b in { keep, use } do
			b.Size = UDim2.new(0, 0, 0, 20)
			b.TextSize = 12
		end
		local function show()
			local picked = view.choices[id]
			styleButton(keep, if picked == "keep" then "primary" else "secondary")
			styleButton(use, if picked == "use" then "primary" else "secondary")
		end
		keep.Activated:Connect(function()
			view.choices[id] = "keep"
			show()
			updateFooter()
		end)
		use.Activated:Connect(function()
			view.choices[id] = "use"
			show()
			updateFooter()
		end)
		table.insert(choiceShows, show)
		show()
	end

	local function colorOf(value: string): Color3?
		local r, g, b = string.match(value, "^(%d+), (%d+), (%d+)$")
		return if r then Color3.fromRGB(tonumber(r) :: number, tonumber(g) :: number, tonumber(b) :: number) else nil
	end

	local function detailLine(order: number, indent: number, change: any): Frame
		local line = new("Frame", {
			LayoutOrder = order, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), ClipsDescendants = true, Parent = list,
		})
		local name = text(line, 1, 12, REGULAR, Color.DimmedText, false)
		name.AutomaticSize = Enum.AutomaticSize.None
		name.Position = UDim2.fromOffset(indent, 0)
		name.Size = UDim2.new(0, 110, 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = escape(change.name)
		local values = box(line, 2, 5, true)
		values.Position = UDim2.fromOffset(indent + 116, 0)
		values.Size = UDim2.new(0, 0, 1, 0)
		local isColor = string.find(change.name, "Color") ~= nil
		local function value(order: number, shown: string, hex: string, struck: boolean)
			local color = if isColor then colorOf(shown) else nil
			if color then
				local swatch = new("Frame", { LayoutOrder = order, Size = UDim2.fromOffset(10, 10), BackgroundColor3 = color, BorderSizePixel = 0, Parent = values })
				round(swatch, 2)
				new("UIStroke", { Thickness = 1, Parent = swatch }, { Color = Color.Border })
			end
			local label = inlineText(values, order + 1, 12, REGULAR, Color.MainText)
			label.Text = string.format('<font color="%s">%s</font>', hex, if struck then "<s>" .. escape(shown) .. "</s>" else escape(shown))
		end
		if change.old == "" then
			inlineText(values, 1, 12, REGULAR, Color.SubText).Text = escape(change.new)
		else
			value(1, change.old, HEX.red, true)
			inlineText(values, 3, 12, REGULAR, Color.DimmedText).Text = "→"
			value(4, change.new, HEX.green, false)
		end
		if change.conflict then
			choice(line, change.conflict)
		end
		return line
	end

	local lastClick = { row = nil :: ViewRow?, time = 0 }

	local function viewRow(index: number, row: any): ViewRow
		local words = KINDS[state.view.kind]
		local indent = 4 + row.depth * INDENT
		local frame = new("TextButton", {
			LayoutOrder = index * 100, Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT), Parent = list,
		})
		local chevron = new("TextButton", {
			Text = "", TextSize = 15, FontFace = BOLD, BackgroundTransparency = 1, Position = UDim2.fromOffset(indent, 0),
			Size = UDim2.fromOffset(16, ROW_HEIGHT), ZIndex = 2, Parent = frame,
		}, { TextColor3 = Color.DimmedText })
		local icon = new("ImageLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(indent + 18, 4), Size = UDim2.fromOffset(16, 16), Parent = frame })
		local ok, image = pcall(StudioService.GetClassIcon, StudioService, row.class)
		if ok and image then
			icon.Image, icon.ImageRectOffset, icon.ImageRectSize = image.Image, image.ImageRectOffset, image.ImageRectSize
		end
		-- Sizes and moves read inline, next to the name; property changes become detail lines.
		local inline, changes = "", {}
		for _, change in row.changes do
			if change.name == "Contains" then
				inline = change.new .. " inside"
			elseif change.name == "Moved with it" then
				inline = "moved with " .. change.new
			elseif change.name == "Moved inside" then
				inline = change.new .. " moved"
			else
				table.insert(changes, change)
			end
		end
		local conflicted = row.conflict ~= nil
		for _, change in changes do
			conflicted = conflicted or change.conflict ~= nil
		end
		local name = text(frame, 1, 13, REGULAR, Color.MainText, false)
		name.AutomaticSize = Enum.AutomaticSize.None
		name.Position = UDim2.fromOffset(indent + 40, 0)
		name.Size = UDim2.new(1, -(indent + 40 + 34), 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local shown = escape(row.name)
		if row.status == "added" then
			shown = string.format('<font color="%s">%s</font>', HEX.green, shown)
		elseif row.status == "removed" then
			shown = string.format('<font color="%s"><s>%s</s></font>', HEX.red, shown)
		elseif row.status == "context" then
			name.TextColor3 = themeColor(Color.SubText)
			themed[name] = { TextColor3 = Color.SubText }
		end
		if inline ~= "" then
			shown ..= string.format('  <font color="%s" size="12">%s</font>', HEX.grey, escape(inline))
		end
		name.Text = shown
		local mark = MARK[row.status]
		if mark or conflicted then
			local badge = text(frame, 2, 12, BOLD, if conflicted then RED else mark[2], false)
			badge.AutomaticSize = Enum.AutomaticSize.None
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.new(1, -12, 0, 0)
			badge.Size = UDim2.new(0, 20, 1, 0)
			badge.TextXAlignment = Enum.TextXAlignment.Right
			badge.Text = if conflicted then "!" else mark[1]
		end
		local v: ViewRow = { row = row, frame = frame, details = {}, chevron = chevron, expanded = true, hasChildren = false }
		for i, change in changes do
			table.insert(v.details, detailLine(index * 100 + math.min(i, 98), indent + 40, change))
		end
		if row.conflict and words.remove then
			table.insert(v.details, detailLine(index * 100 + 99, indent + 40, {
				name = "Choose", old = "", new = if row.status == "removed" then words.remove else words.restore, conflict = row.conflict,
			}))
		end
		v.expanded = row.status == "context" or conflicted or #v.details <= 3
		local function toggleRow()
			v.expanded = not v.expanded
			updateVisibility()
		end
		chevron.Activated:Connect(toggleRow)
		frame.MouseEnter:Connect(function()
			paintRow(v, true)
		end)
		frame.MouseLeave:Connect(function()
			paintRow(v, false)
		end)
		frame.Activated:Connect(function()
			-- A second click soon after the first opens or closes the row, like in Explorer.
			if lastClick.row == v and os.clock() - lastClick.time < 0.35 then
				toggleRow()
			end
			lastClick.row, lastClick.time = v, os.clock()
			local previous = selectedRow
			selectedRow = v
			if previous and previous ~= v then
				paintRow(previous, false)
			end
			paintRow(v, true)
			local object = findObject(row.key)
			if object then
				Selection:Set({ object })
			end
		end)
		return v
	end

	updateFooter = function()
		local view = state.view
		if not view then
			return
		end
		local kind = KINDS[view.kind]
		local data = view.data
		local conflicts = data.conflicts or {}
		local open = 0
		for _, conflict in conflicts do
			if not view.choices[conflict.id] then
				open += 1
			end
		end
		keepAllButton.Visible, useAllButton.Visible = #conflicts > 0, #conflicts > 0
		keepAllButton.Text, useAllButton.Text = (kind.keep or "") .. " for all", (kind.use or "") .. " for all"
		footerText.Text = if open > 0 then string.format("%d conflict%s to decide", open, if open == 1 then "" else "s")
			elseif #conflicts > 0 then "All conflicts decided"
			else ""
		footerText.Visible = footerText.Text ~= ""
		closeButton.Text = if kind.apply then "Cancel" else "Close"
		closeButton.Visible = view.kind ~= "review"
		if view.kind == "review" then
			applyButton.Visible, applyButton.Text, applyButton.AutoButtonColor = true, "Refresh", true
			styleButton(applyButton, "secondary")
			view.ready = true
		elseif view.kind == "commit" then
			applyButton.Visible, applyButton.Text, applyButton.AutoButtonColor = view.canRevert == true, "Revert to this", true
			styleButton(applyButton, "secondary")
			view.ready = true
		elseif kind.apply then
			view.ready = open == 0 and #data.operations > 0
			applyButton.Visible, applyButton.Text = #data.operations > 0, kind.apply
			styleButton(applyButton, "primary")
			applyButton.BackgroundTransparency = if view.ready then 0 else 0.6
			applyButton.AutoButtonColor = view.ready
		else
			applyButton.Visible = false
		end
	end

	renderView = function()
		local view = state.view
		local data = view and view.data
		if data == shownData then
			return
		end
		shownData = data
		selectedRow = nil
		table.clear(viewRows)
		table.clear(choiceShows)
		clear(list)
		if not view then
			return
		end
		viewTitle.Text = escape(view.title)
		viewSubtitle.Text = escape(view.subtitle or "")
		viewSubtitle.Visible = viewSubtitle.Text ~= ""
		viewCounts.Text = counts(data.summary or {})
		if #data.rows == 0 then
			local empty = text(list, 1, 13, REGULAR, Color.SubText)
			new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingTop = UDim.new(0, 10), Parent = empty })
			empty.Text = KINDS[view.kind].empty
		end
		for index, row in data.rows do
			if index > MAX_ROWS then
				local more = text(list, index * 100, 12, REGULAR, Color.DimmedText)
				new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingTop = UDim.new(0, 8), Parent = more })
				more.Text = string.format("…and %d more.", #data.rows - MAX_ROWS + (data.truncated or 0))
				break
			end
			table.insert(viewRows, viewRow(index, row))
		end
		for i, v in viewRows do
			local following = viewRows[i + 1]
			v.hasChildren = following ~= nil and following.row.depth > v.row.depth
		end
		updateVisibility()
		updateFooter()
		layoutReview()
	end

	-- Shows a window of changes.
	showView = function(view: any)
		view.choices = view.choices or {}
		state.view = view
		reviewWidget.Enabled = true
		render()
	end

	local function decideAll(side: string)
		local view = state.view
		if view and view.data.conflicts then
			for _, conflict in view.data.conflicts do
				view.choices[conflict.id] = side
			end
			for _, show in choiceShows do
				show()
			end
			updateFooter()
		end
	end
	keepAllButton.Activated:Connect(function()
		decideAll("keep")
	end)
	useAllButton.Activated:Connect(function()
		decideAll("use")
	end)
end

render = function()
	local g = state.game
	local isMain = g ~= nil and game.GameId == g.universe_id and game.PlaceId == g.main_place_id
	local mode = "other"
	if state.busy then
		connection.Text, connection.TextColor3 = "● Working", AMBER
	elseif state.connected then
		connection.Text, connection.TextColor3 = "● Connected", GREEN
	else
		connection.Text, connection.TextColor3 = "● Offline", GREY
	end
	if not state.connected and not state.busy then
		placeKind.Text, placeTitle.Text = "NOT CONNECTED", "RoGit isn't running"
		placeDetail.Text = "It starts when you log in. To start it now, run rogit serve in a terminal."
	elseif state.archived then
		placeKind.Text, placeTitle.Text = "ARCHIVED", escape(state.archived)
		placeDetail.Text = "This branch was archived. Close this window without saving."
	elseif state.branch then
		local branch = state.branch :: Branch
		mode = if branch.has_starting_point then "branch" else "other"
		placeKind.Text, placeTitle.Text = "BRANCH", escape(branch.name)
		local parts = {}
		if not branch.has_starting_point then
			table.insert(parts, "Getting ready…")
		else
			table.insert(parts, if branch.updated then "pulled from main " .. ago(branch.updated) else "made " .. ago(branch.created))
			if state.autosaved then
				table.insert(parts, "autosaved " .. clock(state.autosaved))
			end
		end
		placeDetail.Text = (string.gsub(table.concat(parts, " · "), "^%l", string.upper))
	elseif g and isMain then
		mode = "main"
		placeKind.Text, placeTitle.Text, placeDetail.Text = "MAIN", escape(g.name), ""
	elseif g and game.GameId == g.universe_id then
		placeKind.Text, placeTitle.Text = "OTHER PLACE", escape(state.experience or game.Name)
		placeDetail.Text = "RoGit works in " .. escape(g.name) .. "'s start place. Open that one to use it."
	elseif game.PlaceId == 0 or game.GameId == 0 then
		placeKind.Text, placeTitle.Text = "NOT PUBLISHED", escape(game.Name)
		placeDetail.Text = "RoGit works with published games. Open your game's start place."
	elseif state.isMain == nil then
		placeKind.Text, placeTitle.Text, placeDetail.Text = "CHECKING", escape(state.experience or game.Name), ""
	elseif state.isMain then
		mode = "init"
		placeKind.Text, placeTitle.Text = "SET UP", escape(state.experience or game.Name)
		placeDetail.Text = "Init gives every object a small hidden ID, so RoGit can follow it between branches. "
			.. "Scripts are left alone."
	else
		placeKind.Text, placeTitle.Text = "NOT THE START PLACE", escape(state.experience or game.Name)
		placeDetail.Text = "Open this game's start place to set up RoGit."
	end
	placeDetail.Visible = placeDetail.Text ~= ""
	local update = ""
	if state.connected and state.version and state.version ~= VERSION then
		update = string.format("RoGit %s and this plugin (%s) are different versions. To fix it, run rogit update.", state.version, VERSION)
	elseif state.connected and state.latest and versionRank(state.latest) > versionRank(VERSION) then
		update = string.format("RoGit %s is out. To update, run rogit update.", state.latest)
	end
	updateNote.Text = update
	updateNote.Visible = update ~= ""
	local offer = state.offer
	if state.problem then
		message.Text, message.TextColor3 = escape(state.problem), RED
	elseif state.busy then
		message.Text, message.TextColor3 = escape(state.busy), themeColor(Color.SubText)
	else
		message.Text = escape(if offer then offer.text else state.notice or "")
		message.TextColor3 = themeColor(Color.SubText)
	end
	if messageActions:GetAttribute("Shown") ~= tostring(offer) then
		messageActions:SetAttribute("Shown", tostring(offer))
		clear(messageActions)
		for i, action in (if offer then offer.actions else {}) do
			button(messageActions, i, action.label, action.kind).Activated:Connect(function()
				state.offer = nil
				render()
				action.run()
			end)
		end
	end
	messageActions.Visible = offer ~= nil and not state.busy
	message.Visible = message.Text ~= ""
	messageBox.Visible = message.Visible or messageActions.Visible
	local idle = not state.busy
	unsavedCard.Visible = mode == "branch" and idle and state.unsaved ~= nil and FRESH_WINDOW
	unsavedText.Text = if state.unsaved then "Unsaved work from " .. formatTime(state.unsaved) else ""
	initButton.Visible = mode == "init" and idle
	newSection.Visible = mode == "main" and idle
	branchesSection.Visible = mode == "main" and #state.branches > 0
	renderChanges()
	sourceSection.Visible = mode == "branch"
	stagedSection.Visible = mode == "branch" and stagedCount > 0
	changesSection.Visible = mode == "branch"
	commitButton.Text = if stagedCount > 0 then string.format("Commit %d staged", stagedCount) else "Commit"
	graphSection.Visible = (mode == "main" or mode == "branch") and #state.graph > 0
	renderBranches()
	renderGraph()
	renderView()
end

local dropView: () -> ()
reviewWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	-- Closing the window with its X is the same as Cancel or Close.
	if not reviewWidget.Enabled and state.view then
		dropView()
	end
	render()
end)

-- Actions ------------------------------------------------------------------------------------------

local recordingStart = false

local function run(first: string, action: () -> ())
	if state.busy then
		return
	end
	state.busy, state.problem, state.notice, state.offer = first, nil, nil, nil
	render()
	local ok, failure = pcall(action)
	state.busy = nil
	if not ok then
		state.problem = tostring(failure)
	end
	render()
end

-- Good news shows for a few seconds, then clears.
local function flash(textValue: string)
	state.notice = textValue
	task.delay(5, function()
		if state.notice == textValue then
			state.notice = nil
			render()
		end
	end)
end

local function step(textValue: string)
	state.busy = textValue
	render()
end

local function call(method: string, path: string, body: any?): any
	local ok, reply = request(method, path, body)
	if not ok then
		error(reply or "Lost the connection to RoGit.", 0)
	end
	return reply
end

-- Copies this place to RoGit and returns the capture ID and manifest.
local function copy(): (string, any)
	local capture = newId(16)
	return capture, copyPlace(capture)
end

openBranch = function(name: string)
	local ok, reply = request("POST", "/api/branches/open", { name = name })
	state.problem = if ok then nil else (reply or "Couldn't reach RoGit.")
	state.notice = if ok then "Opening " .. name .. "…" else nil
	render()
end

local function statusPath(): string
	local file = if game.PlaceId == 0 then "&file=" .. HttpService:UrlEncode(game.Name) else ""
	return "/api/rogit?place=" .. string.format("%d", game.PlaceId) .. file .. "&session=" .. SESSION
end

-- Looks through the ports for RoGit (the newest, if an older one is still running). Returns its reply.
local lastSearch = 0
local function findServer(): (boolean, any)
	lastSearch = os.clock()
	local found: { [number]: any } = {}
	local waiting = #PORTS
	for i, port in PORTS do
		task.spawn(function()
			local base = "http://127.0.0.1:" .. port
			local ok, response = pcall(HttpService.RequestAsync, HttpService, { Url = base .. withGame(statusPath()), Method = "GET" })
			if ok and response.Success then
				local decoded, reply = pcall(HttpService.JSONDecode, HttpService, response.Body)
				if decoded and reply.server == "rogit" then
					found[i] = { base = base, reply = reply }
				end
			end
			waiting -= 1
		end)
	end
	while waiting > 0 do
		task.wait()
	end
	local best = nil
	for i = 1, #PORTS do
		local candidate = found[i]
		if candidate and (best == nil or versionRank(candidate.reply.version) > versionRank(best.reply.version)) then
			best = candidate
		end
	end
	if best then
		serverBase = best.base
		return true, best.reply
	end
	return false, nil
end

local function refresh()
	local ok, reply = request("GET", statusPath())
	-- RoGit isn't where it was (or never was): look through the ports now and then.
	if not ok and os.clock() - lastSearch > 5 then
		ok, reply = findServer()
	end
	if ok and not state.connected then
		-- RoGit (re)started: check this place again.
		state.isMain, state.problem = nil, nil
	end
	state.connected = ok
	if ok then
		state.version, state.latest = reply.version, reply.latest
		state.game = reply.project and reply.project.game
		if type(reply.game) == "number" and reply.game ~= 0 then
			state.branchGame = reply.game
		end
		state.branches = reply.branches or {}
		state.branch = reply.branch
		state.commits = reply.commits or {}
		state.unsaved = reply.unsaved
		state.graph = reply.graph or {}
		state.archived = reply.archived
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
		run("Getting the branch ready…", function()
			local capture, manifest = copy()
			call("POST", "/api/branches/start", { name = branch.name, capture = capture, manifest = manifest })
		end)
		recordingStart = false
	end
	-- A branch is waiting to be updated from main: send it a copy of main.
	local wanted = ok and reply.copy
	if wanted and not state.busy then
		run("Sending main to " .. wanted.branch .. "…", function()
			local sent, failure = pcall(function()
				tagObjects()
				local manifest = copyPlace(wanted.capture)
				call("POST", "/api/main/copy", { capture = wanted.capture, manifest = manifest })
			end)
			if not sent then
				request("POST", "/api/main/copy", { capture = wanted.capture, failed = tostring(failure) })
				error(failure, 0)
			end
			flash("Sent main to " .. wanted.branch .. ".")
		end)
	end
end

initButton.Activated:Connect(function()
	run("Checking with RoGit…", function()
		call("POST", "/api/init", { game = game.GameId, place = game.PlaceId })
		step("Giving every object an ID…")
		local report = tagObjects()
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
	run("Copying main…", function()
		tagObjects()
		local capture, manifest = copy()
		step("Building " .. name .. "…")
		call("POST", "/api/branches", { name = name, capture = capture, manifest = manifest })
		nameBox.Text = ""
		flash("Created " .. name .. ". It's opening in Studio.")
	end)
	refresh()
end

createButton.Activated:Connect(createBranch)
nameBox.FocusLost:Connect(function(enter)
	if enter then
		createBranch()
	end
end)

-- Closes a window of changes that's waiting for a choice, telling rogit serve.
dropView = function()
	local view = state.view
	if view and KINDS[view.kind].apply then
		request("POST", "/api/branches/cancel", { name = view.branch, kind = view.kind })
	end
	state.view = nil
	reviewWidget.Enabled = false
end

-- Takes a reply with a branch's changes (from a refresh or a commit).
local function applyChanges(reply: any)
	state.changes = reply.changes
	state.since = reply.since
	local staged = {}
	for _, key in reply.staged or {} do
		staged[key] = true
	end
	state.staged = staged
	if reply.time then
		state.autosaved = reply.time
	end
end

local function uncommitted(): number
	return stagedCount + unstagedCount
end

-- Commits everything in the branch as it is now, for a pull or a revert (like git's own commits for those).
-- Sends a request about the branch as it is in Studio: from rogit serve's copy (kept current, so this is quick), or
-- with a full copy when it has none.
local function callWithBranch(path: string, body: any): any
	if flushChanges() then
		body.live = true
		local reply = call("POST", path, body)
		if not reply.full then
			return reply
		end
		body.live = nil
	end
	body.capture, body.manifest = copy()
	return call("POST", path, body)
end

local function autoCommit(message: string)
	local branch = state.branch :: Branch
	local ok, reply = pcall(callWithBranch, "/api/branches/commit", { name = branch.name, message = message, auto = true })
	if ok then
		state.commits = reply.commits
		applyChanges(reply)
	end
end

-- Commits the staged changes (or all of them, when none are staged). Returns whether it worked.
local function commitBranch(): boolean
	local branch = state.branch
	if not branch then
		return false
	end
	local messageText = string.gsub(commitBox.Text, "^%s*(.-)%s*$", "%1")
	local done = false
	run("Committing…", function()
		local reply = callWithBranch("/api/branches/commit", { name = branch.name, message = messageText })
		state.commits = reply.commits
		applyChanges(reply)
		commitBox.Text = ""
		flash("Committed “" .. reply.commit.message .. "”.")
		done = true
	end)
	return done
end

-- In a branch: copy it, then wait for main (open in Studio) to send its copy, and show what the pull brings.
local function startUpdate()
	local branch = state.branch
	if not branch or state.busy then
		return
	end
	dropView()
	run("Copying the branch…", function()
		tagObjects()
		local capture, manifest = copy()
		call("POST", "/api/branches/update", { name = branch.name, capture = capture, manifest = manifest })
		step("Waiting for main… Keep " .. (if state.game then (state.game :: Game).name else "main") .. " open in Studio.")
		local path = "/api/branches/update?name=" .. HttpService:UrlEncode(branch.name)
		while true do
			task.wait(0.5)
			local reply = call("GET", path)
			if not reply.waiting then
				showView({
					kind = "update", data = reply.plan, branch = branch.name, id = reply.update,
					title = "Pull main into " .. branch.name, subtitle = SINCE[reply.since] or SINCE.start,
				})
				break
			elseif reply.offered and state.busy ~= "Main is sending a copy…" then
				step("Main is sending a copy…")
			end
		end
	end)
	render()
end

-- Like git, pulling wants the branch's own work committed first.
local function startPull()
	if state.busy then
		return
	end
	if uncommitted() > 0 then
		state.notice, state.problem = nil, nil
		state.offer = {
			text = "Commit your changes before pulling from main.",
			actions = {
				{ label = "Commit and pull", kind = "primary", run = function()
					if commitBranch() then
						startUpdate()
					end
				end },
				{ label = "Cancel", kind = "quiet", run = function() end },
			},
		}
		render()
		return
	end
	startUpdate()
end

startMerge = function(name: string)
	if state.busy then
		return
	end
	dropView()
	run("Copying main…", function()
		tagObjects()
		local capture, manifest = copy()
		step("Comparing " .. name .. " with main…")
		local reply = call("POST", "/api/branches/merge", { name = name, capture = capture, manifest = manifest })
		local source = if reply.source == "commit"
			then "branch at “" .. (reply.commit or "") .. "”"
			else "branch as " .. reply.source .. " " .. clock(reply.sourceTime)
		local left = if reply.uncommitted and reply.uncommitted > 0
			then string.format(" · %d uncommitted change%s left out", reply.uncommitted, if reply.uncommitted == 1 then "" else "s")
			else ""
		showView({
			kind = "merge", data = reply.plan, branch = name, id = reply.merge, title = "Merge " .. name .. " into main",
			subtitle = (SINCE[reply.since] or SINCE.start) .. " · " .. source .. left,
		})
	end)
	render()
end

setPinned = function(name: string, pinned: boolean)
	state.menu = nil
	local ok, reply = request("POST", "/api/branches/pin", { name = name, pinned = pinned })
	if ok then
		state.branches = reply.branches
	else
		state.problem = reply
	end
	render()
end

local function archiveBranch(name: string)
	run("Archiving " .. name .. "…", function()
		local reply = call("POST", "/api/branches/archive", { name = name })
		state.branches = reply.branches
		flash("Archived " .. name .. ".")
	end)
	refresh()
end

confirmArchive = function(name: string)
	state.notice, state.problem = nil, nil
	state.offer = {
		text = "Archive " .. name .. "? This deletes its branch file and closes it in Studio.",
		actions = {
			{ label = "Archive", kind = "danger", run = function()
				archiveBranch(name)
			end },
			{ label = "Cancel", kind = "quiet", run = function() end },
		},
	}
	render()
end

openHistory = function(event: any)
	run("Opening…", function()
		local reply = call("GET", "/api/history/rows?id=" .. event.id)
		showView({
			kind = "history", branch = event.branch, data = { rows = reply.rows, truncated = reply.truncated, summary = event.summary or {} },
			title = string.format(KIND_TEXT[event.kind] or "%s", event.branch), subtitle = formatTime(event.time),
		})
	end)
end

viewCommit = function(commit: any, branchName: string)
	run("Opening…", function()
		local reply = call("POST", "/api/branches/commit/view", { name = branchName, id = commit.id })
		local here = state.branch ~= nil and (state.branch :: Branch).name == branchName
		showView({
			kind = "commit", data = reply.review, branch = branchName, commit = commit, canRevert = here,
			title = commit.message, subtitle = branchName .. " · " .. formatTime(commit.time),
		})
	end)
end

startRevert = function(commit: any)
	local branch = state.branch
	if not branch then
		return
	end
	dropView()
	local lost = uncommitted()
	run("Comparing with “" .. commit.message .. "”…", function()
		local reply = callWithBranch("/api/branches/revert", { name = branch.name, id = commit.id })
		showView({
			kind = "revert", data = reply.plan, branch = branch.name, record = reply.record, message = commit.message,
			title = "Revert to “" .. commit.message .. "”",
			subtitle = formatTime(commit.time)
				.. (if lost > 0 then string.format(" · %d uncommitted change%s will be undone too", lost, if lost == 1 then "" else "s") else ""),
		})
	end)
end

selectObject = function(key: string)
	local object = findObject(key)
	if object then
		Selection:Set({ object })
	end
end

setStaged = function(keys: { string })
	local staged = {}
	for _, key in keys do
		staged[key] = true
	end
	state.staged = staged
	render()
	local branch = state.branch
	if branch then
		request("POST", "/api/branches/stage", { name = branch.name, keys = keys })
	end
end

commitButton.Activated:Connect(commitBranch)
commitBox.FocusLost:Connect(function(enter)
	if enter then
		commitBranch()
	end
end)
pullButton.Activated:Connect(startPull)
stageAllButton.Activated:Connect(function()
	local keys = stagedKeys()
	local _, unstaged = changeList()
	for _, item in unstaged do
		table.insert(keys, item.row.key)
	end
	setStaged(keys)
end)
unstageAllButton.Activated:Connect(function()
	setStaged({})
end)
discardAllButton.Activated:Connect(function()
	local keys = {}
	local _, unstaged = changeList()
	for _, item in unstaged do
		table.insert(keys, item.row.key)
	end
	discard(keys)
end)

restoreButton.Activated:Connect(function()
	local branch = state.branch
	if not branch then
		return
	end
	dropView()
	local from = state.unsaved
	run("Comparing…", function()
		local reply = callWithBranch("/api/branches/restore", { name = branch.name })
		showView({
			kind = "restore", data = reply.plan, branch = branch.name, record = reply.record, title = "Restore unsaved work",
			subtitle = if from then "From " .. formatTime(from) else nil,
		})
	end)
end)

dismissButton.Activated:Connect(function()
	local branch = state.branch
	if branch then
		request("POST", "/api/branches/unsaved/dismiss", { name = branch.name })
		state.unsaved = nil
		render()
	end
end)

-- Applying changes ----------------------------------------------------------------------------------

-- Bundle attributes (set by rogit): which operation an object belongs to, and which ones need a reference fixed.
local OP_TAG = "RoGitOp"
local REF_TAG = "RoGitRef"
-- Workspace attribute in main: the last merge of each branch, so the next merge only brings what changed after it.
local MERGES_TAG = "RoGitMerges"
-- Workspace attribute in a branch: the last update from main, so the next one only brings what changed after it.
local UPDATE_TAG = "RoGitUpdate"

local function recordMerge(branch: string, id: string)
	local ok, record = pcall(HttpService.JSONDecode, HttpService, workspace:GetAttribute(MERGES_TAG) or "{}")
	if not ok or typeof(record) ~= "table" then
		record = {}
	end
	record[branch] = id
	workspace:SetAttribute(MERGES_TAG, HttpService:JSONEncode(record))
end

local runPlan: (any, { [number]: string }) -> (number, number, { string })
do
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
			if key ~= TAG and string.sub(key, 1, 4) ~= "RBX_" and from:GetAttribute(key) == nil then
				to:SetAttribute(key, nil)
			end
		end
		for key, value in from:GetAttributes() do
			if key ~= TAG and key ~= OP_TAG and key ~= REF_TAG and string.sub(key, 1, 4) ~= "RBX_" then
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

	-- Every tagged object in this place, by RoGit ID.
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
			return findObject(key, ids) or error("Couldn't find " .. key .. " in this place.", 0)
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
				elseif target:IsA("Terrain") and property == "SmoothGrid" then
					-- Voxels can't be set directly: paste the incoming terrain over the whole thing.
					local terrain = target :: Terrain
					local source = template :: Terrain
					local region = source:CopyRegion(source.MaxExtents)
					terrain:Clear()
					local low = source.MaxExtents.Min
					terrain:PasteRegion(region, Vector3int16.new(low.X, low.Y, low.Z), true)
				elseif target:IsA("Terrain") and property == "MaterialColors" then
					for _, material in Enum.Material:GetEnumItems() do
						pcall(function()
							(target :: Terrain):SetMaterialColor(material, (template :: Terrain):GetMaterialColor(material))
						end)
					end
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

	-- Applies a plan's operations; conflicts apply only where `choices` says "use". Returns how many applied, how many
	-- were skipped by choice, and what went wrong. The caller wraps this in one undo step.
	runPlan = function(plan: any, choices: { [number]: string }): (number, number, { string })
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
		for _, op in ordered do
			if op.conflict and choices[op.conflict] ~= "use" then
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
		return applied, skipped, problems
	end
end

local VERBS = {
	merge = { "Merge", "Merging…", "Merged" }, update = { "Pull", "Pulling…", "Pulled" },
	revert = { "Revert", "Reverting…", "Reverted" }, restore = { "Restore", "Restoring…", "Restored" },
}

-- Applies the open merge (in main), update, revert or restore (in a branch) as one undo step.
local function applyView()
	local view = state.view
	if not view or not view.ready then
		return
	end
	local kind = view.kind
	local verbs = VERBS[kind]
	state.view = nil
	reviewWidget.Enabled = false
	run(verbs[2], function()
		local recording = ChangeHistoryService:TryBeginRecording("RoGit" .. verbs[1], "RoGit " .. string.lower(verbs[1]) .. " " .. view.branch)
		local applied, skipped, problems = runPlan(view.data, view.choices)
		-- Recorded in the same undo step, so undoing it (or not saving) forgets it too. If something couldn't be
		-- applied, the next merge or update starts from earlier and offers it again.
		local clean = #problems == 0
		if clean and kind == "merge" and view.id then
			recordMerge(view.branch, view.id)
		elseif clean and kind == "update" and view.id then
			workspace:SetAttribute(UPDATE_TAG, view.id)
		elseif clean and (kind == "revert" or kind == "restore") then
			workspace:SetAttribute(UPDATE_TAG, if view.record and view.record ~= "" then view.record else nil)
		end
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		local report: any = { name = view.branch, applied = applied, skipped = skipped, failed = problems }
		if kind == "merge" then
			report.merge = if clean then view.id else nil
			request("POST", "/api/branches/merged", report)
		elseif kind == "update" then
			report.update = if clean then view.id else nil
			request("POST", "/api/branches/updated", report)
		else
			report.kind = kind
			request("POST", "/api/branches/restored", report)
		end
		state.view = nil
		local done = string.format("%s: %d change%s.", verbs[3], applied, if applied == 1 then "" else "s")
		if not clean then
			done ..= string.format(" %d couldn't be applied.", #problems)
		end
		if kind == "merge" then
			-- The graph shows the merge; only problems need a message.
			if not clean then
				state.problem = done
			end
		else
			if kind == "update" then
				step("Committing the pull…")
				autoCommit("Pull from main")
			elseif kind == "revert" then
				step("Committing the revert…")
				autoCommit("Revert to “" .. (view.message or "commit") .. "”")
			end
			if clean then
				flash(done .. " Save with Ctrl+S.")
			else
				state.problem = done
			end
		end
	end)
	refresh()
end

-- Puts uncommitted changes (`keys`) back the way the last commit had them, like VS Code's Discard Changes.
discard = function(keys: { string })
	local branch = state.branch
	if not branch or #keys == 0 then
		return
	end
	run("Discarding…", function()
		local reply = callWithBranch("/api/branches/discard", { name = branch.name, keys = keys })
		local recording = ChangeHistoryService:TryBeginRecording("RoGitDiscard", "RoGit discard changes")
		local _, _, problems = runPlan(reply.plan, {})
		if recording then
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		if #problems > 0 then
			for _, problem in problems do
				warn("RoGit discard: " .. problem)
			end
			state.problem = string.format("%d couldn't be put back; see the Output window.", #problems)
		else
			flash(string.format("Discarded %d change%s. Ctrl+Z brings %s back.", #keys, if #keys == 1 then "" else "s", if #keys == 1 then "it" else "them"))
		end
	end)
end

applyButton.Activated:Connect(function()
	local view = state.view
	if not view then
		return
	elseif view.kind == "commit" then
		startRevert(view.commit)
	else
		applyView()
	end
end)
closeButton.Activated:Connect(function()
	dropView()
	render()
end)

-- Everything below runs in its own function (it has its own 200 locals).
local function startWatching()
	-- A branch's changes stay current. RoGit copies the whole branch once, then sends only the objects that change
	-- (Studio's session IDs say which is which), so this stays quick in big places. rogit serve's copy is also the
	-- autosave.
	local watch = { dirty = true, first = 0, last = 0, seconds = 0.5, sending = false, lastFull = 0 }
	local pending = {
		-- rogit serve has no copy yet (or lost track): send a full one.
		full = true,
		-- Changed or added objects.
		objects = {} :: { [Instance]: boolean },
		-- Removed objects, with their IDs.
		removed = {} :: { [Instance]: string },
		-- Services whose own settings changed.
		services = {} :: { [Instance]: boolean },
	}
	local tracked: { Instance } = {}
	local trackedSet: { [Instance]: boolean } = {}
	for _, name in SERVICES do
		local ok, service = pcall(game.GetService, game, name)
		if ok and service then
			table.insert(tracked, service)
			trackedSet[service] = true
		end
	end

	-- Whether an object is a saved service or in one, remembered per object (dragging a model fires a lot).
	local relevance: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local function relevant(object: Instance): boolean
		local known = relevance[object]
		if known == nil then
			known = trackedSet[object] == true
			for _, service in tracked do
				if known or object:IsDescendantOf(service) then
					known = true
					break
				end
			end
			relevance[object] = known
		end
		return known
	end

	local function noteEdit()
		if not watch.dirty then
			watch.dirty, watch.first = true, os.clock()
		end
		watch.last = os.clock()
	end

	-- Only edits to the place count: Studio changes plenty of its own things (outlines, panels) all the time. RoGit
	-- leaves scripts alone, so their edits don't count, but adding or removing a script changes its parent (a Folder
	-- with a script inside isn't tracked).
	local function touched(object: Instance)
		if object.ClassName == "Camera" or object:IsA("LuaSourceContainer") or not relevant(object) then
			return
		end
		if trackedSet[object] then
			pending.services[object] = true
		else
			pending.objects[object] = true
		end
		noteEdit()
	end
	-- Whether a new object is one Init would give an ID: saved, not a camera, and not inside something that isn't saved.
	local function trackable(object: Instance): boolean
		if object:IsA("Camera") then
			return false
		end
		local current = object
		while not trackedSet[current] do
			if not current.Archivable or current.Parent == nil then
				return false
			end
			current = current.Parent :: Instance
		end
		return true
	end

	-- A newly added object keeps its RoGit ID unless another object has it (a Ctrl+D copy, a paste); then it gets its
	-- own. Something new gets one too, so RoGit can follow it if it's renamed or moved before it's merged. This runs
	-- while Studio is still adding the object, so it's part of the same undo step.
	local function claimId(object: Instance)
		if not idOwners then
			return
		end
		local id = object:GetAttribute(TAG)
		if type(id) ~= "string" then
			if trackable(object) then
				local fresh = newId(10)
				if pcall(object.SetAttribute, object, TAG, fresh) then
					idOwners[fresh] = object
				end
			end
			return
		end
		local owner = idOwners[id]
		if owner and owner ~= object and owner:IsDescendantOf(game) then
			local fresh = newId(10)
			object:SetAttribute(TAG, fresh)
			idOwners[fresh] = object
		else
			idOwners[id] = object
		end
	end

	local function added(object: Instance)
		if object:IsA("LuaSourceContainer") then
			if object.Parent then
				touched(object.Parent)
			end
			return
		end
		if relevant(object) then
			claimId(object)
		end
		touched(object)
	end

	-- Makes the list of IDs, and gives copies that share one (Ctrl+D copies from before) their own, in one undo step.
	local function claimAllIds()
		local owners: { [string]: Instance } = {}
		local copies = {}
		for _, service in tracked do
			for _, object in service:GetDescendants() do
				local id = object:GetAttribute(TAG)
				if type(id) == "string" then
					if owners[id] then
						table.insert(copies, object)
					else
						owners[id] = object
					end
				end
			end
		end
		if #copies > 0 then
			local recording = ChangeHistoryService:TryBeginRecording("RoGitTags", "RoGit IDs")
			for _, object in copies do
				local id = newId(10)
				if pcall(object.SetAttribute, object, TAG, id) then
					owners[id] = object
				end
			end
			if recording then
				ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			end
		end
		idOwners = owners
	end
	local function removing(object: Instance)
		if object:IsA("LuaSourceContainer") then
			if object.Parent then
				touched(object.Parent)
			end
			return
		end
		if object.ClassName == "Camera" or trackedSet[object] or not relevant(object) then
			return
		end
		pending.removed[object] = object:GetDebugId(0)
		pending.objects[object] = nil
		relevance[object] = nil
		-- Cut and paste keeps an object's ID: once it's out of the place, its ID is free again.
		local id = object:GetAttribute(TAG)
		if idOwners and type(id) == "string" and idOwners[id] == object then
			idOwners[id] = nil
		end
		noteEdit()
	end
	game.DescendantAdded:Connect(added)
	game.DescendantRemoving:Connect(removing)
	-- Studio may not let plugins hear every property change. Then RoGit listens to what's selected, which is where
	-- nearly every edit happens (moving, scaling, the Properties panel), and copies the whole place now and then.
	local hearsEverything = pcall(function()
		game.ItemChanged:Connect(touched)
	end)
	local selectionConnections: { RBXScriptConnection } = {}
	local function watchSelection()
		for _, connection in selectionConnections do
			connection:Disconnect()
		end
		table.clear(selectionConnections)
		for _, object in Selection:Get() do
			local objects = object:GetDescendants()
			table.insert(objects, object)
			for _, watched in objects do
				if #selectionConnections >= 5000 then
					return
				end
				table.insert(selectionConnections, watched.Changed:Connect(function()
					touched(watched)
				end))
			end
		end
	end
	if not hearsEverything then
		Selection.SelectionChanged:Connect(watchSelection)
		watchSelection()
	end
	local function changedByUndo()
		if not hearsEverything then
			pending.full = true
		end
		noteEdit()
	end
	ChangeHistoryService.OnUndo:Connect(changedByUndo)
	ChangeHistoryService.OnRedo:Connect(changedByUndo)

	-- Attributes and tags don't fire change events. They're edited on the selection (Properties, Tag Editor), so RoGit
	-- looks at the selected objects a few times a second.
	local marks: { [Instance]: string } = {}
	local function markOf(object: Instance): string
		local parts = {}
		for key, value in object:GetAttributes() do
			table.insert(parts, key .. "=" .. tostring(value))
		end
		table.sort(parts)
		local tags = object:GetTags()
		table.sort(tags)
		return table.concat(parts, ";") .. "|" .. table.concat(tags, ",")
	end
	local function checkSelection()
		local seen = {}
		for i, object in Selection:Get() do
			if i > 200 then
				break
			end
			local mark = markOf(object)
			if marks[object] and marks[object] ~= mark then
				touched(object)
			end
			seen[object] = mark
		end
		marks = seen
	end

	-- Terrain voxels don't fire change events either; the number of filled cells is cheap to check.
	local terrainCells = workspace.Terrain:CountCells()
	local function checkTerrain()
		local cells = workspace.Terrain:CountCells()
		if cells ~= terrainCells then
			terrainCells = cells
			touched(workspace.Terrain)
		end
	end

	-- Whether an object is in the copies: in a saved service, and saved itself (copies skip what isn't Archivable).
	local function inPlace(object: Instance): boolean
		local current: Instance? = object
		while current and not trackedSet[current] do
			if not current.Archivable then
				return false
			end
			current = current.Parent
		end
		return current ~= nil and current ~= object
	end

	-- Reference properties. A copy of just one object loses its references to others; RoGit sends them along.
	local REF_NAMES = {
		PrimaryPart = true, Part0 = true, Part1 = true, Attachment0 = true, Attachment1 = true, Value = true, Adornee = true,
		SoundGroup = true, CameraSubject = true,
	}
	local refNames: { [string]: { string } } = {}
	local function refsOf(class: string): { string }
		local known = refNames[class]
		if not known then
			known = {}
			local ok, infos = pcall(ReflectionService.GetPropertiesOfClass, ReflectionService, class)
			if ok then
				for _, info in infos do
					if REF_NAMES[info.Name] then
						table.insert(known, info.Name)
					end
				end
			end
			refNames[class] = known
		end
		return known
	end

	local function serviceOf(object: Instance): Instance
		local current = object
		while current.Parent and current.Parent ~= game do
			current = current.Parent
		end
		return current
	end

	-- Sends what changed since last time: a full copy when rogit serve has none, otherwise just the changed objects.
	-- Returns whether rogit serve's copy is current afterwards.
	local function sendChanges(): boolean
		local branch = state.branch :: Branch
		if pending.full then
			pending.full = false
			table.clear(pending.objects)
			table.clear(pending.removed)
			table.clear(pending.services)
			local capture = newId(16)
			local manifest = copyPlace(capture, true)
			local reply = call("POST", "/api/branches/changes", { name = branch.name, capture = capture, manifest = manifest, session = SESSION })
			watch.lastFull = os.clock()
			-- If the IDs don't line up with the copy, every refresh stays a full copy.
			pending.full = not reply.live
			applyChanges(reply)
			return not pending.full
		end
		local objects, removed, services = pending.objects, pending.removed, pending.services
		pending.objects, pending.removed, pending.services = {}, {}, {}
		-- The changed objects that aren't inside another changed one (that one brings them along).
		local tops = {}
		for object in objects do
			if inPlace(object) then
				local covered = false
				local ancestor = object.Parent
				while ancestor and not trackedSet[ancestor] do
					if objects[ancestor] then
						covered = true
						break
					end
					ancestor = ancestor.Parent
				end
				if not covered then
					table.insert(tops, object)
				end
			end
		end
		local upserts, refs = {}, {}
		for _, top in tops do
			local ids = {}
			walkIds(top, ids)
			local parent = top.Parent :: Instance
			table.insert(upserts, {
				id = top:GetDebugId(0), parent = if trackedSet[parent] then "service:" .. parent.Name else parent:GetDebugId(0), ids = ids,
			})
			local service = serviceOf(top)
			local inside = top:GetDescendants()
			table.insert(inside, top)
			for _, object in inside do
				for _, property in refsOf(object.ClassName) do
					local ok, target = pcall(function()
						return (object :: any)[property]
					end)
					if ok and typeof(target) == "Instance" and target ~= top and not target:IsDescendantOf(top) and target:IsDescendantOf(service) then
						table.insert(refs, { id = object:GetDebugId(0), property = property, target = target:GetDebugId(0) })
					end
				end
			end
		end
		local removes = {}
		for object, id in removed do
			if not object:IsDescendantOf(game) then
				table.insert(removes, id)
			end
		end
		local settings = {}
		for service in services do
			local attributes = {}
			for key, value in service:GetAttributes() do
				attributes[key] = encode(value)
			end
			table.insert(settings, { name = service.Name, className = service.ClassName, settings = serviceSettings(service), attributes = attributes })
		end
		if #upserts == 0 and #removes == 0 and #settings == 0 then
			return true
		end
		local capture = nil
		if #upserts > 0 then
			capture = newId(16)
			local data = SerializationService:SerializeInstancesAsync(tops)
			local uploads: { pending: number, failure: string? } = { pending = 0, failure = nil }
			sendParts(capture, "Patch", buffer.tostring(EncodingService:Base64Encode(data)), uploads)
			while uploads.pending > 0 do
				task.wait()
			end
			if uploads.failure then
				error(uploads.failure, 0)
			end
		end
		local reply = call("POST", "/api/branches/patch", {
			name = branch.name, capture = capture, upserts = upserts, removes = removes, services = settings, refs = refs,
		})
		if reply.full then
			pending.full = true
			return false
		end
		applyChanges(reply)
		return true
	end

	-- Sends anything not sent yet, and the terrain (which can change unseen), so rogit serve's copy is exact. Returns
	-- whether it is; if not, the caller sends a full copy.
	flushChanges = function(): boolean
		while watch.sending do
			task.wait()
		end
		if pending.full or state.branch == nil then
			return false
		end
		pending.objects[workspace.Terrain] = true
		watch.sending = true
		local ok, current = pcall(sendChanges)
		watch.sending = false
		watch.dirty = false
		return ok and current
	end

	render()
	task.spawn(function()
		while true do
			if not state.busy then
				refresh()
			end
			task.wait(POLL_SECONDS)
		end
	end)
	task.spawn(function()
		local ticks = 0
		while true do
			task.wait(0.1)
			ticks += 1
			local branch = state.branch
			local inBranch = branch ~= nil and branch.has_starting_point and not state.archived and state.connected
			if not inBranch then
				pending.full = true
				continue
			end
			if ticks % 4 == 0 then
				checkSelection()
				checkTerrain()
			end
			if idOwners == nil and not state.busy then
				claimAllIds()
			end
			-- Every 10 minutes, when nobody's editing, a full copy makes sure nothing was missed.
			if os.clock() - watch.lastFull > 600 and os.clock() - watch.last > 30 then
				pending.full = true
				noteEdit()
			end
			-- Bigger places take longer to send, so wait a little longer for edits to settle.
			local settle = math.clamp(watch.seconds / 2, 0.1, 3)
			local due = watch.dirty and (os.clock() - watch.last >= settle or os.clock() - watch.first >= 30)
			-- Without hearing every change, copy the whole place every so often too.
			if not hearsEverything and os.clock() - watch.lastFull >= math.max(15, watch.seconds * 20) then
				pending.full = true
				due = true
			end
			if due and not state.busy and not watch.sending then
				watch.dirty, watch.sending = false, true
				local started = os.clock()
				local ok, failure = pcall(sendChanges)
				watch.sending = false
				watch.seconds = os.clock() - started
				if ok then
					render()
				else
					watch.dirty = true
					warn("RoGit couldn't refresh the changes: " .. tostring(failure))
				end
			end
		end
	end)
end

startWatching()
