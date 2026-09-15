--[[
	Properties - Property and attribute watcher

	Reports property and attribute changes on whatever the user has selected.

	- Reports each selection change and what was selected
	- Watches every property of a selected instance through one subscription
	- Handles a single-value container, which reports values not names
	- Reports attribute changes alongside properties
	- Folds a run of changes to one instance into a single entry
	- Leads that entry with the changed property readers care about most
	- Reads the properties people edit, so the first change knows its old value
	- Includes descendants only while the selection stays small

	Note: watching the whole place would cost one subscription per instance
	and stall Studio.
]]

-- // VARIABLES // --
-- | Services | --
local Selection = game:GetService("Selection")

-- | Modules | --
local Authorship = require(script.Parent.Parent.Authorship)
local Bin = require(script.Parent.Parent.Bin)
local Coalescer = require(script.Parent.Parent.Coalescer)
local Config = require(script.Parent.Parent.Config)
local EventLog = require(script.Parent.Parent.EventLog)
local Naming = require(script.Parent.Parent.Naming)
local Safe = require(script.Parent.Parent.Safe)

-- | State Management | --
local Properties = {}

Properties.Name = "Properties"

local selectionBin = Bin.new()
local serviceBin = Bin.new()
local edits


-- // FUNCTIONS // --
--[[
	Names the change a reader is most likely to have meant, when one gesture
	changed several properties at once.

	@return string -- the leading property, first in the order of interest
]]
local function leadingProperty(changed: { string }): string
	for _, candidate in Config.SNAPSHOT_PROPERTIES do
		if table.find(changed, candidate) then
			return candidate
		end
	end
	return changed[1]
end

--[[
	Releases one folded run of changes to one instance, reading the values the
	run settled on. One gesture moves, turns and resizes at once, so it is
	reported once, led by the property that says the most.
]]
local function release(entry: { [string]: any })
	local leading = leadingProperty(entry.changed)
	local settled = Naming.DescribeProperty(entry.instance, leading)

	local ordered = { leading }
	for _, property in entry.changed do
		entry.previousValues[property] = Naming.DescribeProperty(entry.instance, property)
		if property ~= leading then
			table.insert(ordered, property)
		end
	end

	EventLog.WriteFolded("property", entry.path, entry, {
		className = entry.className,
		property = table.concat(ordered, ", "),
		oldValue = entry.before[leading],
		newValue = settled,
		amount = entry.count,
	})
end

--[[
	Watches every property and attribute of one instance, reading up front the
	values people edit, so their first change knows what it replaced. A change
	that extends a run already open does no reading or naming at all.
]]
local function watch(instance: Instance)
	local path = Naming.PathOf(instance)
	local previousValues = {}

	for _, property in Config.SNAPSHOT_PROPERTIES do
		local value = Safe.Property(instance, property)
		if value ~= nil then
			previousValues[property] = Naming.Describe(value)
		end
	end

	local pending = ""

	local function fold(entry: { [string]: any })
		entry.count += 1
		if entry.before[pending] == nil then
			entry.before[pending] = previousValues[pending] or "<unknown>"
			table.insert(entry.changed, pending)
		end
	end

	local function note(property: string)
		pending = property

		if edits:Touch(path, fold) then
			return
		end

		edits:Add(path, function()
			local entry = EventLog.Stamp({
				instance = instance,
				path = path,
				className = instance.ClassName,
				previousValues = previousValues,
				before = {},
				changed = {},
				count = 0,
			})
			fold(entry)
			return entry
		end, fold)
	end

	if instance:IsA("ValueBase") then
		local signal = Safe.Value(function()
			return instance:GetPropertyChangedSignal("Value")
		end)
		if signal then
			selectionBin:Add(signal:Connect(Safe.Handler("ValueChanged", function()
				note("Value")
			end)))
		end
	else
		selectionBin:Add(instance.Changed:Connect(Safe.Handler("Changed", function(property: string)
			if Config.DERIVED_PROPERTIES[property] then
				return
			end
			if property == "Name" then
				edits:Release(path)
				path = Naming.PathOf(instance)
			end
			note(property)
		end)))
	end

	selectionBin:Add(instance.AttributeChanged:Connect(Safe.Handler("AttributeChanged", function(attribute: string)
		local value = Safe.Value(function()
			return instance:GetAttribute(attribute)
		end)
		EventLog.Write("attribute", Naming.PathOf(instance), {
			className = instance.ClassName,
			property = attribute,
			newValue = value == nil and "<unset>" or Naming.Describe(value),
		})
	end)))
end

--[[
	Collects the instances worth watching for the current selection.

	Descendants are included only while the selection stays small enough to
	afford them, so selecting a whole service costs almost nothing.
]]
local function selectionTargets(): { Instance }
	local targets = {}

	for _, instance in Selection:Get() do
		table.insert(targets, instance)

		local descendants = Safe.Value(function()
			return instance:GetDescendants()
		end)
		if typeof(descendants) ~= "table" then
			continue
		end

		if #targets + #descendants <= Config.MAX_WATCHED_DESCENDANTS then
			for _, descendant in descendants do
				table.insert(targets, descendant)
			end
		end
	end

	return targets
end

--[[
	Moves the watch onto whatever is selected now.
]]
local function rebind()
	selectionBin:Clear()
	for _, instance in selectionTargets() do
		watch(instance)
	end
end

--[[
	Begins reporting selection, property and attribute change.
]]
function Properties.Start()
	edits = Coalescer.new(Config.PROPERTY_COALESCE_SECONDS, release)

	serviceBin:Add(Selection.SelectionChanged:Connect(Safe.Handler("SelectionChanged", function()
		local selected = Selection:Get()
		rebind()
		EventLog.Write("selection", selected[1] and Naming.PathOf(selected[1]) or "none", {
			className = selected[1] and selected[1].ClassName or "",
			amount = #selected,
		})
		Authorship.Prove()
	end)))

	rebind()
end

--[[
	Releases property runs that have gone quiet.
]]
function Properties.Tick()
	edits:Drain()
end

--[[
	Stops reporting and releases everything still folded.
]]
function Properties.Stop()
	if edits then
		edits:Drain(true)
	end
	selectionBin:Clear()
	serviceBin:Clear()
end

return Properties
