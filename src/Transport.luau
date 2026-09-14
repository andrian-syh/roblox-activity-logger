--[[
	Transport - Delivery queue

	Holds activity until the collector accepts it, and reports the health of
	that delivery.

	- Queues events and discards the oldest only when full
	- Delivers in batches, retrying with a widening back-off
	- Keeps one batch identity across retries so nothing is stored twice
	- Keeps undelivered work across sessions and unclean shutdowns
	- Publishes delivery health to whatever displays it
	- Resolves the published name of the place being edited

	Note: a loss that cannot be avoided is still reported, never hidden.
]]

-- // VARIABLES // --
-- | Services | --
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local StudioService = game:GetService("StudioService")

-- | Modules | --
local Config = require(script.Parent.Config)
local Safe = require(script.Parent.Safe)

-- | Types | --
export type Health = {
	Healthy: boolean,
	Reason: string,
	PendingCount: number,
	DroppedCount: number,
	LastSuccessEpoch: number,
}

-- | Constants | --
local APPS_SCRIPT_PATTERN = "script%.google%.com/macros/"
local REDIRECTED_TO_READ_ONLY = 405

-- | State Management | --
local Transport = {}

local queue = {}
local healthListeners = {}

local droppedCount = 0
local consecutiveFailures = 0
local nextAttemptClock = 0
local lastPersistClock = 0
local sending = false
local persistedAnything = false

local sessionId = HttpService:GenerateGUID(false)
local pendingBatchId = ""
local placeName = game.Name

local health: Health = {
	Healthy = true,
	Reason = "",
	PendingCount = 0,
	DroppedCount = 0,
	LastSuccessEpoch = 0,
}


-- // FUNCTIONS // --
--[[
	Tells subscribers that the health state changed.
]]
local function publishHealth()
	health.PendingCount = #queue
	health.DroppedCount = droppedCount
	for _, listener in healthListeners do
		task.spawn(function()
			Safe.Call(listener, health)
		end)
	end
end

--[[
	Records a failed delivery and schedules the next attempt further out.

	The alarm waits for a second failure, so one transient error does not
	interrupt the person working.

	@param reason string -- what went wrong, shown to the reader as written
]]
local function markFailure(reason: string)
	consecutiveFailures += 1
	local backoff = math.min(Config.RETRY_BASE_SECONDS * 2 ^ (consecutiveFailures - 1), Config.RETRY_MAX_SECONDS)
	nextAttemptClock = os.clock() + backoff

	if consecutiveFailures >= Config.FAILURES_BEFORE_ALARM then
		health.Healthy = false
		health.Reason = reason
	end

	warn(string.format("%s: delivery failed (%d): %s", Config.DISPLAY_NAME, consecutiveFailures, reason))
	publishHealth()
end

--[[
	Records a successful delivery and clears any standing alarm.
]]
local function markSuccess()
	consecutiveFailures = 0
	nextAttemptClock = 0
	health.Healthy = true
	health.Reason = ""
	health.LastSuccessEpoch = os.time()
	publishHealth()
end

--[[
	Reclaims activity left behind by a previous session.

	@param plugin Plugin -- the running plugin
]]
local function restoreQueue(plugin: Plugin)
	local stored = Safe.Value(function()
		return plugin:GetSetting(Config.SETTING_KEY_QUEUE)
	end)
	if typeof(stored) ~= "string" or stored == "" then
		return
	end

	local restored = Safe.Value(function()
		return HttpService:JSONDecode(stored)
	end)
	if typeof(restored) == "table" then
		queue = restored
	end

	Safe.Call(function()
		plugin:SetSetting(Config.SETTING_KEY_QUEUE, nil)
	end)
end

--[[
	Finds the published name of the place.

	In edit mode the data model carries a placeholder name whatever the place
	is called, so the real one has to be asked for.
]]
local function resolvePlaceName()
	if game.PlaceId == 0 then
		return
	end

	local info = Safe.Value(function()
		return MarketplaceService:GetProductInfo(game.PlaceId)
	end)
	if typeof(info) == "table" and typeof(info.Name) == "string" and info.Name ~= "" then
		placeName = info.Name
	end
end

--[[
	Sends one batch and reports whether the collector stored it.

	A spreadsheet-backed collector refuses the request after storing it, so
	that one refusal counts as delivery. Others are judged on status alone.

	@param batch {any} -- the events to deliver
	@param batchId string -- identifies this batch across retries
	@return boolean -- whether the collector stored the batch
	@return string -- the failure reason, empty on success
]]
local function deliver(batch: { any }, batchId: string): (boolean, string)
	local body = Safe.Value(function()
		return HttpService:JSONEncode({
			token = Config.SHARED_TOKEN,
			version = Config.VERSION,
			batchId = batchId,
			sessionId = sessionId,
			userId = StudioService:GetUserId(),
			placeId = game.PlaceId,
			placeName = placeName,
			sentAtEpoch = os.time(),
			events = batch,
		})
	end)
	if typeof(body) ~= "string" then
		return false, "batch could not be encoded"
	end

	local response = Safe.Value(function()
		return HttpService:RequestAsync({
			Url = Config.COLLECTOR_URL,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)

	if typeof(response) ~= "table" then
		return false, "request was rejected before it was sent"
	end
	if response.Success then
		return true, ""
	end
	-- ponytail: treat the redirect refusal as delivery for a spreadsheet
	-- collector only; drop this once the collector answers writes directly.
	if response.StatusCode == REDIRECTED_TO_READ_ONLY and Config.COLLECTOR_URL:find(APPS_SCRIPT_PATTERN) then
		return true, ""
	end
	return false, string.format("HTTP %d %s", response.StatusCode, tostring(response.StatusMessage))
end

--[[
	Queues one event for delivery.

	At capacity the oldest events are discarded and the loss is reported,
	never hidden.

	@param event {[string]: any} -- the event to deliver
]]
function Transport.Push(event: { [string]: any })
	if #queue >= Config.QUEUE_CAPACITY then
		table.remove(queue, 1)
		droppedCount += 1
		health.Healthy = false
		health.Reason = string.format("Queue penuh, %d event terbuang", droppedCount)
	end
	table.insert(queue, event)
	publishHealth()
end

--[[
	Attempts to deliver what is queued.

	Safe to call on a timer: overlapping calls and back-off windows are
	handled here.

	@param force boolean? -- attempt even inside the back-off window
]]
function Transport.Flush(force: boolean?)
	if sending or #queue == 0 then
		return
	end
	if not force and os.clock() < nextAttemptClock then
		return
	end

	sending = true

	local batchSize = math.min(#queue, Config.BATCH_LIMIT)
	local batch = table.move(queue, 1, batchSize, 1, {})
	queue = table.move(queue, batchSize + 1, #queue, 1, {})

	if pendingBatchId == "" then
		pendingBatchId = HttpService:GenerateGUID(false)
	end

	local success, reason = deliver(batch, pendingBatchId)
	if success then
		pendingBatchId = ""
		markSuccess()
	else
		local arrivedDuringSend = queue
		queue = batch
		table.move(arrivedDuringSend, 1, #arrivedDuringSend, #queue + 1, queue)
		markFailure(reason)
	end

	sending = false
end

--[[
	Reports the current delivery health.

	@return Health -- the live health state
]]
function Transport.GetHealth(): Health
	return health
end

--[[
	Subscribes to health changes, delivering the current state at once so a
	late subscriber is never left blank.

	@param listener (Health) -> () -- called on every health change
]]
function Transport.OnHealthChanged(listener: (Health) -> ())
	table.insert(healthListeners, listener)
	task.spawn(function()
		Safe.Call(listener, health)
	end)
end

--[[
	Keeps undelivered activity where the next session can find it.

	Studio does not always get to unload a plugin cleanly, so this runs on a
	timer as well as at shutdown.

	@param plugin Plugin -- the running plugin
	@param force boolean? -- persist without waiting for the interval
]]
function Transport.Persist(plugin: Plugin, force: boolean?)
	if not force and os.clock() - lastPersistClock < Config.PERSIST_INTERVAL_SECONDS then
		return
	end
	lastPersistClock = os.clock()

	if #queue == 0 then
		if persistedAnything then
			persistedAnything = false
			Safe.Call(function()
				plugin:SetSetting(Config.SETTING_KEY_QUEUE, nil)
			end)
		end
		return
	end

	local encoded = Safe.Value(function()
		return HttpService:JSONEncode(queue)
	end)
	if typeof(encoded) ~= "string" then
		return
	end

	persistedAnything = true
	Safe.Call(function()
		plugin:SetSetting(Config.SETTING_KEY_QUEUE, encoded)
	end)
end

--[[
	Prepares delivery and reclaims anything a previous session left behind.

	@param plugin Plugin -- the running plugin
]]
function Transport.Start(plugin: Plugin)
	restoreQueue(plugin)
	task.spawn(resolvePlaceName)
	publishHealth()
end

--[[
	Keeps undelivered activity as the plugin unloads.

	@param plugin Plugin -- the running plugin
]]
function Transport.Stop(plugin: Plugin)
	Transport.Persist(plugin, true)
end

return Transport
