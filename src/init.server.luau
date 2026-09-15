--[[
	StudioActivityLogger - Studio edit activity recorder

	Records what the person at this machine does while editing, and delivers
	it to the team collector.

	- Stays idle inside playtest sessions, whose changes are thrown away
	- Builds the status panel before anything that can fail
	- Refuses to run on a placeholder or insecure collector address
	- Settles the collector address before anything is checked against it
	- Marks the start and the end of the session
	- Follows the supervisor in holding and releasing delivery
	- Starts every watcher and reports when none survives
	- Releases folded activity often, delivers it on a slower cadence
	- Releases everything held when Studio unloads the plugin

	Note: a logger nobody knows has stopped is the same as no logger, so every
	fault opens the panel and names itself.
]]

-- // VARIABLES // --
-- | Services | --
local RunService = game:GetService("RunService")

-- | Modules | --
local Config = require(script.Config)
local Deployment = require(script.Deployment)
local EventLog = require(script.EventLog)
local StatusUi = require(script.StatusUi)
local Transport = require(script.Transport)
local Watchers = require(script.Watchers)

-- | Constants | --
--[[
	A session boundary is the plugin reporting itself, so no verdict about who
	made a change applies to it.
]]
local SESSION_DETAIL = { confidence = "", origin = "", via = "" }

-- | Objects | --
local plugin: Plugin = plugin

-- | State Management | --
local running = true
local deliveryHeld = false


-- // FUNCTIONS // --
--[[
	Reports what stops the plugin from running, if anything does.

	@return string? -- the reason, or nil when the plugin can run
]]
local function configurationFault(): string?
	if Config.COLLECTOR_URL == "" or Config.COLLECTOR_URL:find("PASTE_") then
		return "Plugin belum dikonfigurasi. COLLECTOR_URL masih placeholder, tidak ada aktivitas yang terekam."
	end
	if Config.SHARED_TOKEN == "" or Config.SHARED_TOKEN:find("PASTE_") then
		return "Plugin belum dikonfigurasi. SHARED_TOKEN masih placeholder, collector akan menolak semua kiriman."
	end
	if not Config.COLLECTOR_URL:match("^https://") then
		return "COLLECTOR_URL harus memakai https. Pengiriman dibatalkan."
	end
	return nil
end

--[[
	Follows whatever the supervisor has set since the last reading. A hold and
	its release are both recorded, so the gap in the sheet has two ends, and the
	panel is repainted whenever what it shows has moved.
]]
local function followSupervisor()
	local changed = Deployment.Refresh()

	local held = Deployment.IsPaused()
	if held ~= deliveryHeld then
		deliveryHeld = held
		EventLog.Write(if held then "loggingPaused" else "loggingResumed", Config.VERSION, SESSION_DETAIL)
		Transport.SetPaused(held)
	end

	if changed then
		StatusUi.Render(Transport.GetHealth())
	end
end

--[[
	Releases folded activity and delivers it for as long as the plugin runs.
	The release turn comes far more often than delivery, since one cadence for
	both would widen every folding window to the delivery interval.
]]
local function runMaintenanceLoop()
	local lastFlushClock = 0

	while running do
		task.wait(Config.TICK_INTERVAL_SECONDS)
		if not running then
			break
		end

		Watchers.Tick()
		followSupervisor()

		if os.clock() - lastFlushClock >= Config.FLUSH_INTERVAL_SECONDS then
			lastFlushClock = os.clock()
			Transport.Flush()
		end

		Transport.Persist(plugin)
	end
end


-- // INITIALIZATION // --
if not RunService:IsEdit() then
	return
end

StatusUi.Build(plugin)
Deployment.Resolve(plugin)

local fault = configurationFault()
if fault then
	StatusUi.ShowFatal(fault)
	warn(string.format("%s: %s", Config.DISPLAY_NAME, fault))
	return
end

Transport.Start(plugin)
Transport.OnHealthChanged(StatusUi.Render)

EventLog.Write("sessionStart", Config.VERSION, SESSION_DETAIL)

local watcherCount = Watchers.Start()
if watcherCount == 0 then
	StatusUi.ShowFatal("Tidak ada watcher yang berhasil dijalankan. Aktivitas tidak terekam sama sekali.")
	warn(string.format("%s: no watcher started", Config.DISPLAY_NAME))
	return
end

task.spawn(runMaintenanceLoop)
task.spawn(function()
	followSupervisor()
	Transport.Flush(true)
end)

plugin.Unloading:Connect(function()
	running = false
	EventLog.Write("sessionEnd", Config.VERSION, SESSION_DETAIL)
	Watchers.Stop()
	Transport.Persist(plugin, true)
	Transport.Flush(true)
	Transport.Stop(plugin)
end)
