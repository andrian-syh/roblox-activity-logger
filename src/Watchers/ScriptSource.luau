--[[
	ScriptSource - Machine-written code watcher

	Reports code changing without anyone typing it, which is how the work of
	one person silently replaces another.

	- Watches every script in the place, not only the selected ones
	- Releases a script's watch when it leaves, so churn cannot exhaust the cap
	- Ignores a change while its script is being typed into
	- Folds a run of rewrites into one entry per script
	- Credits code kept in step with a file on disk to the sync tool
	- Raises an alarm when a run spans many scripts at once

	Note: the scripts most at risk are exactly the ones nobody has open.
]]

-- // VARIABLES // --
-- | Services | --
local InstanceFileSyncService = game:GetService("InstanceFileSyncService")

-- | Modules | --
local Coalescer = require(script.Parent.Parent.Coalescer)
local Config = require(script.Parent.Parent.Config)
local Editor = require(script.Parent.Editor)
local EventLog = require(script.Parent.Parent.EventLog)
local Naming = require(script.Parent.Parent.Naming)
local Safe = require(script.Parent.Parent.Safe)
local Structure = require(script.Parent.Structure)

-- | Constants | --
local SCRIPT_SYNC_LABEL = "Script Sync"

-- | State Management | --
local ScriptSource = {}

ScriptSource.Name = "ScriptSource"

local writes
local connections: { [LuaSourceContainer]: RBXScriptConnection } = {}
local watchedCount = 0
local lengths = {}
local recentWrites = {}
local alarmRaised = false
local capReported = false


-- // FUNCTIONS // --
--[[
	Raises an alarm when a run of rewrites spans many scripts at once.

	A person works through one script at a time, so a wide run is the shape of
	a tool rewriting the place rather than someone editing it.
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
	Reports whether Studio's own file sync keeps a script in step with a file
	on disk.
]]
local function syncedFromFile(container: LuaSourceContainer): boolean
	local status = Safe.Value(function()
		return InstanceFileSyncService:GetStatus(container)
	end)
	return status == Enum.InstanceFileSyncStatus.SyncedAsRoot
		or status == Enum.InstanceFileSyncStatus.SyncedAsDescendant
end

--[[
	Releases one folded run of rewrites to a single script.
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
]]
local function watch(container: LuaSourceContainer)
	if connections[container] then
		return
	end
	if watchedCount >= Config.MAX_WATCHED_SCRIPTS then
		if not capReported then
			capReported = true
			warn(string.format("%s: more than %d scripts, the rest are not watched", Config.DISPLAY_NAME, Config.MAX_WATCHED_SCRIPTS))
		end
		return
	end

	local signal = Safe.Value(function()
		return container:GetPropertyChangedSignal("Source")
	end)
	if not signal then
		return
	end

	local initial = Safe.Property(container, "Source")
	lengths[container] = typeof(initial) == "string" and #initial or 0

	watchedCount += 1
	connections[container] = signal:Connect(Safe.Handler("SourceChanged", function()
		local current = Safe.Property(container, "Source")
		local before = lengths[container] or 0
		local after = typeof(current) == "string" and #current or 0
		lengths[container] = after

		if Editor.IsBeingTyped(container) then
			return
		end

		local path = Naming.PathOf(container)
		writes:Add(path, function()
			local entry = EventLog.Stamp({
				path = path,
				className = container.ClassName,
				from = before,
				to = after,
			})
			if syncedFromFile(container) then
				entry.origin = "tool"
				entry.via = SCRIPT_SYNC_LABEL
			end
			return entry
		end, function(entry)
			entry.to = after
		end)
	end))
end

--[[
	Stops watching a script that has left the place, freeing its slot for the
	scripts that remain.
]]
local function unwatch(container: LuaSourceContainer)
	local connection = connections[container]
	if not connection then
		return
	end
	connection:Disconnect()
	connections[container] = nil
	lengths[container] = nil
	watchedCount -= 1
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

	Structure.OnInstanceRemoved(function(instance: Instance)
		if instance:IsA("LuaSourceContainer") then
			unwatch(instance)
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
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(lengths)
	watchedCount = 0
	table.clear(recentWrites)
	alarmRaised = false
end

return ScriptSource
