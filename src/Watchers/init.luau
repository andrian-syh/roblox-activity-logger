--[[
	Watchers - Watcher registry

	Runs every activity watcher as one unit, in the order they must start.

	- Starts each watcher, skipping and reporting any that fails
	- Gives each running watcher a turn to release folded activity
	- Stops each running watcher and releases what it still holds

	Note: to add a source of activity, write a module beside this one exposing
	Name and Start, then list it below.
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Config)
local Safe = require(script.Parent.Safe)

-- | Types | --
type Watcher = {
	Name: string,
	Start: () -> (),
	Tick: (() -> ())?,
	Stop: (() -> ())?,
}

-- | Configuration | --
local WATCHERS: { Watcher } = {
	require(script.Presence),
	require(script.Structure),
	require(script.History),
	require(script.Editor),
	require(script.ScriptSource),
	require(script.Properties),
}

-- | State Management | --
local Watchers = {}

local started = {}

--[[
	Starts every watcher, skipping and reporting any that fails.

	@return number -- how many watchers are running
]]
function Watchers.Start(): number
	for _, watcher in WATCHERS do
		if Safe.Call(watcher.Start) then
			table.insert(started, watcher)
		else
			warn(string.format("%s: watcher %s did not start", Config.DISPLAY_NAME, watcher.Name))
		end
	end
	return #started
end

--[[
	Gives every running watcher a chance to release folded activity.
]]
function Watchers.Tick()
	for _, watcher in started do
		if watcher.Tick then
			Safe.Call(watcher.Tick)
		end
	end
end

--[[
	Stops every running watcher and releases whatever they still hold.
]]
function Watchers.Stop()
	for index = #started, 1, -1 do
		local watcher = started[index]
		if watcher.Stop then
			Safe.Call(watcher.Stop)
		end
		started[index] = nil
	end
end

return Watchers
