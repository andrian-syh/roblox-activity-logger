--[[
	Presence - Collaborator watcher

	Reports who else is editing the place, and tells the authorship verdict
	whether the local user is alone.

	- Reports the collaborators already editing when recording starts
	- Reports each collaborator joining and leaving
	- Keeps the authorship verdict informed of whether anyone else is present

	Note: while nobody else is editing, a change with no local activity around
	it can only have come from something running on this machine.
]]

-- // VARIABLES // --
-- | Services | --
local Players = game:GetService("Players")
local StudioService = game:GetService("StudioService")

-- | Modules | --
local Authorship = require(script.Parent.Parent.Authorship)
local Bin = require(script.Parent.Parent.Bin)
local EventLog = require(script.Parent.Parent.EventLog)
local Safe = require(script.Parent.Parent.Safe)

-- | Constants | --
local NOT_APPLICABLE = ""

-- | State Management | --
local Presence = {}

Presence.Name = "Presence"

local bin = Bin.new()
local localUserId = 0
local collaborators: { [number]: true } = {}
local collaboratorCount = 0


-- // FUNCTIONS // --
--[[
	Records one collaborator arriving.

	@param operation string -- how the arrival was noticed
]]
local function arrive(player: Player, operation: string)
	local userId = player.UserId
	if userId == localUserId or collaborators[userId] then
		return
	end

	collaborators[userId] = true
	collaboratorCount += 1
	Authorship.SetAlone(false)

	EventLog.Write("collaboratorJoined", tostring(userId), {
		amount = collaboratorCount,
		operation = operation,
		confidence = NOT_APPLICABLE,
		origin = NOT_APPLICABLE,
		via = NOT_APPLICABLE,
	})
end

--[[
	Records one collaborator leaving.
]]
local function depart(player: Player)
	local userId = player.UserId
	if not collaborators[userId] then
		return
	end

	collaborators[userId] = nil
	collaboratorCount -= 1
	Authorship.SetAlone(collaboratorCount == 0)

	EventLog.Write("collaboratorLeft", tostring(userId), {
		amount = collaboratorCount,
		confidence = NOT_APPLICABLE,
		origin = NOT_APPLICABLE,
		via = NOT_APPLICABLE,
	})
end

--[[
	Begins reporting collaborators.
]]
function Presence.Start()
	localUserId = Safe.Value(function()
		return StudioService:GetUserId()
	end) or 0

	bin:Add(Players.PlayerAdded:Connect(Safe.Handler("PlayerAdded", function(player: Player)
		arrive(player, "joined")
	end)))

	bin:Add(Players.PlayerRemoving:Connect(Safe.Handler("PlayerRemoving", depart)))

	for _, player in Players:GetPlayers() do
		arrive(player, "present")
	end
end

--[[
	Stops reporting collaborators.
]]
function Presence.Stop()
	bin:Clear()
	table.clear(collaborators)
	collaboratorCount = 0
	Authorship.SetAlone(true)
end

return Presence
