--[[
	EventLog - Activity event builder

	Builds activity events in one shape and hands them to the transport.

	- Stamps time, mode, transaction, verdict and origin on every event
	- Stamps the same onto an entry that will be written later
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
	origin: string?,
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
	Stamps the transaction, verdict and origin for a change happening now onto
	an entry that will be written later.

	@param entry {[string]: any} -- the entry to stamp
	@return {[string]: any} -- the same entry
]]
function EventLog.Stamp(entry: { [string]: any }): { [string]: any }
	entry.confidence, entry.origin, entry.via = Authorship.Classify(recordingLabel)
	return entry
end

--[[
	Records one activity event.

	@param kind string -- the activity category
	@param target string -- what the activity concerns
	@param detail Detail? -- fields specific to this category
]]
function EventLog.Write(kind: string, target: string, detail: Detail?)
	local confidence, origin, via = Authorship.Classify(recordingLabel)
	local event: { [string]: any } = {
		epoch = os.time(),
		clock = os.clock(),
		kind = kind,
		target = target,
		mode = currentMode(),
		via = via,
		confidence = confidence,
		origin = origin,
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
	local confidence, origin, via = Authorship.Classify(recordingLabel)
	local event: { [string]: any } = {
		epoch = entry._epoch or os.time(),
		clock = entry._clock or os.clock(),
		kind = kind,
		target = target,
		mode = currentMode(),
		via = entry.via or via,
		confidence = entry.confidence or confidence,
		origin = entry.origin or origin,
	}

	for key, value in detail :: any do
		event[key] = value
	end

	Transport.Push(event)
	Authorship.Hold(event)
end

return EventLog
