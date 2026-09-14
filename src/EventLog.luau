--[[
	EventLog - Activity event builder

	Builds activity events in one shape and hands them to the transport.

	- Stamps time, mode, transaction and verdict on every event
	- Records one event reported as it happens
	- Records one event folded from a burst, keeping its own verdict
	- Names the change transaction that later events belong to

	Note: every watcher reports through here, so none can invent its own event
	shape.
]]

-- // VARIABLES // --
-- | Services | --
local RunService = game:GetService("RunService")

-- | Modules | --
local Authorship = require(script.Parent.Authorship)
local Transport = require(script.Parent.Transport)

-- | Types | --
export type Detail = {
	className: string?,
	property: string?,
	oldValue: string?,
	newValue: string?,
	amount: number?,
	location: string?,
	preview: string?,
	operation: string?,
	confidence: string?,
	via: string?,
}

-- | State Management | --
local EventLog = {}

local recordingLabel = ""


-- // FUNCTIONS // --
--[[
	Reports whether the session is being edited or played.

	@return string -- the current session mode
]]
local function currentMode(): string
	return RunService:IsEdit() and "edit" or "run"
end

--[[
	Names the change transaction currently in progress, which later events are
	attributed to.

	@param label string -- the transaction label, or an empty string for none
]]
function EventLog.SetTransaction(label: string)
	recordingLabel = label
end

--[[
	Reports the transaction currently in progress.

	@return string -- the transaction label, or an empty string for none
]]
function EventLog.Transaction(): string
	return recordingLabel
end

--[[
	Records one activity event.

	@param kind string -- the activity category
	@param target string -- what the activity concerns
	@param detail Detail? -- fields specific to this category
]]
function EventLog.Write(kind: string, target: string, detail: Detail?)
	local event: { [string]: any } = {
		epoch = os.time(),
		clock = os.clock(),
		kind = kind,
		target = target,
		mode = currentMode(),
		via = recordingLabel,
		confidence = Authorship.Verdict(),
	}

	if detail then
		for key, value in detail :: any do
			event[key] = value
		end
	end

	Transport.Push(event)
	Authorship.Hold(event)
end

--[[
	Records one activity event that was folded from a burst, keeping the verdict
	and transaction reached when the burst began.

	@param kind string -- the activity category
	@param target string -- what the activity concerns
	@param entry {[string]: any} -- the folded burst, carrying its own verdict
	@param detail Detail -- fields specific to this category
]]
function EventLog.WriteFolded(kind: string, target: string, entry: { [string]: any }, detail: Detail)
	local event: { [string]: any } = {
		epoch = os.time(),
		clock = entry._clock or os.clock(),
		kind = kind,
		target = target,
		mode = currentMode(),
		via = entry.via or "",
		confidence = entry.confidence or Authorship.Verdict(),
	}

	for key, value in detail :: any do
		event[key] = value
	end

	Transport.Push(event)
end

return EventLog
