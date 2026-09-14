--[[
	Structure - Instance tree watcher

	Reports instances entering and leaving the services that hold project
	content.

	- Reports an instance appearing, with its path and class
	- Reports an instance leaving, named as it was before detaching
	- Lists the watched services this place actually has
	- Announces new instances to watchers that must subscribe to them

	Note: Studio interface services are left out because they churn throwaway
	instances on every mouse gesture.
]]

-- // VARIABLES // --
-- | Modules | --
local Bin = require(script.Parent.Parent.Bin)
local Config = require(script.Parent.Parent.Config)
local EventLog = require(script.Parent.Parent.EventLog)
local Naming = require(script.Parent.Parent.Naming)
local Safe = require(script.Parent.Parent.Safe)

-- | State Management | --
local Structure = {}

Structure.Name = "Structure"

local bin = Bin.new()
local listeners = {}


-- // FUNCTIONS // --
--[[
	Announces a new instance to anything that wants to watch it.

	@param instance Instance -- the instance that appeared
]]
local function announce(instance: Instance)
	for _, listener in listeners do
		Safe.Call(listener, instance)
	end
end

--[[
	Subscribes to instances appearing anywhere in the watched services.

	@param listener (Instance) -> () -- called for each new instance
]]
function Structure.OnInstanceAdded(listener: (Instance) -> ())
	table.insert(listeners, listener)
end

--[[
	Returns every service holding project content that this place has.

	@return {Instance} -- the reachable watched services
]]
function Structure.Roots(): { Instance }
	local roots = {}
	for _, serviceName in Config.WATCHED_SERVICES do
		local service = Safe.Value(function()
			return game:GetService(serviceName :: any)
		end)
		if service then
			table.insert(roots, service)
		end
	end
	return roots
end

--[[
	Begins reporting structural change.
]]
function Structure.Start()
	for _, root in Structure.Roots() do
		bin:Add(root.DescendantAdded:Connect(Safe.Handler("DescendantAdded", function(descendant: Instance)
			EventLog.Write("added", Naming.PathOf(descendant), { className = descendant.ClassName })
			announce(descendant)
		end)))

		bin:Add(root.DescendantRemoving:Connect(Safe.Handler("DescendantRemoving", function(descendant: Instance)
			EventLog.Write("removed", Naming.RemovedPathOf(descendant), { className = descendant.ClassName })
			Naming.Forget(descendant)
		end)))
	end
end

--[[
	Stops reporting structural change.
]]
function Structure.Stop()
	bin:Clear()
	table.clear(listeners)
end

return Structure
