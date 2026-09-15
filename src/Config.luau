--[[
	Config - Every tunable in one place

	Deployment settings and thresholds for the whole plugin, shared by every
	machine that builds from this source.

	- Names the company and the plugin as they appear in Studio
	- Lists the change recordings that identify an assistant or a tool
	- Names the collector and the token sent with each batch
	- Sets how often the supervisor's settings are read again
	- Sets delivery cadence, batch size and retry behaviour
	- Sets how long each kind of burst is folded before release
	- Caps what is watched and how much of a value is logged
	- Sets how much recent activity the panel keeps on show
	- Lists the properties read ahead of time, so a change knows its old value
	- Lists the classes the engine maintains rather than the user
	- Lists the services holding project content
	- Lists the properties the engine recomputes on its own

	Note: the token ships inside a readable plugin file, so treat it as a
	noise filter rather than authentication.
]]

-- // VARIABLES // --
-- | Configuration | --
local Config = {}

--[[
	Stamped on every batch so the collector can tell which build a machine is
	running. Raise it whenever the event shape changes.
]]
Config.VERSION = "1.4.0"

-- | Branding | --
--[[
	The company tag shown in brackets before the plugin name wherever the
	plugin names itself. Leave it empty to show the plugin name alone.
]]
Config.COMPANY_TAG = ""
Config.PRODUCT_NAME = "Studio Activity Logger"
Config.DISPLAY_NAME = if Config.COMPANY_TAG == ""
	then Config.PRODUCT_NAME
	else string.format("[%s] %s", Config.COMPANY_TAG, Config.PRODUCT_NAME)

-- | Attribution | --
--[[
	Change recordings whose name identifies who made the change. Studio's own
	recordings and any name not listed here count as the local user's work.
]]
Config.KNOWN_RECORDINGS = {
	{ prefix = "Assistant", origin = "assistant" },
	{ prefix = "Rojo:", origin = "tool" },
}

-- | Collector | --
Config.COLLECTOR_URL = "PASTE_COLLECTOR_URL_HERE"

--[[
	Shared with the collector to turn away strangers. A plugin file can be read
	by anyone who has it, so this keeps out noise, never a determined person.
]]
Config.SHARED_TOKEN = "PASTE_SHARED_TOKEN_HERE"

--[[
	How often the settings the supervisor controls are read again, and how
	often a machine whose delivery is held still reports that it is alive.
]]
Config.BOOTSTRAP_INTERVAL_SECONDS = 120
Config.PAUSED_HEARTBEAT_SECONDS = 300

-- | Delivery | --
Config.TICK_INTERVAL_SECONDS = 1
Config.FLUSH_INTERVAL_SECONDS = 15
Config.QUEUE_CAPACITY = 2000
Config.BATCH_LIMIT = 200
Config.PERSIST_INTERVAL_SECONDS = 60
Config.RETRY_BASE_SECONDS = 5
Config.RETRY_MAX_SECONDS = 120
Config.FAILURES_BEFORE_ALARM = 2

-- | Folding | --
Config.PROPERTY_COALESCE_SECONDS = 2
Config.SOURCE_COALESCE_SECONDS = 5
Config.SCRIPT_EDIT_COALESCE_SECONDS = 10
Config.EDITOR_TYPING_WINDOW_SECONDS = 5
Config.LOCAL_ACTIVITY_WINDOW_SECONDS = 3
Config.CUT_PASTE_WINDOW_SECONDS = 60
Config.DELETE_KEY_WINDOW_SECONDS = 1

-- | Limits | --
Config.MAX_WATCHED_DESCENDANTS = 200
Config.MAX_WATCHED_SCRIPTS = 3000
Config.MAX_STRUCTURE_ROWS_PER_BURST = 50
Config.MAX_VALUE_CHARS = 120
Config.MAX_TARGET_CHARS = 300
Config.SCRIPT_TEXT_PREVIEW_CHARS = 200
Config.FEED_LENGTH = 1000

-- | Alarms | --
Config.BULK_WINDOW_SECONDS = 10
Config.BULK_SCRIPT_THRESHOLD = 5

-- | Storage | --
Config.SETTING_KEY_QUEUE = "StudioActivityLogger_PendingQueue"
Config.SETTING_KEY_BATCH = "StudioActivityLogger_PendingBatchId"
Config.SETTING_KEY_OVERRIDE = "StudioActivityLogger_Override"
Config.WIDGET_ID = "StudioActivityLogger_Status"

--[[
	The services holding project content. Studio's interface services are left
	out on purpose: they churn throwaway instances on every mouse gesture.
]]
Config.WATCHED_SERVICES = {
	"Workspace",
	"Lighting",
	"ReplicatedFirst",
	"ReplicatedStorage",
	"ServerScriptService",
	"ServerStorage",
	"SoundService",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"Teams",
	"TextChatService",
}

--[[
	The properties read when an instance comes under watch, so the first change
	to one of them can report what it was before. The order is also the order of
	interest: when several change at once, the earliest one here is reported.
]]
Config.SNAPSHOT_PROPERTIES = {
	"Name",
	"Size",
	"Position",
	"Orientation",
	"CFrame",
	"Anchored",
	"CanCollide",
	"Color",
	"Material",
	"Transparency",
	"Enabled",
	"Visible",
	"Text",
	"Value",
}

--[[
	Classes Studio maintains for itself. They come and go with the session
	rather than with anyone's work, so their arrival and departure says nothing
	about who changed what.
]]
Config.IGNORED_CLASSES = {
	Camera = true,
	Terrain = true,
}

--[[
	Properties the engine recomputes rather than the user setting them.
	Reporting these would bury every real edit.
]]
Config.DERIVED_PROPERTIES = {
	AssemblyAngularVelocity = true,
	AssemblyCenterOfMass = true,
	AssemblyLinearVelocity = true,
	AssemblyMass = true,
	AssemblyRootPart = true,
	CenterOfMass = true,
	CFrame = true,
	ExtentsCFrame = true,
	ExtentsSize = true,
	Mass = true,
	ModelMeshCFrame = true,
	ModelMeshSize = true,
	ReceiveAge = true,
	ResizeableFaces = true,
	Rotation = true,
	WorldCFrame = true,
	WorldPivot = true,
	WorldPosition = true,
	WorldRotation = true,
}

return Config
