--[[
	Version - Plugin version tile

	Names the build running on this machine, marked when the supervisor no
	longer accepts it.

	- Builds the tile
	- Paints the tile as current or outdated
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Parent.Parent.Config)
local Theme = require(script.Parent.Parent.Theme)

-- | Types | --
type State = { [string]: any }

-- | State Management | --
local Version = {}

Version.Slot = "tile"

local caption: TextLabel


-- // FUNCTIONS // --
--[[
	Builds the tile.
]]
function Version.Build(parent: Instance, order: number)
	local _, builtCaption, value = Theme.Tile(parent, order, "Version")
	caption = builtCaption
	value.Text = Config.VERSION
end

--[[
	Paints the tile from the current state.
]]
function Version.Update(state: State)
	Theme.Mark(caption, "Version", if state.Outdated then "warning" else nil)
end

return Version
