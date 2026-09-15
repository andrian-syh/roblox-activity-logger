--[[
	Editor - Script editor watcher

	Reports code written by hand, and tells the rest of the plugin which
	scripts a person has open.

	- Reports a script opening and closing in the editor
	- Folds typing into one entry per script, with line range and preview
	- Releases the entry for a script as soon as its document closes
	- Remembers each document's script, since a closed document can no longer say
	- Reports whether a script is being typed into right now

	Note: the editor is the only place a person types code, so everything it
	reports is human authorship.
]]

-- // VARIABLES // --
-- | Services | --
local ScriptEditorService = game:GetService("ScriptEditorService")

-- | Modules | --
local Authorship = require(script.Parent.Parent.Authorship)
local Bin = require(script.Parent.Parent.Bin)
local Coalescer = require(script.Parent.Parent.Coalescer)
local Config = require(script.Parent.Parent.Config)
local EventLog = require(script.Parent.Parent.EventLog)
local Naming = require(script.Parent.Parent.Naming)
local Safe = require(script.Parent.Parent.Safe)

-- | State Management | --
local Editor = {}

Editor.Name = "Editor"

local bin = Bin.new()
local edits
local openScripts = setmetatable({}, { __mode = "k" })
local documentScripts = setmetatable({}, { __mode = "k" })
local lastTypedClock = setmetatable({}, { __mode = "k" })


-- // FUNCTIONS // --
--[[
	Releases one folded run of typing in a single script.

	@param entry {[string]: any} -- the folded run
]]
local function release(entry: { [string]: any })
	EventLog.WriteFolded("scriptEdit", entry.path, entry, {
		className = entry.className,
		amount = entry.characters,
		location = entry.firstLine < math.huge
				and string.format("lines %d-%d", entry.firstLine, entry.lastLine)
			or "",
		preview = entry.preview,
	})
end

--[[
	Folds one reported edit into the run in progress for its script.

	@param container LuaSourceContainer -- the script being typed into
	@param changes any -- the edit ranges the editor reported
]]
local function note(container: LuaSourceContainer, changes: any)
	local path = Naming.PathOf(container)

	edits:Add(path, function()
		return {
			path = path,
			className = container.ClassName,
			characters = 0,
			firstLine = math.huge,
			lastLine = 0,
			preview = "",
			confidence = "authored",
			origin = "user",
			via = "",
		}
	end, function(entry)
		if typeof(changes) ~= "table" then
			return
		end

		for _, change in changes do
			if typeof(change) ~= "table" then
				continue
			end

			local text = typeof(change.text) == "string" and change.text or ""
			entry.characters += #text

			if entry.preview == "" and text:gsub("%s", "") ~= "" then
				entry.preview = Naming.Preview(text)
			end

			local range = change.range
			if typeof(range) == "table" and typeof(range.start) == "table" then
				local startLine = tonumber(range.start.line) or math.huge
				local endLine = tonumber(range["end"] and range["end"].line) or startLine
				entry.firstLine = math.min(entry.firstLine, startLine)
				entry.lastLine = math.max(entry.lastLine, endLine)
			end
		end
	end)
end

--[[
	Releases the run in progress for one script immediately.

	@param container LuaSourceContainer -- the script to release
]]
local function flushScript(container: LuaSourceContainer)
	edits:Release(Naming.PathOf(container))
end

--[[
	Finds the script behind an open editor document, remembering it so the
	document can still be named once it has closed.

	@param document ScriptDocument -- an open document
	@return LuaSourceContainer? -- the script, or nil for the command bar
]]
local function scriptOf(document: ScriptDocument): LuaSourceContainer?
	local known = documentScripts[document]
	if known then
		return known
	end
	if document:IsCommandBar() then
		return nil
	end
	local container = document:GetScript()
	documentScripts[document] = container
	return container
end

--[[
	Reports whether a script is open and being typed into right now.

	@param container LuaSourceContainer -- the script to test
	@return boolean -- whether a person is typing into it
]]
function Editor.IsBeingTyped(container: LuaSourceContainer): boolean
	if not openScripts[container] then
		return false
	end
	local typedAt = lastTypedClock[container]
	if not typedAt then
		return false
	end
	return (os.clock() - typedAt) <= Config.EDITOR_TYPING_WINDOW_SECONDS
end

--[[
	Begins reporting editor activity.
]]
function Editor.Start()
	edits = Coalescer.new(Config.SCRIPT_EDIT_COALESCE_SECONDS, release)

	bin:Add(ScriptEditorService.TextDocumentDidOpen:Connect(Safe.Handler("TextDocumentDidOpen", function(document)
		local container = scriptOf(document)
		if not container then
			return
		end
		openScripts[container] = true
		lastTypedClock[container] = os.clock()
		EventLog.Write("scriptOpen", Naming.PathOf(container), { className = container.ClassName })
		Authorship.Prove()
	end)))

	bin:Add(
		ScriptEditorService.TextDocumentDidChange:Connect(
			Safe.Handler("TextDocumentDidChange", function(document, changes)
				local container = scriptOf(document)
				if not container then
					return
				end
				lastTypedClock[container] = os.clock()
				note(container, changes)
				Authorship.Prove()
			end)
		)
	)

	bin:Add(ScriptEditorService.TextDocumentDidClose:Connect(Safe.Handler("TextDocumentDidClose", function(document)
		local container = documentScripts[document]
		documentScripts[document] = nil
		if not container then
			return
		end
		openScripts[container] = nil
		flushScript(container)
		EventLog.Write("scriptClose", Naming.PathOf(container), { className = container.ClassName })
		Authorship.Prove()
	end)))

	local documents = Safe.Value(function()
		return ScriptEditorService:GetScriptDocuments()
	end)
	for _, document in documents or {} do
		local container = Safe.Value(scriptOf, document)
		if container then
			openScripts[container] = true
		end
	end
end

--[[
	Releases typing runs that have gone quiet.
]]
function Editor.Tick()
	edits:Drain()
end

--[[
	Stops reporting and releases everything still folded.
]]
function Editor.Stop()
	if edits then
		edits:Drain(true)
	end
	bin:Clear()
end

return Editor
