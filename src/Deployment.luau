--[[
	Deployment - Where this machine reports to, and on whose terms

	Settles the collector address this machine uses, and carries the settings
	the supervisor controls from the collector to whatever needs them.

	- Settles the address from what was installed and what was entered here
	- Records an address entered by hand, remembering what it was replacing
	- Reads the supervisor's settings again on a slow cadence
	- Reports whether delivery is being held
	- Reports the line the supervisor wants shown, and whether this build is too old
	- Names which of the two addresses is in force

	Note: an address entered by hand survives until an install changes the one
	underneath it, so a correction sticks but a reinstall is never overruled by
	something typed months earlier.
]]

-- // VARIABLES // --
-- | Services | --
local HttpService = game:GetService("HttpService")

-- | Modules | --
local Config = require(script.Parent.Config)
local Safe = require(script.Parent.Safe)

-- | Constants | --
local INSTALLED = "installed"
local ENTERED = "entered"

-- | State Management | --
local Deployment = {}

local installedUrl = Config.COLLECTOR_URL
local installedToken = Config.SHARED_TOKEN

local source = INSTALLED
local paused = false
local announcement = ""
local minVersion = ""
local lastRefreshClock = -math.huge


-- // FUNCTIONS // --
--[[
	Reads a version as numbers, so builds can be ordered without string
	comparison calling 10 smaller than 9.

	@return {number} -- one number per part, in order
]]
local function versionParts(version: string): { number }
	local parts = {}
	for part in version:gmatch("%d+") do
		table.insert(parts, tonumber(part) or 0)
	end
	return parts
end

--[[
	Reads the address entered by hand, if there is one.

	@return {[string]: any}? -- the stored entry, or nil when none was made
]]
local function readEntry(plugin: Plugin): { [string]: any }?
	local stored = Safe.Value(function()
		return plugin:GetSetting(Config.SETTING_KEY_OVERRIDE)
	end)
	if typeof(stored) ~= "string" or stored == "" then
		return nil
	end

	local entry = Safe.Value(function()
		return HttpService:JSONDecode(stored)
	end)
	return if typeof(entry) == "table" then entry else nil
end

--[[
	Discards an address entered by hand.
]]
local function forgetEntry(plugin: Plugin)
	Safe.Call(function()
		plugin:SetSetting(Config.SETTING_KEY_OVERRIDE, nil)
	end)
end

--[[
	Settles which collector address this machine uses, before anything reads
	one. An entry made against a different installed address is discarded, so
	the newer of the two always wins.
]]
function Deployment.Resolve(plugin: Plugin)
	installedUrl = Config.COLLECTOR_URL
	installedToken = Config.SHARED_TOKEN

	local entry = readEntry(plugin)
	if not entry then
		return
	end

	if entry.baseUrl ~= installedUrl or entry.baseToken ~= installedToken then
		forgetEntry(plugin)
		return
	end

	if typeof(entry.url) == "string" and entry.url ~= "" then
		Config.COLLECTOR_URL = entry.url
	end
	if typeof(entry.token) == "string" and entry.token ~= "" then
		Config.SHARED_TOKEN = entry.token
	end
	source = ENTERED
end

--[[
	Records an address entered by hand, alongside the installed one it
	replaces. It takes effect when the plugin next starts.
]]
function Deployment.Enter(plugin: Plugin, url: string, token: string)
	local encoded = Safe.Value(function()
		return HttpService:JSONEncode({
			url = url,
			token = token,
			baseUrl = installedUrl,
			baseToken = installedToken,
		})
	end)
	if typeof(encoded) ~= "string" then
		return
	end

	Safe.Call(function()
		plugin:SetSetting(Config.SETTING_KEY_OVERRIDE, encoded)
	end)
end

--[[
	Reads the supervisor's settings again, no more often than the cadence
	allows. A collector that cannot be reached leaves the last answer standing,
	so a network fault never holds delivery on its own.
]]
function Deployment.Refresh()
	if os.clock() - lastRefreshClock < Config.BOOTSTRAP_INTERVAL_SECONDS then
		return
	end
	lastRefreshClock = os.clock()

	local url = string.format(
		"%s?token=%s&bootstrap=1",
		Config.COLLECTOR_URL,
		HttpService:UrlEncode(Config.SHARED_TOKEN)
	)

	local response = Safe.Value(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if typeof(response) ~= "table" or not response.Success then
		return
	end

	local answer = Safe.Value(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if typeof(answer) ~= "table" or answer.ok == false then
		return
	end

	paused = answer.enabled == false
	announcement = if typeof(answer.announcement) == "string" then answer.announcement else ""
	minVersion = if typeof(answer.minVersion) == "string" then answer.minVersion else ""
end

--[[
	Reports whether the supervisor is holding delivery.
]]
function Deployment.IsPaused(): boolean
	return paused
end

--[[
	Reports the line the supervisor wants every machine to show.
]]
function Deployment.Announcement(): string
	return announcement
end

--[[
	Reports whether this build is older than the oldest one still accepted.
]]
function Deployment.IsOutdated(): boolean
	if minVersion == "" then
		return false
	end

	local running = versionParts(Config.VERSION)
	local required = versionParts(minVersion)

	for index = 1, math.max(#running, #required) do
		local mine = running[index] or 0
		local theirs = required[index] or 0
		if mine ~= theirs then
			return mine < theirs
		end
	end
	return false
end

--[[
	Reports the version this machine is being asked to reach.
]]
function Deployment.RequiredVersion(): string
	return minVersion
end

--[[
	Names which address is in force, so a reader can tell an installed one from
	an entered one.
]]
function Deployment.Source(): string
	return source
end

return Deployment
