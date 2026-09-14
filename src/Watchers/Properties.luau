--[[
	Properties - Property and attribute watcher

	Reports property and attribute changes on whatever the user has selected.

	- Reports each selection change and what was selected
	- Watches every property of a selected instance through one subscription
	- Handles a single-value container, which reports values not names
	- Reports attribute changes alongside properties
	- Folds a run of changes to one property into a single entry
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
	Releases one folded run of changes to a single property.

	@param entry {[string]: any} -- the folded run
]]
local function release(entry: { [string]: any })
	EventLog.WriteFolded("property", entry.path, entry, {
		className = entry.className,
		property = entry.property,
		oldValue = entry.from,
		newValue = entry.to,
		amount = entry.count,
	})
end

--[[
	Records one property change, folding it into any run already in progress.

	@param instance Instance -- the instance that changed
	@param property string -- the property that changed
	@param before string? -- the value held before the run began
]]
local function note(instance: Instance, property: string, before: string?)
	if Config.DERIVED_PROPERTIES[property] then
		return
	end

	local path = Naming.PathOf(instance)

	edits:Add(path .. "|" .. property, function()
		return {
			path = path,
			property = property,
			className = instance.ClassName,
			from = before or "<unknown>",
			to = Naming.DescribeProperty(instance, property),
			count = 1,
			via = EventLog.Transaction(),
			confidence = Authorship.Verdict(),
		}
	end, function(entry)
		entry.to = Naming.DescribeProperty(instance, property)
		entry.count += 1
	end)
end

--[[
	Watches every property and attribute of one instance.

	A container of a single value reports that value rather than a property
	name, so it is subscribed to on its own terms.

	@param instance Instance -- the instance to watch
]]
local function watch(instance: Instance)
	Naming.PathOf(instance)

	if instance:IsA("ValueBase") then
		local signal = Safe.Value(function()
			return instance:GetPropertyChangedSignal("Value")
		end)
		if signal then
			local previous = Naming.DescribeProperty(instance, "Value")
			selectionBin:Add(signal:Connect(Safe.Handler("ValueChanged", function()
				note(instance, "Value", previous)
				previous = Naming.DescribeProperty(instance, "Value")
			end)))
		end
	else
		local previousValues = {}
		selectionBin:Add(instance.Changed:Connect(Safe.Handler("Changed", function(property: string)
			if Config.DERIVED_PROPERTIES[property] then
				return
			end
			note(instance, property, previousValues[property])
			previousValues[property] = Naming.DescribeProperty(instance, property)
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
	afford them, so selecting a whole service costs nothing but their names.

	@return {Instance} -- the instances to subscribe to
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
		else
			Naming.Remember(instance)
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
