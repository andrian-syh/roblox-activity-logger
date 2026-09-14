--[[
	ScriptSource - Machine-written code watcher

	Reports code changing without anyone typing it, which is how the work of
	one person silently replaces another.

	- Watches every script in the place, not only the selected ones
	- Ignores a change while its script is being typed into
	- Folds a run of rewrites into one entry per script
	- Raises an alarm when a run spans many scripts at once

	Note: the scripts most at risk are exactly the ones nobody has open.
]]

-- // VARIABLES // --
-- | Modules | --
local Authorship = require(script.Parent.Parent.Authorship)
local Bin = require(script.Parent.Parent.Bin)
local Coalescer = require(script.Parent.Parent.Coalescer)
local Config = require(script.Parent.Parent.Config)
local Editor = require(script.Parent.Editor)
local EventLog = require(script.Parent.Parent.EventLog)
local Naming = require(script.Parent.Parent.Naming)
local Safe = require(script.Parent.Parent.Safe)
local Structure = require(script.Parent.Structure)

-- | State Management | --
local ScriptSource = {}

ScriptSource.Name = "ScriptSource"

local bin = Bin.new()
local writes
local watched = setmetatable({}, { __mode = "k" })
local lengths = setmetatable({}, { __mode = "k" })
local recentWrites = {}
local alarmRaised = false


-- // FUNCTIONS // --
--[[
	Raises an alarm when a run of rewrites spans many scripts at once.

	A person works through one script at a time, so a wide run is the shape of
	a tool rewriting the place rather than someone editing it.

	@param path string -- the script just rewritten
]]
local function checkForBulkRun(path: string)
	local now = os.clock()
	for index = #recentWrites, 1, -1 do
		if now - recentWrites[index].clock > Config.BULK_WINDOW_SECONDS then
			table.remove(recentWrites, index)
		end
	end

	table.insert(recentWrites, { clock = now, path = path })

	local seen = {}
	local paths = {}
	for _, write in recentWrites do
		if not seen[write.path] then
			seen[write.path] = true
			table.insert(paths, write.path)
		end
	end

	if #paths < Config.BULK_SCRIPT_THRESHOLD then
		if #paths <= 1 then
			alarmRaised = false
		end
		return
	end

	if alarmRaised then
		return
	end

	alarmRaised = true
	EventLog.Write("bulkScriptWrite", table.concat(paths, ", "):sub(1, Config.MAX_TARGET_CHARS), { amount = #paths })
end

--[[
	Releases one folded run of rewrites to a single script.

	@param entry {[string]: any} -- the folded run
]]
local function release(entry: { [string]: any })
	EventLog.WriteFolded("scriptSource", entry.path, entry, {
		className = entry.className,
		oldValue = string.format("%d chars", entry.from),
		newValue = string.format("%d chars", entry.to),
		amount = entry.to - entry.from,
	})
	checkForBulkRun(entry.path)
end

--[[
	Begins watching one script for code it did not receive by hand.

	@param container LuaSourceContainer -- the script to watch
]]
local function watch(container: LuaSourceContainer)
	if watched[container] or bin:Count() >= Config.MAX_WATCHED_SCRIPTS then
		return
	end
	watched[container] = true

	local initial = Safe.Property(container, "Source")
	lengths[container] = typeof(initial) == "string" and #initial or 0

	local signal = Safe.Value(function()
		return container:GetPropertyChangedSignal("Source")
	end)
	if not signal then
		return
	end

	bin:Add(signal:Connect(Safe.Handler("SourceChanged", function()
		local current = Safe.Property(container, "Source")
		local before = lengths[container] or 0
		local after = typeof(current) == "string" and #current or 0
		lengths[container] = after

		if Editor.IsBeingTyped(container) then
			return
		end

		local path = Naming.PathOf(container)
		writes:Add(path, function()
			return {
				path = path,
				className = container.ClassName,
				from = before,
				to = after,
				via = EventLog.Transaction(),
				confidence = Authorship.Verdict(),
			}
		end, function(entry)
			entry.to = after
		end)
	end)))
end

--[[
	Begins reporting code rewritten without typing.
]]
function ScriptSource.Start()
	writes = Coalescer.new(Config.SOURCE_COALESCE_SECONDS, release)

	Structure.OnInstanceAdded(function(instance: Instance)
		if instance:IsA("LuaSourceContainer") then
			watch(instance)
		end
	end)

	for _, root in Structure.Roots() do
		local descendants = Safe.Value(function()
			return root:GetDescendants()
		end)
		if typeof(descendants) ~= "table" then
			continue
		end
		for _, descendant in descendants do
			if descendant:IsA("LuaSourceContainer") then
				watch(descendant)
			end
		end
	end
end

--[[
	Releases rewrite runs that have gone quiet.
]]
function ScriptSource.Tick()
	writes:Drain()
end

--[[
	Stops reporting and releases everything still folded.
]]
function ScriptSource.Stop()
	if writes then
		writes:Drain(true)
	end
	bin:Clear()
	table.clear(recentWrites)
	alarmRaised = false
end

return ScriptSource
