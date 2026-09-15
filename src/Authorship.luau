--[[
	Authorship - Local authorship verdict

	Decides whether a change started on this machine, and whether a person, an
	assistant, a tool or a collaborator made it.

	- Reports the verdict and origin for a change happening now
	- Recognises change recordings named by assistants and sync tools
	- Holds an event open so later evidence can still upgrade it
	- Records evidence of local work and upgrades everything still open
	- Tracks whether anyone else is editing the place
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

local USER = "user"
local UNATTENDED = "unattended"
local COLLABORATOR = "collaborator"

local ORIGIN_RANK = {
	[COLLABORATOR] = 0,
	[UNATTENDED] = 1,
	[USER] = 2,
	assistant = 2,
	tool = 2,
}

-- | State Management | --
local Authorship = {}

local pending = {}
local lastProofClock = -math.huge
local lastProofOrigin = USER
local lastProofLabel = ""
local alone = true


-- // FUNCTIONS // --
--[[
	Drops held events that are too old to be explained by new evidence.
]]
local function prune()
	local now = os.clock()
	while pending[1] and now - pending[1].clock > Config.LOCAL_ACTIVITY_WINDOW_SECONDS do
		table.remove(pending, 1)
	end
end

--[[
	Names the assistant or tool behind a change recording, when its name says.

	@param label string -- the change recording name, or an empty string
	@return string? -- the origin, or nil when the name belongs to nobody known
]]
function Authorship.OriginOf(label: string): string?
	if label == "" then
		return nil
	end
	for _, known in Config.KNOWN_RECORDINGS do
		if label:sub(1, #known.prefix) == known.prefix then
			return known.origin
		end
	end
	return nil
end

--[[
	Reports the verdict, origin and recording name for a change happening now.

	A recording's own structural changes can be reported just after it closes,
	so the most recent evidence lends them its origin and name.

	@param label string -- the change recording in progress, or an empty string
	@return string -- whether the change started on this machine
	@return string -- who or what made the change
	@return string -- the recording the change belongs to, or an empty string
]]
function Authorship.Classify(label: string): (string, string, string)
	local named = Authorship.OriginOf(label)
	if named then
		return AUTHORED, named, label
	end
	if os.clock() - lastProofClock <= Config.LOCAL_ACTIVITY_WINDOW_SECONDS then
		return AUTHORED, lastProofOrigin, if label ~= "" then label else lastProofLabel
	end
	if alone then
		return AUTHORED, UNATTENDED, label
	end
	return OBSERVED, COLLABORATOR, label
end

--[[
	Holds an event open so later evidence can still upgrade its verdict.

	@param event {[string]: any} -- the event to keep revisable
]]
function Authorship.Hold(event: { [string]: any })
	prune()
	if os.clock() - event.clock <= Config.LOCAL_ACTIVITY_WINDOW_SECONDS then
		table.insert(pending, event)
	end
end

--[[
	Records evidence of local work, and upgrades every event still open that
	was credited to something less certain.

	@param origin string? -- who did the work, a person when omitted
	@param label string? -- the recording that proves it, when there was one
]]
function Authorship.Prove(origin: string?, label: string?)
	local proven = origin or USER
	local provenRank = ORIGIN_RANK[proven] or ORIGIN_RANK[USER]
	lastProofClock = os.clock()
	lastProofOrigin = proven
	lastProofLabel = label or ""
	prune()

	for _, event in pending do
		if event.confidence == "" then
			continue
		end
		event.confidence = AUTHORED
		if (ORIGIN_RANK[event.origin] or 0) < provenRank then
			event.origin = proven
			if event.via == "" then
				event.via = lastProofLabel
			end
		end
	end
end

--[[
	Records whether anyone else is editing the place, which decides who an
	unexplained change is credited to.

	@param isAlone boolean -- whether the local user is the only editor
]]
function Authorship.SetAlone(isAlone: boolean)
	alone = isAlone
end

--[[
	Forgets all held events and evidence.
]]
function Authorship.Reset()
	table.clear(pending)
	lastProofClock = -math.huge
	lastProofOrigin = USER
	lastProofLabel = ""
	alone = true
end

return Authorship
