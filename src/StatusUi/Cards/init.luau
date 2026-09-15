--[[
	Cards - Panel card registry

	Lists every tile and card shown beside the activity feed, in the order they
	appear.

	- Names every tile and card the panel shows
	- Describes the state each one is painted from

	Note: to show something new, write a module beside this one exposing Slot,
	Build and optionally Update, then list it below. A tile sits in the grid, a
	stack card spans the full width below it.
]]

-- // VARIABLES // --
-- | Modules | --
local Transport = require(script.Parent.Parent.Transport)

-- | Types | --
export type State = {
	Health: Transport.Health,
	Fatal: string?,
	Paused: boolean,
	Announcement: string,
	Outdated: boolean,
	RequiredVersion: string,
}

export type Card = {
	Slot: string,
	Build: (parent: Instance, order: number, plugin: Plugin) -> (),
	Update: ((state: State) -> ())?,
}

-- | Configuration | --
local CARDS: { Card } = {
	require(script.Status),
	require(script.Version),
	require(script.LastSync),
	require(script.Queue),
	require(script.Studio),
	require(script.Problem),
	require(script.Announcement),
}

return CARDS
