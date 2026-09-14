--[[
	StudioActivityLogger - Studio edit activity recorder

	Records what the person at this machine does while editing, and delivers
	it to the team collector.

	- Builds the status panel before anything that can fail
	- Refuses to run on a placeholder or insecure collector address
	- Starts every watcher and reports when none survives
	- Drives the flush, fold and persist cycle on one timer
	- Releases everything held when Studio unloads the plugin

	Note: a logger nobody knows has stopped is the same as no logger, so every
	fault opens the panel and names itself.
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Config)
local StatusUi = require(script.StatusUi)
local Transport = require(script.Transport)
local Watchers = require(script.Watchers)

-- | Objects | --
local plugin: Plugin = plugin

-- | State Management | --
local running = true


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
	Delivers queued activity on a fixed cadence for as long as the plugin runs.
]]
local function runMaintenanceLoop()
	while running do
		task.wait(Config.FLUSH_INTERVAL_SECONDS)
		if not running then
			break
		end
		Watchers.Tick()
		Transport.Flush()
		Transport.Persist(plugin)
	end
end


-- // INITIALIZATION // --
StatusUi.Build(plugin)

local fault = configurationFault()
if fault then
	StatusUi.ShowFatal(fault)
	warn(string.format("%s: %s", Config.DISPLAY_NAME, fault))
	return
end

Transport.Start(plugin)
Transport.OnHealthChanged(StatusUi.Render)

local watcherCount = Watchers.Start()
if watcherCount == 0 then
	StatusUi.ShowFatal("Tidak ada watcher yang berhasil dijalankan. Aktivitas tidak terekam sama sekali.")
	warn(string.format("%s: no watcher started", Config.DISPLAY_NAME))
	return
end

task.spawn(runMaintenanceLoop)
task.spawn(function()
	Transport.Flush(true)
end)

plugin.Unloading:Connect(function()
	running = false
	Watchers.Stop()
	Transport.Flush(true)
	Transport.Stop(plugin)
end)
