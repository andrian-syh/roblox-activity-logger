--[[
	Coalescer - Burst folding

	Folds a run of repeated changes into one entry per subject, released once
	that subject goes quiet.

	- Starts an entry for a subject or extends the one already held
	- Extends a held entry cheaply, for changes that repeat every frame
	- Releases entries that have been quiet long enough
	- Releases one named subject immediately
	- Discards everything held without releasing it
]]

-- // VARIABLES // --
-- | Modules | --
local Safe = require(script.Parent.Safe)

-- | Types | --
export type Entry = { [string]: any }

export type Coalescer = {
	Add: (self: Coalescer, key: string, create: () -> Entry, update: (Entry) -> ()) -> (),
	Touch: (self: Coalescer, key: string, update: (Entry) -> ()) -> boolean,
	Drain: (self: Coalescer, force: boolean?) -> (),
	Release: (self: Coalescer, key: string) -> (),
	Clear: (self: Coalescer) -> (),
}

-- | State Management | --
local Coalescer = {}
Coalescer.__index = Coalescer


-- // FUNCTIONS // --
--[[
	Creates a coalescer that releases entries through the given callback.

	@param window number -- seconds of quiet before an entry is released
	@param release (Entry) -> () -- receives each released entry
]]
function Coalescer.new(window: number, release: (Entry) -> ()): Coalescer
	return setmetatable({
		_window = window,
		_release = release,
		_entries = {},
	}, Coalescer) :: any
end

--[[
	Records one change against a subject, starting a new entry or extending the
	one already held for it.

	@param key string -- identifies the subject across the burst
	@param create () -> Entry -- builds the entry when the burst begins
	@param update (Entry) -> () -- folds a later change into the held entry
]]
function Coalescer:Add(key: string, create: () -> Entry, update: (Entry) -> ())
	local held = self._entries[key]
	if held then
		Safe.Call(update, held)
		held._clock = os.clock()
		return
	end

	local entry = Safe.Value(create)
	if not entry then
		return
	end

	entry._clock = os.clock()
	self._entries[key] = entry
end

--[[
	Extends the entry already held for a subject, without building anything
	when none is held.

	@param key string -- identifies the subject across the burst
	@param update (Entry) -> () -- folds this change into the held entry
	@return boolean -- whether an entry was held and extended
]]
function Coalescer:Touch(key: string, update: (Entry) -> ()): boolean
	local held = self._entries[key]
	if not held then
		return false
	end
	Safe.Call(update, held)
	held._clock = os.clock()
	return true
end

--[[
	Releases every entry whose subject has gone quiet.

	@param force boolean? -- release every held entry regardless of quiet time
]]
function Coalescer:Drain(force: boolean?)
	local now = os.clock()
	for key, entry in self._entries do
		if force or now - entry._clock >= self._window then
			self._entries[key] = nil
			Safe.Call(self._release, entry)
		end
	end
end

--[[
	Releases one subject's entry now, if it is holding one.
]]
function Coalescer:Release(key: string)
	local entry = self._entries[key]
	if not entry then
		return
	end
	self._entries[key] = nil
	Safe.Call(self._release, entry)
end

--[[
	Discards every held entry without releasing it.
]]
function Coalescer:Clear()
	table.clear(self._entries)
end

return Coalescer
