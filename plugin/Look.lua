--!strict
-- How the plugin looks: Studio's theme colors, RoGit's own, and the pieces the panel and windows are built from.

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

return {
	Color = Color, Modifier = Modifier, REGULAR = REGULAR, MEDIUM = MEDIUM, BOLD = BOLD, GREEN = GREEN, RED = RED,
	AMBER = AMBER, GREY = GREY, HEX = HEX, MARK = MARK, themed = themed, themeColor = themeColor, new = new, round = round,
	pad = pad, stack = stack, box = box, text = text, inlineText = inlineText, clear = clear, styleButton = styleButton,
	button = button, field = field, section = section, listRow = listRow, escape = escape, formatTime = formatTime,
	clock = clock, ago = ago, counts = counts,
}
