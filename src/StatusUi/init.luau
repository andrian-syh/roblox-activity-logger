--[[
	StatusUi - Logger panel

	Shows whether activity is reaching the collector, what the supervisor has
	to say, and what has just been recorded, and opens itself when something
	is wrong.

	- Builds the docked panel, its tiles, cards, feed and toolbar button
	- Arranges tiles and cards beside the feed when wide, above it when narrow
	- Fits as many tile columns as the width allows
	- Paints every tile and card from delivery health and the supervisor's settings
	- Shows a fault that stops the plugin running at all
	- Passes recorded activity to the feed and redraws it on a timer
	- Follows the Studio theme until the plugin unloads

	Note: the panel forces itself open on trouble, because a silent logger
	looks exactly like a working one.
]]

-- // VARIABLES // --
-- | Modules | --
local Cards = require(script.Cards)
local Config = require(script.Parent.Config)
local Deployment = require(script.Parent.Deployment)
local Feed = require(script.Feed)
local Theme = require(script.Theme)
local Transport = require(script.Parent.Transport)

-- | Constants | --
local GAP = 8
local SCROLLBAR_ROOM = 6

local LANDSCAPE_MIN_WIDTH = 560
local LANDSCAPE_MIN_RATIO = 1.2
local COLUMN_SHARE = 0.36
local COLUMN_MIN_WIDTH = 280
local COLUMN_MAX_WIDTH = 400
local PORTRAIT_COLUMN_SHARE = 0.55

local TILE_MIN_WIDTH = 120
local TILE_HEIGHT = 56

-- | State Management | --
local StatusUi = {}

local widget: DockWidgetPluginGui
local area: Frame
local column: ScrollingFrame
local columnLayout: UIListLayout
local tiles: Frame
local tileGrid: UIGridLayout
local feedCard: Frame
local button: PluginToolbarButton

local fatalReason: string? = nil
local lastHealth: Transport.Health = Transport.GetHealth()


-- // FUNCTIONS // --
--[[
	Sizes the tiles to share the column width evenly, as many to a row as fit,
	balancing the rows so no tile is left alone on the last one.

	@param width number -- the width the tiles have to fill
]]
local function fitTiles(width: number)
	local shown = 0
	for _, child in tiles:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then
			shown += 1
		end
	end

	shown = math.max(shown, 1)
	local fits = math.clamp(math.floor((width + GAP) / (TILE_MIN_WIDTH + GAP)), 1, shown)
	local perRow = math.ceil(shown / math.ceil(shown / fits))
	local cellWidth = math.floor((width - GAP * (perRow - 1)) / perRow)

	tileGrid.FillDirectionMaxCells = perRow
	tileGrid.CellSize = UDim2.fromOffset(cellWidth, TILE_HEIGHT)
end

--[[
	Places tiles and cards beside the feed when the panel is wide, and above it
	when the panel is narrow or tall.
]]
local function arrange()
	local size = area.AbsoluteSize
	local landscape = size.X >= LANDSCAPE_MIN_WIDTH and size.X >= size.Y * LANDSCAPE_MIN_RATIO

	if landscape then
		local width = math.clamp(math.floor(size.X * COLUMN_SHARE), COLUMN_MIN_WIDTH, COLUMN_MAX_WIDTH)
		column.Size = UDim2.new(0, width, 1, 0)
		feedCard.Position = UDim2.fromOffset(width + GAP, 0)
		feedCard.Size = UDim2.new(1, -(width + GAP), 1, 0)
		fitTiles(width - SCROLLBAR_ROOM - 1)
	else
		fitTiles(size.X - SCROLLBAR_ROOM - 1)
		local height = math.min(
			columnLayout.AbsoluteContentSize.Y + 2,
			math.floor(size.Y * PORTRAIT_COLUMN_SHARE)
		)
		column.Size = UDim2.new(1, 0, 0, height)
		feedCard.Position = UDim2.fromOffset(0, height + GAP)
		feedCard.Size = UDim2.new(1, 0, 1, -(height + GAP))
	end
end

--[[
	Paints every tile and card from the last known health and the supervisor's
	current settings, and opens the panel when any of it needs attention.
]]
local function paint()
	local state: Cards.State = {
		Health = lastHealth,
		Fatal = fatalReason,
		Paused = Deployment.IsPaused(),
		Announcement = Deployment.Announcement(),
		Outdated = Deployment.IsOutdated(),
		RequiredVersion = Deployment.RequiredVersion(),
	}

	for _, card in Cards do
		if card.Update then
			card.Update(state)
		end
	end

	if state.Fatal or not state.Health.Healthy or state.Outdated then
		widget.Enabled = true
	end
	button:SetActive(widget.Enabled)
end

--[[
	Builds the column holding the tile grid above the full-width cards.
]]
local function buildColumn(plugin: Plugin)
	column = Instance.new("ScrollingFrame")
	column.BackgroundTransparency = 1
	column.BorderSizePixel = 0
	column.ScrollBarThickness = 4
	column.ScrollingDirection = Enum.ScrollingDirection.Y
	column.CanvasSize = UDim2.new()
	column.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Theme.Paint(column, "ScrollBarImageColor3", "DimmedText")
	column.Parent = area

	local columnPadding = Instance.new("UIPadding")
	columnPadding.PaddingTop = UDim.new(0, 1)
	columnPadding.PaddingBottom = UDim.new(0, 1)
	columnPadding.PaddingLeft = UDim.new(0, 1)
	columnPadding.PaddingRight = UDim.new(0, SCROLLBAR_ROOM)
	columnPadding.Parent = column

	columnLayout = Instance.new("UIListLayout")
	columnLayout.SortOrder = Enum.SortOrder.LayoutOrder
	columnLayout.Padding = UDim.new(0, GAP)
	columnLayout.Parent = column

	tiles = Instance.new("Frame")
	tiles.LayoutOrder = 0
	tiles.Size = UDim2.fromScale(1, 0)
	tiles.AutomaticSize = Enum.AutomaticSize.Y
	tiles.BackgroundTransparency = 1
	tiles.Parent = column

	tileGrid = Instance.new("UIGridLayout")
	tileGrid.SortOrder = Enum.SortOrder.LayoutOrder
	tileGrid.CellPadding = UDim2.fromOffset(GAP, GAP)
	tileGrid.Parent = tiles

	for order, card in Cards do
		card.Build(if card.Slot == "tile" then tiles else column, order, plugin)
	end
end

--[[
	Builds the panel, its tiles, cards, feed and toolbar button.
]]
function StatusUi.Build(plugin: Plugin)
	widget = plugin:CreateDockWidgetPluginGuiAsync(
		Config.WIDGET_ID,
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Bottom, false, false, 720, 300, 320, 240)
	)
	widget.Name = Config.WIDGET_ID
	widget.Title = Config.DISPLAY_NAME

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BorderSizePixel = 0
	Theme.Paint(root, "BackgroundColor3", "MainBackground")
	root.Parent = widget

	local rootPadding = Instance.new("UIPadding")
	rootPadding.PaddingTop = UDim.new(0, GAP)
	rootPadding.PaddingBottom = UDim.new(0, GAP)
	rootPadding.PaddingLeft = UDim.new(0, GAP)
	rootPadding.PaddingRight = UDim.new(0, GAP)
	rootPadding.Parent = root

	area = Instance.new("Frame")
	area.Size = UDim2.fromScale(1, 1)
	area.BackgroundTransparency = 1
	area.Parent = root

	buildColumn(plugin)
	feedCard = Feed.Build(area, 0)

	area:GetPropertyChangedSignal("AbsoluteSize"):Connect(arrange)
	columnLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(arrange)

	Theme.OnChanged(paint)
	Theme.Start()

	local toolbar = plugin:CreateToolbar(Config.DISPLAY_NAME)
	button = toolbar:CreateButton(
		"Status",
		"Show logger delivery status",
		"rbxasset://textures/ui/GuiImagePlaceholder.png"
	)
	button.ClickableWhenViewportHidden = true

	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)

	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end)

	paint()
	arrange()
end

--[[
	Shows that the plugin cannot run at all, and why.

	@param reason string -- what stops it, for the person at this machine
]]
function StatusUi.ShowFatal(reason: string)
	fatalReason = reason
	paint()
end

--[[
	Repaints the panel from the current delivery health, from what the
	supervisor has set, and from whether this build is still accepted.
]]
function StatusUi.Render(health: Transport.Health)
	lastHealth = health
	paint()
end

--[[
	Passes one recorded event to the feed.

	@param event {[string]: any} -- the event as it was recorded
]]
function StatusUi.Record(event: { [string]: any })
	Feed.Record(event)
end

--[[
	Redraws the feed if anything new was recorded since the last turn.
]]
function StatusUi.Tick()
	Feed.Tick()
end

--[[
	Stops following the Studio theme.
]]
function StatusUi.Stop()
	Theme.Stop()
end

return StatusUi
