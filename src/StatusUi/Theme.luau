--[[
	Theme - Panel look that follows Studio

	Gives every part of the panel its colours from the Studio theme, and builds
	the rounded pieces the panel is assembled from.

	- Reads one colour from the current Studio theme
	- Paints an element now, and again whenever the theme changes
	- Marks a caption with the emoji and colour of a state, or clears the mark
	- Builds a rounded card, a fixed-size tile, and the text inside either
	- Sets text in italics, or as a faint hint
	- Tells listeners the theme changed, and lets go of it on request
]]

-- // VARIABLES // --
-- | Objects | --
local studio = settings().Studio

-- | Constants | --
local MARKS = {
	healthy = { emoji = "\u{1F7E2}", color = Color3.fromRGB(67, 181, 97) },
	held = { emoji = "\u{1F7E1}", color = Color3.fromRGB(232, 163, 45) },
	broken = { emoji = "\u{1F534}", color = Color3.fromRGB(226, 76, 76) },
	warning = { emoji = "\u{26A0}\u{FE0F}", color = Color3.fromRGB(226, 76, 76) },
	notice = { emoji = "\u{1F4E2}", color = Color3.fromRGB(232, 163, 45) },
}

local TEXT_STYLES = {
	title = { font = Enum.Font.BuilderSansBold, size = 15, color = "MainText" },
	body = { font = Enum.Font.BuilderSans, size = 14, color = "MainText" },
	meta = { font = Enum.Font.BuilderSans, size = 13, color = "DimmedText" },
}

local CORNER_RADIUS = UDim.new(0, 8)
local CARD_PADDING = UDim.new(0, 10)
local CARD_GAP = UDim.new(0, 4)
local HINT_TRANSPARENCY = 0.5

-- | State Management | --
local Theme = {}

local painted = {}
local listeners = {}
local themeConnection: RBXScriptConnection? = nil


-- // FUNCTIONS // --
--[[
	Reads one colour from the theme Studio is showing now.

	@param name string -- a StudioStyleGuideColor item name
]]
function Theme.Color(name: string): Color3
	return studio.Theme:GetColor((Enum.StudioStyleGuideColor :: any)[name])
end

--[[
	Paints one property from the theme, and keeps it painted through every
	theme change.

	@param name string -- a StudioStyleGuideColor item name
]]
function Theme.Paint(instance: Instance, property: string, name: string)
	(instance :: any)[property] = Theme.Color(name)
	table.insert(painted, { instance = instance, property = property, name = name })
end

--[[
	Names the colour of a state.

	@param state string -- healthy, held, broken, warning or notice
]]
function Theme.StateColor(state: string): Color3
	return (MARKS[state] or MARKS.broken).color
end

--[[
	Shows a caption marked with the emoji and colour of a state, so it draws the
	eye, or plain in its themed colour when there is nothing to mark.

	@param state string? -- healthy, held, broken, warning or notice
]]
function Theme.Mark(label: TextLabel, caption: string, state: string?)
	local mark = if state then MARKS[state] else nil
	if mark then
		label.Text = mark.emoji .. " " .. caption
		label.TextColor3 = mark.color
	else
		label.Text = caption
		label.TextColor3 = Theme.Color("DimmedText")
	end
end

--[[
	Rounds the corners of one element.
]]
function Theme.Round(instance: GuiObject, radius: UDim?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius or CORNER_RADIUS
	corner.Parent = instance
end

--[[
	Builds one rounded card that grows with what it holds, stacking its
	contents top to bottom.

	@param order number -- position among its siblings
]]
function Theme.Card(parent: Instance, order: number): Frame
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.LayoutOrder = order
	card.Size = UDim2.fromScale(1, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BorderSizePixel = 0
	Theme.Paint(card, "BackgroundColor3", "InputFieldBackground")
	Theme.Round(card)

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = CARD_PADDING
	padding.PaddingBottom = CARD_PADDING
	padding.PaddingLeft = CARD_PADDING
	padding.PaddingRight = CARD_PADDING
	padding.Parent = card

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = CARD_GAP
	layout.Parent = card

	card.Parent = parent
	return card
end

--[[
	Builds one wrapping line of text that grows to fit what it says.

	@param style string -- title, body or meta
	@param order number -- position among its siblings
]]
function Theme.Text(parent: Instance, style: string, order: number): TextLabel
	local look = TEXT_STYLES[style] or TEXT_STYLES.body

	local label = Instance.new("TextLabel")
	label.LayoutOrder = order
	label.Size = UDim2.fromScale(1, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Font = look.font
	label.TextSize = look.size
	label.Text = ""
	Theme.Paint(label, "TextColor3", look.color)
	label.Parent = parent

	return label
end

--[[
	Builds one tile: a card the surrounding grid sizes, holding a caption above
	a single-line value.

	@param order number -- position among its siblings
	@return Frame -- the tile
	@return TextLabel -- the caption
	@return TextLabel -- the value
]]
function Theme.Tile(parent: Instance, order: number, caption: string): (Frame, TextLabel, TextLabel)
	local tile = Theme.Card(parent, order)
	tile.AutomaticSize = Enum.AutomaticSize.None

	local captionLabel = Theme.Text(tile, "meta", 1)
	captionLabel.Text = caption

	local valueLabel = Theme.Text(tile, "title", 2)
	valueLabel.TextWrapped = false
	valueLabel.TextTruncate = Enum.TextTruncate.AtEnd

	return tile, captionLabel, valueLabel
end

--[[
	Sets a label in italics.
]]
function Theme.Italic(label: TextLabel)
	label.FontFace = Font.new(label.FontFace.Family, label.FontFace.Weight, Enum.FontStyle.Italic)
end

--[[
	Shows a label as a faint hint, or as ordinary text again.
]]
function Theme.Hint(label: TextLabel, hinted: boolean)
	label.TextTransparency = if hinted then HINT_TRANSPARENCY else 0
	label.FontFace = Font.new(
		label.FontFace.Family,
		label.FontFace.Weight,
		if hinted then Enum.FontStyle.Italic else Enum.FontStyle.Normal
	)
end

--[[
	Subscribes to theme changes, called after every painted element has been
	repainted.
]]
function Theme.OnChanged(listener: () -> ())
	table.insert(listeners, listener)
end

--[[
	Starts following the Studio theme.
]]
function Theme.Start()
	if themeConnection then
		return
	end

	themeConnection = studio.ThemeChanged:Connect(function()
		for _, entry in painted do
			entry.instance[entry.property] = Theme.Color(entry.name)
		end
		for _, listener in listeners do
			listener()
		end
	end)
end

--[[
	Stops following the Studio theme and forgets everything painted.
]]
function Theme.Stop()
	if themeConnection then
		themeConnection:Disconnect()
		themeConnection = nil
	end
	table.clear(painted)
	table.clear(listeners)
end

return Theme
