--!strict
-- The RoGit panel: where you are, its branches (in main) or its changes (in a branch), and the graph.

local StudioService = game:GetService("StudioService")

local App = require(script.Parent.App)
local Core = require(script.Parent.Core)
local Look = require(script.Parent.Look)
local Review = require(script.Parent.Review)

type Branch = Core.Branch

local state, playtest, PAUSED, VERSION, versionRank, FRESH_WINDOW = Core.state, Core.playtest, Core.PAUSED, Core.VERSION, Core.versionRank, Core.FRESH_WINDOW
local Color, REGULAR, MEDIUM, BOLD, GREEN, RED, AMBER, GREY, HEX, MARK = Look.Color, Look.REGULAR, Look.MEDIUM, Look.BOLD, Look.GREEN, Look.RED, Look.AMBER, Look.GREY, Look.HEX, Look.MARK
local themeColor, new, round, pad, stack, box, text, clear, button = Look.themeColor, Look.new, Look.round, Look.pad, Look.stack, Look.box, Look.text, Look.clear, Look.button
local field, section, listRow, escape, formatTime, clock, ago = Look.field, Look.section, Look.listRow, Look.escape, Look.formatTime, Look.clock, Look.ago

-- The panel's parts call this when something changes; it's defined at the end, once they all exist.
local render: () -> ()

local toolbar = App.plugin:CreateToolbar("RoGit")
local toggle = toolbar:CreateButton("RoGit", "Open the RoGit panel", "")
toggle.ClickableWhenViewportHidden = true

-- Open in every window, docked on the left the first time. After that Studio keeps it wherever it was moved to.
local widget = App.plugin:CreateDockWidgetPluginGui(
	"RoGitPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Left, true, true, 300, 440, 260, 240)
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
			App.openBranch(branch.name)
		end)
		button(buttons, 2, "Merge", "primary").Activated:Connect(function()
			App.startMerge(branch.name)
		end)
		local more = button(buttons, 3, "···", "quiet")
		more.Activated:Connect(function()
			state.menu = if state.menu == branch.name then nil else branch.name
			render()
		end)
		if state.menu == branch.name then
			local menu = box(row, 2, 4, true)
			button(menu, 1, if branch.pinned then "Unpin" else "Pin", "secondary").Activated:Connect(function()
				App.setPinned(branch.name, not branch.pinned)
			end)
			button(menu, 2, "Archive…", "secondary").Activated:Connect(function()
				state.menu = nil
				App.confirmArchive(branch.name)
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
					App.openHistory(event)
				elseif event.kind == "commit" then
					App.viewCommit({ id = event.id, message = event.message, time = event.time }, event.branch)
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
		App.setStaged(keys)
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
			App.discard({ row.key })
		end)
	end
	-- Clicking a change shows what changed under it, and selects the object in Studio.
	frame.Activated:Connect(function()
		expandedChanges[row.key] = not expandedChanges[row.key] or nil
		shownChanges = ""
		render()
		App.selectObject(row.key)
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

local function uncommitted(): number
	return stagedCount + unstagedCount
end

stageAllButton.Activated:Connect(function()
	local keys = stagedKeys()
	local _, unstaged = changeList()
	for _, item in unstaged do
		table.insert(keys, item.row.key)
	end
	App.setStaged(keys)
end)
unstageAllButton.Activated:Connect(function()
	App.setStaged({})
end)
discardAllButton.Activated:Connect(function()
	local keys = {}
	local _, unstaged = changeList()
	for _, item in unstaged do
		table.insert(keys, item.row.key)
	end
	App.discard(keys)
end)

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
	if not playtest.isEditing() then
		message.Text, message.TextColor3 = escape(PAUSED), themeColor(Color.SubText)
	elseif state.problem then
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
	local idle = playtest.isEditing() and not state.busy
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
	Review.renderView()
end

App.render = render

return {
	render = render, uncommitted = uncommitted, KIND_TEXT = KIND_TEXT, initButton = initButton, nameBox = nameBox,
	createButton = createButton, commitBox = commitBox, commitButton = commitButton, pullButton = pullButton,
	restoreButton = restoreButton, dismissButton = dismissButton,
}
