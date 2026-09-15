--[[
	Status - Delivery status tile

	Says in one word whether activity is reaching the collector, coloured and
	dotted to read at a glance.

	- Builds the tile with its state dot
	- Paints the tile as recording, paused, not delivering or stopped
]]

-- // VARIABLES // --
-- | Modules | --
local Theme = require(script.Parent.Parent.Theme)

-- | Types | --
type State = { [string]: any }

-- | Constants | --
local DOT_SIZE = 10
local DOT_GAP = 6

-- | State Management | --
local Status = {}

Status.Slot = "tile"

local dot: Frame
local value: TextLabel


-- // FUNCTIONS // --
--[[
	Builds the tile.
]]
function Status.Build(parent: Instance, order: number)
	local _, caption, builtValue = Theme.Tile(parent, order, "Status")
	value = builtValue

	local inset = Instance.new("UIPadding")
	inset.PaddingLeft = UDim.new(0, DOT_SIZE + DOT_GAP)
	inset.Parent = caption

	dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
	dot.Position = UDim2.new(0, -(DOT_SIZE + DOT_GAP), 0.5, -DOT_SIZE / 2)
	dot.BorderSizePixel = 0
	Theme.Round(dot, UDim.new(1, 0))
	dot.Parent = caption
end

--[[
	Paints the tile from the current state.
]]
function Status.Update(state: State)
	local tone

	if state.Fatal then
		tone, value.Text = "broken", "Stopped"
	elseif not state.Health.Healthy then
		tone, value.Text = "broken", "Not delivering"
	elseif state.Paused then
		tone, value.Text = "held", "Paused"
	else
		tone, value.Text = "healthy", "Recording"
	end

	local color = Theme.StateColor(tone)
	dot.BackgroundColor3 = color
	value.TextColor3 = color
end

return Status
