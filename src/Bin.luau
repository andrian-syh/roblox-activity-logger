--[[
	Bin - Connection ownership

	Holds a group of connections so a watcher can release all of them at once.

	- Takes ownership of a connection and returns it for chaining
	- Reports how many connections are held
	- Releases every held connection and empties itself
]]

-- // VARIABLES // --
-- | Types | --
export type Bin = {
	Add: (self: Bin, connection: RBXScriptConnection) -> RBXScriptConnection,
	Count: (self: Bin) -> number,
	Clear: (self: Bin) -> (),
}

-- | State Management | --
local Bin = {}
Bin.__index = Bin


-- // FUNCTIONS // --
--[[
	Creates an empty bin.

	@return Bin -- a bin holding nothing
]]
function Bin.new(): Bin
	return setmetatable({ _connections = {} }, Bin) :: any
end

--[[
	Takes ownership of a connection.

	@param connection RBXScriptConnection -- the connection to own
	@return RBXScriptConnection -- the same connection, for chaining
]]
function Bin:Add(connection: RBXScriptConnection): RBXScriptConnection
	table.insert(self._connections, connection)
	return connection
end

--[[
	Reports how many connections the bin holds.

	@return number -- the number of owned connections
]]
function Bin:Count(): number
	return #self._connections
end

--[[
	Releases every connection the bin holds and empties it.
]]
function Bin:Clear()
	for _, connection in self._connections do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(self._connections)
end

return Bin
