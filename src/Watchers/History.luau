--[[
	History - Change transaction watcher

	Reports the change transactions Studio records for itself, plus undo and
	redo.

	- Reports each committed transaction in Studio own wording
	- Reports undo and redo by the operation they name
	- Names the transaction in progress for other watchers to use
	- Proves local authorship, since a transaction is never replicated

	Note: the wording Studio gives an edit is the most readable account of it
	available anywhere.
]]

-- // VARIABLES // --
-- | Services | --
local ChangeHistoryService = game:GetService("ChangeHistoryService")

-- | Modules | --
local Authorship = require(script.Parent.Parent.Authorship)
local Bin = require(script.Parent.Parent.Bin)
local EventLog = require(script.Parent.Parent.EventLog)
local Safe = require(script.Parent.Parent.Safe)

-- | State Management | --
local History = {}

History.Name = "History"

local bin = Bin.new()
local depth = 0

--[[
	Begins reporting transactions, undo and redo.
]]
function History.Start()
	bin:Add(ChangeHistoryService.OnRecordingStarted:Connect(Safe.Handler("OnRecordingStarted", function(name: string)
		depth += 1
		EventLog.SetTransaction(name)
	end)))

	bin:Add(ChangeHistoryService.OnRecordingFinished:Connect(
		Safe.Handler("OnRecordingFinished", function(name: string, _displayName, _identifier, operation)
			EventLog.Write("action", name, { operation = typeof(operation) == "EnumItem" and operation.Name or "" })
			depth = math.max(depth - 1, 0)
			if depth == 0 then
				EventLog.SetTransaction("")
			end
			Authorship.Prove()
		end)
	))

	bin:Add(ChangeHistoryService.OnUndo:Connect(Safe.Handler("OnUndo", function(waypoint: string)
		EventLog.Write("undo", waypoint)
		Authorship.Prove()
	end)))

	bin:Add(ChangeHistoryService.OnRedo:Connect(Safe.Handler("OnRedo", function(waypoint: string)
		EventLog.Write("redo", waypoint)
		Authorship.Prove()
	end)))
end

--[[
	Stops reporting transactions.
]]
function History.Stop()
	bin:Clear()
	depth = 0
	EventLog.SetTransaction("")
end

return History
