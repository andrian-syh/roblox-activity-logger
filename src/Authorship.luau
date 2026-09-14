--[[
	Authorship - Local authorship verdict

	Decides whether the local user caused a change or merely saw it replicate
	in from a collaborator.

	- Reports the standing verdict for a change happening now
	- Holds an event open so later evidence can still upgrade it
	- Records evidence of local work and upgrades everything still open
	- Releases events that are past revision
	- Forgets all held events and evidence

	Note: evidence can arrive either side of the change it explains, so it is
	applied in both directions.
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Config)

-- | Constants | --
local AUTHORED = "authored"
local OBSERVED = "observed"

-- | State Management | --
local Authorship = {}

local pending = {}
local lastProofClock = -math.huge


-- // FUNCTIONS // --
--[[
	Drops events that can no longer be explained by new evidence.
]]
local function prune()
	local now = os.clock()
	for index = #pending, 1, -1 do
		if now - pending[index].clock > Config.LOCAL_ACTIVITY_WINDOW_SECONDS then
			table.remove(pending, index)
		end
	end
end

--[[
	Reports the standing verdict for a change happening now.

	@return string -- the confidence to stamp on a new event
]]
function Authorship.Verdict(): string
	return (os.clock() - lastProofClock) <= Config.LOCAL_ACTIVITY_WINDOW_SECONDS and AUTHORED or OBSERVED
end

--[[
	Holds an event open so later evidence can still upgrade its verdict.

	@param event {[string]: any} -- the event to keep revisable
]]
function Authorship.Hold(event: { [string]: any })
	table.insert(pending, event)
end

--[[
	Records evidence that the local user is working, and upgrades the verdict
	of every event still open.
]]
function Authorship.Prove()
	lastProofClock = os.clock()
	prune()
	for _, event in pending do
		event.confidence = AUTHORED
	end
end

--[[
	Releases events that are past revision. Call on the maintenance timer.
]]
function Authorship.Tick()
	prune()
end

--[[
	Forgets all held events and evidence.
]]
function Authorship.Reset()
	table.clear(pending)
	lastProofClock = -math.huge
end

return Authorship
