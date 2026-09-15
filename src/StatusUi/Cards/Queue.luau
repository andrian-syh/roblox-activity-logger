--[[
	Queue - Waiting activity tile

	Shows how much activity is waiting to be delivered, marked once any of it
	has been lost.

	- Builds the tile
	- Shows the waiting count, and the lost count when there is one
]]

-- // VARIABLES // --
-- | Modules | --
local Theme = require(script.Parent.Parent.Theme)

-- | Types | --
type State = { [string]: any }

-- | State Management | --
local Queue = {}

Queue.Slot = "tile"

local caption: TextLabel
local value: TextLabel


-- // FUNCTIONS // --
--[[
	Builds the tile.
]]
function Queue.Build(parent: Instance, order: number)
	local _, builtCaption, builtValue = Theme.Tile(parent, order, "Queue")
	caption, value = builtCaption, builtValue
end

--[[
	Paints the tile from the current state.
]]
function Queue.Update(state: State)
	local health = state.Health
	local waiting = string.format("%d %s", health.PendingCount, if health.PendingCount == 1 then "event" else "events")
	local lost = health.DroppedCount > 0

	value.Text = if lost then string.format("%s, %d lost", waiting, health.DroppedCount) else waiting
	Theme.Mark(caption, "Queue", if lost then "warning" else nil)
end

return Queue
