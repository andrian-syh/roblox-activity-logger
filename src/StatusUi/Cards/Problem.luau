--[[
	Problem - Trouble card

	Explains whatever needs the developer's attention, and takes a new collector
	address by hand when delivery is the trouble.

	- Builds the card, its two fields and a save button
	- Explains a stopped plugin, failing delivery or an outdated build
	- Offers the fields only when a new address could help
	- Hides the card when nothing is wrong
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Parent.Parent.Config)
local Deployment = require(script.Parent.Parent.Parent.Deployment)
local Theme = require(script.Parent.Parent.Theme)

-- | Types | --
type State = { [string]: any }

-- | Constants | --
local FIELD_HEIGHT = 28
local FIELD_RADIUS = UDim.new(0, 6)
local FIELD_INSET = UDim.new(0, 8)

local DELIVERY_HINT = "Allow HTTP requests for this plugin in Plugin Management. "
	.. "If it stays red, enter the latest URL and token from your supervisor below, then restart Studio."

-- | State Management | --
local Problem = {}

Problem.Slot = "stack"

local card: Frame
local title: TextLabel
local body: TextLabel
local form: Frame


-- // FUNCTIONS // --
--[[
	Builds one rounded input whose text, placeholder included, never spills
	past its edges.

	@param order number -- position inside the form
	@return TextBox -- the field the reader types into
]]
local function buildField(order: number, placeholder: string): TextBox
	local frame = Instance.new("Frame")
	frame.LayoutOrder = order
	frame.Size = UDim2.new(1, 0, 0, FIELD_HEIGHT)
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	Theme.Paint(frame, "BackgroundColor3", "MainBackground")
	Theme.Round(frame, FIELD_RADIUS)
	frame.Parent = form

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = FIELD_INSET
	padding.PaddingRight = FIELD_INSET
	padding.Parent = frame

	local box = Instance.new("TextBox")
	box.Size = UDim2.fromScale(1, 1)
	box.BackgroundTransparency = 1
	box.Font = Enum.Font.Code
	box.TextSize = 13
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextTruncate = Enum.TextTruncate.AtEnd
	box.ClearTextOnFocus = false
	box.PlaceholderText = placeholder
	box.Text = ""
	Theme.Paint(box, "TextColor3", "MainText")
	Theme.Paint(box, "PlaceholderColor3", "DimmedText")
	box.Parent = frame

	return box
end

--[[
	Builds the form that takes a collector address by hand.
]]
local function buildForm(plugin: Plugin)
	form = Instance.new("Frame")
	form.LayoutOrder = 3
	form.Size = UDim2.fromScale(1, 0)
	form.AutomaticSize = Enum.AutomaticSize.Y
	form.BackgroundTransparency = 1
	form.Parent = card

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = form

	local urlBox = buildField(1, "Collector URL ending in /exec")
	local tokenBox = buildField(2, "Shared token")

	local save = Instance.new("TextButton")
	save.LayoutOrder = 3
	save.Size = UDim2.new(1, 0, 0, FIELD_HEIGHT)
	save.BorderSizePixel = 0
	save.Font = Enum.Font.BuilderSansBold
	save.TextSize = 14
	save.Text = "Save"
	Theme.Paint(save, "BackgroundColor3", "DialogMainButton")
	Theme.Paint(save, "TextColor3", "DialogMainButtonText")
	Theme.Round(save, FIELD_RADIUS)
	save.Parent = form

	save.Activated:Connect(function()
		if urlBox.Text == "" or tokenBox.Text == "" then
			save.Text = "Both URL and token are required"
			return
		end
		Deployment.Enter(plugin, urlBox.Text, tokenBox.Text)
		save.Text = "Saved. Restart Studio to apply"
	end)
end

--[[
	Builds the card, hidden until something is wrong.
]]
function Problem.Build(parent: Instance, order: number, plugin: Plugin)
	card = Theme.Card(parent, order)
	card.Visible = false

	title = Theme.Text(card, "title", 1)
	body = Theme.Text(card, "body", 2)
	buildForm(plugin)
end

--[[
	Paints the card from the current state.
]]
function Problem.Update(state: State)
	if state.Fatal then
		Theme.Mark(title, "Plugin stopped", "broken")
		body.Text = state.Fatal
		form.Visible = true
	elseif not state.Health.Healthy then
		Theme.Mark(title, "Activity is not reaching the sheet", "broken")
		body.Text = string.format("%s\n%s", state.Health.Reason, DELIVERY_HINT)
		form.Visible = true
	elseif state.Outdated then
		Theme.Mark(title, "Plugin outdated", "warning")
		body.Text = string.format(
			"Version %s is older than the required %s. Recording continues. Run the installer again to update.",
			Config.VERSION,
			state.RequiredVersion
		)
		form.Visible = false
	else
		card.Visible = false
		return
	end

	card.Visible = true
end

return Problem
