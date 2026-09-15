--[[
	Transport - Delivery queue

	Holds activity until the collector accepts it, and reports the health of
	that delivery.

	- Stamps each event with the place, session and user it happened in
	- Numbers each event within its session, so a missing one can be noticed
	- Queues events and discards the oldest only when full
	- Delivers in batches, retrying with a widening back-off
	- Holds delivery on request, while still reporting the machine as alive
	- Keeps one batch identity across retries so nothing is stored twice
	- Asks the collector whether a batch landed when the reply cannot say
	- Treats anything it cannot confirm as undelivered, and keeps it queued
	- Keeps undelivered work, and the batch it was sending, across sessions
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
local paused = false
local lastHeartbeatClock = -math.huge
local sequence = 0

local sessionId = HttpService:GenerateGUID(false)
local pendingBatchId = ""
local pendingBatchSize = 0
local sendingBatch: { any } = {}
local placeName = game.Name
local placeNameResolved = false
local userId = Safe.Value(function()
	return StudioService:GetUserId()
end) or 0

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

	local storedBatch = Safe.Value(function()
		return plugin:GetSetting(Config.SETTING_KEY_BATCH)
	end)
	local storedId, storedSize = if typeof(storedBatch) == "string" then storedBatch:match("^(.+)|(%d+)$") else nil
	local size = tonumber(storedSize)
	if storedId and size and size > 0 and size <= #queue then
		pendingBatchId = storedId
		pendingBatchSize = size
	end

	Safe.Call(function()
		plugin:SetSetting(Config.SETTING_KEY_QUEUE, nil)
		plugin:SetSetting(Config.SETTING_KEY_BATCH, nil)
	end)
end

--[[
	Finds the published name of the place.

	In edit mode the data model carries a placeholder name whatever the place
	is called, so the real one has to be asked for.
]]
local function resolvePlaceName()
	placeNameResolved = true
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
	Reads the collector's answer, when the reply carries one.

	@return {[string]: any}? -- the answer, or nil when there is none to read
]]
local function decodedAnswer(body: string?): { [string]: any }?
	if typeof(body) ~= "string" or body == "" then
		return nil
	end
	local answer = Safe.Value(function()
		return HttpService:JSONDecode(body)
	end)
	return if typeof(answer) == "table" then answer else nil
end

--[[
	Asks the collector whether it holds a batch whose reply could not be read.
	Only the collector saying so counts as delivery, and an unanswered question
	leaves the batch queued for a retry it recognises rather than stores twice.

	@param status number -- the status the write itself came back with
	@return boolean -- whether the collector holds the batch
	@return string -- the failure reason, empty on success
]]
local function confirmStored(batchId: string, status: number): (boolean, string)
	local url = string.format(
		"%s?token=%s&batchId=%s",
		Config.COLLECTOR_URL,
		HttpService:UrlEncode(Config.SHARED_TOKEN),
		HttpService:UrlEncode(batchId)
	)

	local response = Safe.Value(function()
		return HttpService:RequestAsync({ Url = url, Method = "GET" })
	end)
	if typeof(response) ~= "table" then
		return false, string.format("HTTP %d, and the check could not be sent", status)
	end
	if not response.Success then
		return false, string.format("HTTP %d, check HTTP %d", status, response.StatusCode)
	end

	local answer = decodedAnswer(response.Body)
	if not answer then
		return false, string.format("HTTP %d, and the check was unreadable", status)
	end
	if answer.ok == false then
		return false, tostring(answer.error or "collector refused the batch")
	end
	if answer.stored ~= true then
		return false, "collector does not hold the batch"
	end
	return true, ""
end

--[[
	Sends one batch and reports whether the collector stored it. A reply the
	collector controls is believed as written. An unreadable reply says nothing
	about the write behind it, so that one is settled by asking.

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
			userId = userId,
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
		local answer = decodedAnswer(response.Body)
		if answer and answer.ok == false then
			return false, tostring(answer.error or "collector refused the batch")
		end
		return true, ""
	end

	if Config.COLLECTOR_URL:find(APPS_SCRIPT_PATTERN) then
		return confirmStored(batchId, response.StatusCode)
	end

	return false, string.format("HTTP %d %s", response.StatusCode, tostring(response.StatusMessage))
end

--[[
	Reports that this machine is still here while its delivery is held, so a
	held machine is not mistaken for a machine that stopped reporting. The
	report carries no events, only the sender.
]]
local function sendHeartbeat()
	if os.clock() - lastHeartbeatClock < Config.PAUSED_HEARTBEAT_SECONDS then
		return
	end
	lastHeartbeatClock = os.clock()

	sending = true
	local success, reason = deliver({}, HttpService:GenerateGUID(false))
	sending = false

	if success then
		markSuccess()
	else
		markFailure(reason)
	end
end

--[[
	Holds delivery, or releases it. Recording is untouched either way: what is
	queued while delivery is held goes out once it resumes.
]]
function Transport.SetPaused(value: boolean)
	paused = value
end

--[[
	Queues one event, stamped with the place, session and user it happened in,
	since the queue can be delivered later from somewhere else. At capacity the
	oldest go, and the batch identity naming them goes with them.
]]
function Transport.Push(event: { [string]: any })
	sequence += 1

	event.placeId = game.PlaceId
	event.placeName = placeName
	event.sessionId = sessionId
	event.userId = userId
	event.seq = sequence

	if #queue >= Config.QUEUE_CAPACITY then
		table.remove(queue, 1)
		droppedCount += 1
		pendingBatchId = ""
		health.Healthy = false
		health.Reason = string.format("Queue full, %d events discarded", droppedCount)
	end
	table.insert(queue, event)
	publishHealth()
end

--[[
	Attempts to deliver what is queued.

	Safe to call on a timer: overlapping calls, back-off windows and a held
	delivery are all handled here.

	@param force boolean? -- attempt even inside the back-off window
]]
function Transport.Flush(force: boolean?)
	if sending then
		return
	end
	if paused then
		sendHeartbeat()
		return
	end
	if #queue == 0 then
		return
	end
	if not force and os.clock() < nextAttemptClock then
		return
	end

	sending = true

	if not placeNameResolved then
		resolvePlaceName()
	end

	if pendingBatchId ~= "" and pendingBatchSize > #queue then
		pendingBatchId = ""
	end
	if pendingBatchId == "" then
		pendingBatchId = HttpService:GenerateGUID(false)
		pendingBatchSize = math.min(#queue, Config.BATCH_LIMIT)
	end

	local batch = table.move(queue, 1, pendingBatchSize, 1, {})
	queue = table.move(queue, pendingBatchSize + 1, #queue, 1, {})
	sendingBatch = batch

	for _, event in batch do
		if event.placeId == game.PlaceId then
			event.placeName = placeName
		end
	end

	local success, reason = deliver(batch, pendingBatchId)
	sendingBatch = {}

	if success then
		pendingBatchId = ""
		pendingBatchSize = 0
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
	Keeps undelivered activity, and the batch identity it belongs to, where the
	next session can find both. A batch still on its way is kept too, without
	its identity: if it did land, the next session stores it twice rather than
	never.

	@param force boolean? -- persist without waiting for the interval
]]
function Transport.Persist(plugin: Plugin, force: boolean?)
	if not force and os.clock() - lastPersistClock < Config.PERSIST_INTERVAL_SECONDS then
		return
	end
	lastPersistClock = os.clock()

	local snapshot = queue
	if sending and #sendingBatch > 0 then
		snapshot = table.move(sendingBatch, 1, #sendingBatch, 1, {})
		table.move(queue, 1, #queue, #snapshot + 1, snapshot)
	end

	if #snapshot == 0 then
		if persistedAnything then
			persistedAnything = false
			Safe.Call(function()
				plugin:SetSetting(Config.SETTING_KEY_QUEUE, nil)
				plugin:SetSetting(Config.SETTING_KEY_BATCH, nil)
			end)
		end
		return
	end

	local encoded = Safe.Value(function()
		return HttpService:JSONEncode(snapshot)
	end)
	if typeof(encoded) ~= "string" then
		warn(string.format("%s: %d queued events could not be kept for the next session", Config.DISPLAY_NAME, #snapshot))
		return
	end

	local batchSetting = if sending or pendingBatchId == ""
		then ""
		else string.format("%s|%d", pendingBatchId, pendingBatchSize)

	persistedAnything = true
	Safe.Call(function()
		plugin:SetSetting(Config.SETTING_KEY_QUEUE, encoded)
		plugin:SetSetting(Config.SETTING_KEY_BATCH, batchSetting)
	end)
end

--[[
	Prepares delivery and reclaims anything a previous session left behind.
]]
function Transport.Start(plugin: Plugin)
	restoreQueue(plugin)
	publishHealth()
end

--[[
	Keeps undelivered activity as the plugin unloads.
]]
function Transport.Stop(plugin: Plugin)
	Transport.Persist(plugin, true)
end

return Transport
