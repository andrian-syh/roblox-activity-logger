--[[
	Safe - Failure boundary for engine-facing work

	Runs calls that may throw without letting the failure escape, and reports
	whatever it swallows.

	- Wraps a call and reports a failure instead of propagating it
	- Wraps a call that returns a value, yielding nothing on failure
	- Wraps a signal handler so a throw cannot break the connection
	- Reads one property, yielding nothing when it is unreadable
	- Reports each distinct failure once so the output cannot flood

	Note: missing one event beats losing the whole log, which is why every
	boundary routes through here.
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Config)

-- | State Management | --
local Safe = {}

local reportedFailures = {}


-- // FUNCTIONS // --
--[[
	Reports a failure once per distinct message, so a signal that fails on
	every call cannot flood the output.

	@param context string -- names the failure in the report
]]
local function reportOnce(context: string, message: string)
	local key = context .. "|" .. message
	if reportedFailures[key] then
		return
	end
	reportedFailures[key] = true
	warn(string.format("%s: %s failed: %s", Config.DISPLAY_NAME, context, message))
end

--[[
	Calls a function and reports any failure instead of propagating it.

	@param ... any -- forwarded to the callback
	@return boolean -- whether the call completed
]]
function Safe.Call(callback: (...any) -> ...any, ...): boolean
	local ok, err = pcall(callback, ...)
	if not ok then
		reportOnce("call", tostring(err))
	end
	return ok
end

--[[
	Calls a function and returns its result, or nothing when it fails.

	@param ... any -- forwarded to the callback
	@return any -- the result, or nil when the call failed
]]
function Safe.Value(callback: (...any) -> any, ...): any
	local ok, result = pcall(callback, ...)
	if not ok then
		reportOnce("value", tostring(result))
		return nil
	end
	return result
end

--[[
	Wraps a signal handler so a failure inside it cannot break the connection.

	@param context string -- names the handler in any failure report
	@return (...any) -> () -- a handler that never throws
]]
function Safe.Handler(context: string, handler: (...any) -> ()): (...any) -> ()
	return function(...)
		local ok, err = pcall(handler, ...)
		if not ok then
			reportOnce(context, tostring(err))
		end
	end
end

--[[
	Reads one property, yielding nothing when it cannot be read.

	@return any -- the value, or nil when it is unreadable
]]
function Safe.Property(instance: Instance, property: string): any
	local ok, value = pcall(function()
		return (instance :: any)[property]
	end)
	return ok and value or nil
end

return Safe
