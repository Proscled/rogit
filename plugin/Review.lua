--!strict
-- The window of changes: a branch's changes, a commit, a merge, a pull, a revert or a restore, laid out like Studio's
-- Explorer, with a choice for each conflict.

local Selection = game:GetService("Selection")
local StudioService = game:GetService("StudioService")

local App = require(script.Parent.App)
local Core = require(script.Parent.Core)
local Look = require(script.Parent.Look)
local Place = require(script.Parent.Place)
local Preview = require(script.Parent.Preview)

local state = Core.state
local findObject = Place.findObject
local Color, Modifier, REGULAR, MEDIUM, BOLD, RED, HEX, MARK = Look.Color, Look.Modifier, Look.REGULAR, Look.MEDIUM, Look.BOLD, Look.RED, Look.HEX, Look.MARK
local themed, themeColor, new, round, pad, stack, box = Look.themed, Look.themeColor, Look.new, Look.round, Look.pad, Look.stack, Look.box
local text, inlineText, clear, styleButton, button, escape, counts = Look.text, Look.inlineText, Look.clear, Look.styleButton, Look.button, Look.escape, Look.counts

local SINCE: { [string]: string }
local KINDS: { [string]: any }
local reviewWidget: DockWidgetPluginGui
local closeButton: TextButton
local applyButton: TextButton
local renderView: () -> ()
local showView: (any) -> ()

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

reviewWidget = App.plugin:CreateDockWidgetPluginGui(
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
		Preview.update()
	end)
	use.Activated:Connect(function()
		view.choices[id] = "use"
		show()
		updateFooter()
		Preview.update()
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
		if row.status ~= "context" then
			Preview.focus(row, object)
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
	Preview.show(view)
	App.render()
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
		Preview.update()
	end
end
keepAllButton.Activated:Connect(function()
	decideAll("keep")
end)
useAllButton.Activated:Connect(function()
	decideAll("use")
end)

return {
	SINCE = SINCE, KINDS = KINDS, widget = reviewWidget, closeButton = closeButton, applyButton = applyButton,
	renderView = renderView, showView = showView,
}
