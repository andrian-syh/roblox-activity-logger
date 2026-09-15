--[[
	Feed - Recent activity list

	Shows the person at this machine what has just been recorded about them, in
	short sentences, newest first, with the recording notice beneath.

	- Builds the feed card, its scrolling list and the notice
	- Describes one event as a verb and a short sentence
	- Remembers this session's events, forgetting the oldest past the limit
	- Draws only the rows in view, so a long history costs no more than a short one
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Parent.Config)
local Theme = require(script.Parent.Theme)

-- | Constants | --
local HEADER_HEIGHT = 20
local NOTICE_HEIGHT = 14
local SECTION_GAP = 4
local ROW_HEIGHT = 20
local TIME_WIDTH = 60
local VERB_WIDTH = 72
local COLUMN_GAP = 6

local NOTICE = "Studio edits here are logged for team audit."
local EMPTY_NOTE = "Nothing recorded in this session yet."

--[[
	One describer per event kind, answering the verb and the sentence shown for
	it. A kind not listed here is shown by its raw name.
]]
local DESCRIBERS: { [string]: (event: { [string]: any }, leaf: string) -> (string, string) } = {
	added = function(event, leaf)
		if event.operation == "burst" then
			return "Create", string.format('%d more instances, from "%s"', event.amount or 0, leaf)
		end
		return "Create", string.format('%s "%s"', event.className or "Instance", leaf)
	end,
	removed = function(event, leaf)
		if event.operation == "burst" then
			return "Delete", string.format('%d more instances, from "%s"', event.amount or 0, leaf)
		end
		return "Delete", string.format('%s "%s"', event.className or "Instance", leaf)
	end,
	restored = function(event, leaf)
		return "Restore", string.format('%s "%s"', event.className or "Instance", leaf)
	end,
	moved = function(event, leaf)
		return "Move", string.format('"%s" to %s', leaf, event.newValue or "?")
	end,
	property = function(event, leaf)
		return "Change", string.format('%s on "%s"', event.property or "property", leaf)
	end,
	attribute = function(event, leaf)
		return "Attribute", string.format('%s on "%s"', event.property or "attribute", leaf)
	end,
	selection = function(event, leaf)
		local amount = event.amount or 0
		if amount == 0 then
			return "Select", "Selection cleared"
		end
		return "Select", if amount == 1 then string.format('"%s"', leaf) else string.format("%d instances", amount)
	end,
	scriptEdit = function(event, leaf)
		return "Type", string.format('%d characters in "%s"', math.abs(event.amount or 0), leaf)
	end,
	scriptSource = function(_, leaf)
		return "Code", string.format('"%s" rewritten without typing', leaf)
	end,
	bulkScriptWrite = function(event)
		return "Warning", string.format("%d scripts rewritten at once", event.amount or 0)
	end,
	scriptOpen = function(_, leaf)
		return "Open", string.format('"%s"', leaf)
	end,
	scriptClose = function(_, leaf)
		return "Close", string.format('"%s"', leaf)
	end,
	action = function(event)
		return "Action", tostring(event.target)
	end,
	undo = function(event)
		return "Undo", tostring(event.target)
	end,
	redo = function(event)
		return "Redo", tostring(event.target)
	end,
	collaboratorJoined = function(event)
		return "Joined", string.format("%s started editing", tostring(event.target))
	end,
	collaboratorLeft = function(event)
		return "Left", string.format("%s stopped editing", tostring(event.target))
	end,
	sessionStart = function()
		return "Session", "Place opened"
	end,
	sessionEnd = function()
		return "Session", "Place closed"
	end,
	loggingPaused = function()
		return "Paused", "Delivery paused by supervisor, still recording"
	end,
	loggingResumed = function()
		return "Resumed", "Delivery resumed"
	end,
}

-- | State Management | --
local Feed = {}

local list: ScrollingFrame
local emptyLabel: TextLabel

local rows = {}
local entries = {}
local newest = 0
local count = 0
local dirty = false


-- // FUNCTIONS // --
--[[
	Returns the last segment of an instance path, which is what a person
	recognises the instance by.
]]
local function leafOf(path: any): string
	local text = tostring(path or "")
	return text:match("([^%.]+)$") or text
end

--[[
	Returns a remembered event by how recent it is.

	@param recency number -- one for the newest
]]
local function entryAt(recency: number): { [string]: string }?
	if recency < 1 or recency > count then
		return nil
	end
	return entries[(newest - recency) % Config.FEED_LENGTH + 1]
end

--[[
	Builds one text cell of a row.
]]
local function buildCell(row: Frame, style: string, x: number, width: UDim): TextLabel
	local label = Theme.Text(row, style, 1)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.Position = UDim2.fromOffset(x, 0)
	label.Size = UDim2.new(width, UDim.new(1, 0))
	label.TextWrapped = false
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	return label
end

--[[
	Builds one reusable row.
]]
local function buildRow()
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.Visible = false
	row.Parent = list

	local textOffset = TIME_WIDTH + VERB_WIDTH + COLUMN_GAP * 2

	local time = buildCell(row, "meta", 0, UDim.new(0, TIME_WIDTH))
	time.Font = Enum.Font.Code

	local verb = buildCell(row, "title", TIME_WIDTH + COLUMN_GAP, UDim.new(0, VERB_WIDTH))
	verb.TextSize = 14

	table.insert(rows, {
		frame = row,
		time = time,
		verb = verb,
		text = buildCell(row, "body", textOffset, UDim.new(1, -textOffset)),
	})
end

--[[
	Draws the rows in view, building more when the list has grown taller than
	the rows already built.
]]
local function draw()
	dirty = false

	list.CanvasSize = UDim2.fromOffset(0, count * ROW_HEIGHT)
	emptyLabel.Visible = count == 0

	local needed = math.ceil(list.AbsoluteSize.Y / ROW_HEIGHT) + 1
	while #rows < needed do
		buildRow()
	end

	local firstRecency = math.floor(list.CanvasPosition.Y / ROW_HEIGHT) + 1

	for offset, row in rows do
		local recency = firstRecency + offset - 1
		local entry = entryAt(recency)
		row.frame.Visible = entry ~= nil
		if entry then
			row.frame.Position = UDim2.fromOffset(0, (recency - 1) * ROW_HEIGHT)
			row.time.Text = entry.time
			row.verb.Text = entry.verb
			row.text.Text = entry.text
		end
	end
end

--[[
	Builds the feed card. Its size is left to whoever arranges the panel.

	@return Frame -- the card holding the feed
]]
function Feed.Build(parent: Instance, order: number): Frame
	local card = Theme.Card(parent, order)
	card.AutomaticSize = Enum.AutomaticSize.None

	local header = Theme.Text(card, "title", 1)
	header.AutomaticSize = Enum.AutomaticSize.None
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.Text = "Activity on this machine"

	list = Instance.new("ScrollingFrame")
	list.LayoutOrder = 2
	list.Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + NOTICE_HEIGHT + SECTION_GAP * 2))
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.CanvasSize = UDim2.new()
	Theme.Paint(list, "ScrollBarImageColor3", "DimmedText")
	list.Parent = card

	emptyLabel = Theme.Text(list, "meta", 0)
	Theme.Hint(emptyLabel, true)
	emptyLabel.Text = EMPTY_NOTE

	local notice = Theme.Text(card, "meta", 3)
	notice.AutomaticSize = Enum.AutomaticSize.None
	notice.Size = UDim2.new(1, 0, 0, NOTICE_HEIGHT)
	notice.TextSize = 12
	notice.TextWrapped = false
	notice.TextTruncate = Enum.TextTruncate.AtEnd
	notice.TextYAlignment = Enum.TextYAlignment.Bottom
	notice.Text = NOTICE
	Theme.Italic(notice)

	list:GetPropertyChangedSignal("CanvasPosition"):Connect(draw)
	list:GetPropertyChangedSignal("AbsoluteSize"):Connect(draw)

	return card
end

--[[
	Remembers one recorded event for the feed.

	@param event {[string]: any} -- the event as it was recorded
]]
function Feed.Record(event: { [string]: any })
	local describe = DESCRIBERS[event.kind]
	local verb, text
	if describe then
		verb, text = describe(event, leafOf(event.target))
	else
		verb, text = tostring(event.kind), tostring(event.target or "")
	end

	newest = newest % Config.FEED_LENGTH + 1
	entries[newest] = {
		time = os.date("%H:%M:%S", event.epoch or os.time()),
		verb = verb,
		text = text,
	}
	count = math.min(count + 1, Config.FEED_LENGTH)

	dirty = true
end

--[[
	Redraws the list when something new has arrived since the last redraw.
]]
function Feed.Tick()
	if dirty then
		draw()
	end
end

return Feed
