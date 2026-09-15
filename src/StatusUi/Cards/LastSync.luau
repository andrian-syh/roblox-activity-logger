--[[
	LastSync - Last delivery tile

	Shows when activity last reached the collector.

	- Builds the tile
	- Shows the time of the last successful delivery, or that there was none
]]

-- // VARIABLES // --
-- | Modules | --
local Theme = require(script.Parent.Parent.Theme)

-- | Types | --
type State = { [string]: any }

-- | State Management | --
local LastSync = {}

LastSync.Slot = "tile"

local value: TextLabel


-- // FUNCTIONS // --
--[[
	Builds the tile.
]]
function LastSync.Build(parent: Instance, order: number)
	local _, _, builtValue = Theme.Tile(parent, order, "Last Sync")
	value = builtValue
end

--[[
	Paints the tile from the current state.
]]
function LastSync.Update(state: State)
	local epoch = state.Health.LastSuccessEpoch
	value.Text = if epoch > 0 then os.date("%H:%M:%S", epoch) else "Never"
end

return LastSync
