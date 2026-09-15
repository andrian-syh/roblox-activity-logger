--[[
	Naming - Instance paths and value rendering

	Names instances for the log and renders values short enough to scan.

	- Names an instance still in the tree and remembers the name
	- Names an instance that has already left the tree
	- Forgets an instance so a reused reference inherits no stale name
	- Renders a value or a property, trimmed to a readable length
	- Flattens typed text into a single-line preview

	Note: an instance loses its ancestry before removal is reported, so the
	remembered name is the only one left by then.
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Config)
local Safe = require(script.Parent.Safe)

-- | State Management | --
local Naming = {}

local pathCache = setmetatable({}, { __mode = "k" })


-- // FUNCTIONS // --
--[[
	Names an instance that is still in the tree, and remembers the name.

	@return string -- the full path, or the last one seen for a detached instance
]]
function Naming.PathOf(instance: Instance): string
	local path = Safe.Value(function()
		return instance:GetFullName()
	end)

	if typeof(path) == "string" and path:find("%.") then
		pathCache[instance] = path
		return path
	end

	return pathCache[instance] or (typeof(path) == "string" and path) or "<unknown>"
end

--[[
	Names an instance that has already left the tree.

	@return string -- the last path seen while the instance was attached
]]
function Naming.RemovedPathOf(instance: Instance): string
	local cached = pathCache[instance]
	if cached then
		return cached
	end

	local path = Safe.Value(function()
		return instance:GetFullName()
	end)
	return typeof(path) == "string" and path or "<unknown>"
end

--[[
	Forgets an instance, so a reused reference cannot inherit a stale name.
]]
function Naming.Forget(instance: Instance)
	pathCache[instance] = nil
end

--[[
	Renders a value for the log, trimmed to a length a reader can scan.
]]
function Naming.Describe(value: any): string
	local ok, text = pcall(tostring, value)
	if not ok then
		return "<unreadable>"
	end
	if #text > Config.MAX_VALUE_CHARS then
		return text:sub(1, Config.MAX_VALUE_CHARS) .. "..."
	end
	return text
end

--[[
	Renders one property of an instance for the log.

	@return string -- the rendered value, or a placeholder when unreadable
]]
function Naming.DescribeProperty(instance: Instance, property: string): string
	local value = Safe.Property(instance, property)
	if value == nil then
		return "<unreadable>"
	end
	return Naming.Describe(value)
end

--[[
	Flattens text to a single line and trims it to a preview.
]]
function Naming.Preview(text: string): string
	local flattened = text:gsub("%s+", " ")
	if #flattened > Config.SCRIPT_TEXT_PREVIEW_CHARS then
		return flattened:sub(1, Config.SCRIPT_TEXT_PREVIEW_CHARS) .. "..."
	end
	return flattened
end

return Naming
