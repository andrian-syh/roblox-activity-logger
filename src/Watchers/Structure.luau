--[[
	Structure - Instance tree watcher

	Reports instances entering and leaving the services that hold project
	content.

	- Reports an instance appearing, with its path and class
	- Ignores the classes Studio maintains for itself
	- Reports an instance leaving, named as it was before detaching
	- Folds a subtree arriving or leaving at once into one row for its root
	- Reports an instance leaving one place and arriving in another as a move
	- Recognises a cut followed by a paste of the same content as a move
	- Caps how many rows one burst can produce, counting the rest
	- Lists the watched services this place actually has
	- Announces instances arriving and leaving to watchers that track them

	Note: a removal is held back briefly, because a paste arriving later is the
	only thing that tells a cut apart from a deletion.
]]

-- // VARIABLES // --
-- | Modules | --
local Bin = require(script.Parent.Parent.Bin)
local Config = require(script.Parent.Parent.Config)
local EventLog = require(script.Parent.Parent.EventLog)
local Naming = require(script.Parent.Parent.Naming)
local Safe = require(script.Parent.Parent.Safe)

-- | Types | --
type Row = {
	instance: Instance,
	service: string,
	target: string,
	className: string,
	nested: number,
	paired: boolean,
	signature: string?,
	epoch: number,
	clock: number,
	via: string,
	confidence: string,
	origin: string,
}

type Burst = {
	rows: { Row },
	byInstance: { [Instance]: Row },
	byPath: { [string]: Row },
	overflowTarget: string?,
	overflowCount: number,
}

-- | Constants | --
local SIGNATURE_SAMPLE = 50

-- | State Management | --
local Structure = {}

Structure.Name = "Structure"

local bin = Bin.new()
local listeners = {}
local removalListeners = {}
local bursts: { [string]: Burst } = {}
local held: { Row } = {}
local closeScheduled = false


-- // FUNCTIONS // --
--[[
	Announces a new instance to anything that wants to watch it.
]]
local function announce(instance: Instance)
	for _, listener in listeners do
		Safe.Call(listener, instance)
	end
end

--[[
	Describes a subtree by its shape, so a pasted copy can be recognised as the
	content that was cut.

	@param nested number -- how many instances the subtree holds
	@return string -- identical for identical content
]]
local function signatureOf(instance: Instance, nested: number): string
	local parts = { instance.ClassName, instance.Name, tostring(nested) }

	if instance:IsA("BasePart") then
		table.insert(parts, tostring(Safe.Property(instance, "Size")))
		table.insert(parts, tostring(Safe.Property(instance, "Color")))
		table.insert(parts, tostring(Safe.Property(instance, "Material")))
	elseif instance:IsA("LuaSourceContainer") then
		local source = Safe.Property(instance, "Source")
		table.insert(parts, tostring(typeof(source) == "string" and #source or 0))
	end

	local descendants = Safe.Value(function()
		return instance:GetDescendants()
	end)
	if typeof(descendants) == "table" then
		for index = 1, math.min(#descendants, SIGNATURE_SAMPLE) do
			local descendant = descendants[index]
			table.insert(parts, descendant.ClassName .. ":" .. descendant.Name)
		end
	end

	return table.concat(parts, "|")
end

--[[
	Writes a single row for a structural change.

	@param kind string -- the structural change
	@param detail EventLog.Detail? -- fields beyond class and size
]]
local function writeRow(kind: string, row: Row, detail: EventLog.Detail?)
	local fields: EventLog.Detail = detail or {}
	fields.className = row.className
	fields.amount = if row.nested > 0 then row.nested else nil
	EventLog.WriteFolded(kind, row.target, {
		_epoch = row.epoch,
		_clock = row.clock,
		via = row.via,
		confidence = row.confidence,
		origin = row.origin,
	}, fields)
end

--[[
	Writes one instance leaving one place and arriving in another.

	@param departure Row -- the instance as it left
	@param arrival Row -- the instance as it arrived
	@param operation string? -- how the move was made, when not a reparent
]]
local function writeMove(departure: Row, arrival: Row, operation: string?)
	local knownOrigin = departure.target ~= arrival.target and departure.target:find("%.") ~= nil

	writeRow("moved", arrival, {
		oldValue = if knownOrigin then departure.target else departure.service,
		newValue = arrival.target,
		operation = operation,
	})
end

--[[
	Pairs an arrival with a removal still held back, if one matches.

	The same instance coming back is a restore or a move; different instances
	with identical content are a paste of what was cut.

	@return boolean -- whether the arrival was reported as part of a pair
]]
local function claimHeld(arrival: Row): boolean
	local signature

	for index, departure in held do
		local sameInstance = rawequal(departure.instance, arrival.instance)
		if not sameInstance then
			signature = signature or signatureOf(arrival.instance, arrival.nested)
			if departure.signature ~= signature or departure.target == arrival.target then
				continue
			end
		end

		table.remove(held, index)

		if sameInstance and departure.target == arrival.target then
			writeRow("restored", arrival)
		else
			writeMove(departure, arrival, if sameInstance then nil else "cutPaste")
		end
		return true
	end

	return false
end

--[[
	Writes out removals held back for longer than a paste could still claim.

	@param force boolean? -- release every held removal regardless of age
]]
local function releaseHeld(force: boolean?)
	local now = os.clock()

	for index = #held, 1, -1 do
		local row = held[index]
		if not force and now - row.clock < Config.CUT_PASTE_WINDOW_SECONDS then
			continue
		end

		table.remove(held, index)
		EventLog.WriteFolded("removed", row.target, {
			_epoch = row.epoch,
			_clock = row.clock,
			via = row.via,
			confidence = row.confidence,
			origin = row.origin,
		}, {
			className = row.className,
			amount = if row.nested > 0 then row.nested else nil,
		})
	end
end

--[[
	Writes out the overflow of one burst as a single counting row.

	@param kind string -- the structural change
	@param burst Burst? -- the burst that may have overflowed
]]
local function writeOverflow(kind: string, burst: Burst?)
	if burst and burst.overflowTarget then
		EventLog.Write(kind, burst.overflowTarget, {
			amount = burst.overflowCount,
			operation = "burst",
		})
	end
end

--[[
	Closes every burst gathered so far: pairs moves, holds removals back for a
	possible paste, and writes the arrivals that pair with nothing.
]]
local function closeBursts()
	closeScheduled = false

	local closing = bursts
	bursts = {}

	local removed = closing.removed
	local added = closing.added

	if removed then
		for _, departure in removed.rows do
			departure.signature = signatureOf(departure.instance, departure.nested)
		end
	end

	if added then
		for _, arrival in added.rows do
			local departure = removed and removed.byInstance[arrival.instance]
			if departure then
				departure.paired = true
				writeMove(departure, arrival, nil)
			elseif not claimHeld(arrival) then
				writeRow("added", arrival)
			end
		end
	end

	if removed then
		for _, departure in removed.rows do
			if not departure.paired then
				table.insert(held, departure)
			end
		end
	end

	writeOverflow("removed", removed)
	writeOverflow("added", added)
end

--[[
	Returns the open burst of one kind, opening it if needed.

	Everything a single operation raises is delivered before the burst closes,
	so a subtree always lands inside one burst.

	@param kind string -- the structural change being gathered
]]
local function burstOf(kind: string): Burst
	local burst = bursts[kind]
	if burst then
		return burst
	end

	burst = {
		rows = {},
		byInstance = {},
		byPath = {},
		overflowTarget = nil,
		overflowCount = 0,
	}
	bursts[kind] = burst

	if not closeScheduled then
		closeScheduled = true
		task.defer(Safe.Handler("CloseBursts", closeBursts))
	end

	return burst
end

--[[
	Finds the row of an ancestor already reported in the same burst.

	A destroyed subtree keeps no ancestry, so its remembered path is checked
	when the live parent chain is gone.

	@param path string -- the path the instance is reported under
	@return Row? -- the ancestor's row, or nil when this instance is a root
]]
local function ancestorRow(burst: Burst, instance: Instance, path: string): Row?
	local ancestor = instance.Parent
	while ancestor do
		local row = burst.byInstance[ancestor]
		if row then
			return row
		end
		ancestor = ancestor.Parent
	end

	local prefix = path
	while true do
		local lastDot = prefix:match("^.*()%.")
		if not lastDot then
			return nil
		end
		prefix = prefix:sub(1, lastDot - 1)
		local row = burst.byPath[prefix]
		if row then
			return row
		end
	end
end

--[[
	Gathers one structural change into the burst of its kind.

	@param kind string -- the structural change
	@param service Instance -- the watched service that raised the change
	@param instance Instance -- the instance that arrived or left
	@param path string -- the path to report it under
]]
local function gather(kind: string, service: Instance, instance: Instance, path: string)
	if Config.IGNORED_CLASSES[instance.ClassName] then
		return
	end

	local burst = burstOf(kind)

	local parentRow = ancestorRow(burst, instance, path)
	if parentRow then
		parentRow.nested += 1
		return
	end

	if #burst.rows >= Config.MAX_STRUCTURE_ROWS_PER_BURST then
		burst.overflowTarget = burst.overflowTarget or path
		burst.overflowCount += 1
		return
	end

	local row: Row = EventLog.Stamp({
		instance = instance,
		service = service.Name,
		target = path,
		className = instance.ClassName,
		nested = 0,
		paired = false,
		signature = nil,
		epoch = os.time(),
		clock = os.clock(),
	}) :: any
	table.insert(burst.rows, row)
	burst.byInstance[instance] = row
	burst.byPath[path] = row
end

--[[
	Subscribes to instances appearing anywhere in the watched services.

	@param listener (Instance) -> () -- called for each new instance
]]
function Structure.OnInstanceAdded(listener: (Instance) -> ())
	table.insert(listeners, listener)
end

--[[
	Subscribes to instances leaving the watched services.

	@param listener (Instance) -> () -- called for each departing instance
]]
function Structure.OnInstanceRemoved(listener: (Instance) -> ())
	table.insert(removalListeners, listener)
end

--[[
	Returns every service holding project content that this place has.
]]
function Structure.Roots(): { Instance }
	local roots = {}
	for _, serviceName in Config.WATCHED_SERVICES do
		local service = Safe.Value(function()
			return game:GetService(serviceName :: any)
		end)
		if service then
			table.insert(roots, service)
		end
	end
	return roots
end

--[[
	Begins reporting structural change.
]]
function Structure.Start()
	for _, root in Structure.Roots() do
		bin:Add(root.DescendantAdded:Connect(Safe.Handler("DescendantAdded", function(descendant: Instance)
			gather("added", root, descendant, Naming.PathOf(descendant))
			announce(descendant)
		end)))

		bin:Add(root.DescendantRemoving:Connect(Safe.Handler("DescendantRemoving", function(descendant: Instance)
			gather("removed", root, descendant, Naming.RemovedPathOf(descendant))
			Naming.Forget(descendant)
			for _, listener in removalListeners do
				Safe.Call(listener, descendant)
			end
		end)))
	end
end

--[[
	Writes out removals that no paste claimed in time.
]]
function Structure.Tick()
	releaseHeld()
end

--[[
	Stops reporting structural change and writes out everything still open or
	held back.
]]
function Structure.Stop()
	bin:Clear()
	table.clear(listeners)
	table.clear(removalListeners)
	closeBursts()
	releaseHeld(true)
end

return Structure
