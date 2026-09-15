--[[
	Announcement - Supervisor announcement card

	Shows the line the supervisor wants every machine to see, and says so
	plainly when there is none.

	- Builds the card
	- Shows the announcement, or a faint note that there is none
]]

-- // VARIABLES // --
-- | Modules | --
local Theme = require(script.Parent.Parent.Theme)

-- | Types | --
type State = { [string]: any }

-- | Constants | --
local EMPTY_NOTE = "No announcements right now."

-- | State Management | --
local Announcement = {}

Announcement.Slot = "stack"

local caption: TextLabel
local body: TextLabel


-- // FUNCTIONS // --
--[[
	Builds the card.
]]
function Announcement.Build(parent: Instance, order: number)
	local card = Theme.Card(parent, order)
	caption = Theme.Text(card, "meta", 1)
	caption.Text = "Announcement"
	body = Theme.Text(card, "body", 2)
end

--[[
	Paints the card from the current state.
]]
function Announcement.Update(state: State)
	local empty = state.Announcement == ""
	body.Text = if empty then EMPTY_NOTE else state.Announcement
	Theme.Hint(body, empty)
	Theme.Mark(caption, "Announcement", if empty then nil else "notice")
end

return Announcement
