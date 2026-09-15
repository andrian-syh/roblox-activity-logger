--[[
	Studio - Company tile

	Names the studio this plugin was built for, and is left out entirely when
	the build names none.

	- Builds the tile, hidden when no studio is named
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Parent.Parent.Config)
local Theme = require(script.Parent.Parent.Theme)

-- | State Management | --
local Studio = {}

Studio.Slot = "tile"


-- // FUNCTIONS // --
--[[
	Builds the tile.
]]
function Studio.Build(parent: Instance, order: number)
	local tile, _, value = Theme.Tile(parent, order, "Studio")
	value.Text = Config.COMPANY_TAG
	tile.Visible = Config.COMPANY_TAG ~= ""
end

return Studio
