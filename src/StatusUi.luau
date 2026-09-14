--[[
	StatusUi - Delivery status panel

	Shows whether activity is reaching the collector, and opens itself when it
	is not.

	- Builds the docked panel and its toolbar button
	- Paints the panel from the current delivery health
	- Shows a fault that stops the plugin running at all

	Note: the panel forces itself open on trouble, because a silent logger
	looks exactly like a working one.
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Config)

-- | Constants | --
local HEALTHY_BACKGROUND = Color3.fromRGB(30, 62, 38)
local HEALTHY_TEXT = Color3.fromRGB(196, 240, 206)
local BROKEN_BACKGROUND = Color3.fromRGB(120, 26, 26)
local BROKEN_TEXT = Color3.fromRGB(255, 226, 226)

-- | State Management | --
local StatusUi = {}

local widget
local frame
local label
local button


-- // FUNCTIONS // --
--[[
	Paints the panel in its broken colours.

	@param text string -- the message to show
]]
local function paintBroken(text: string)
	frame.BackgroundColor3 = BROKEN_BACKGROUND
	label.TextColor3 = BROKEN_TEXT
	label.Text = text
	widget.Enabled = true
end

--[[
	Builds the status panel and its toolbar button.

	@param plugin Plugin -- the running plugin
]]
function StatusUi.Build(plugin: Plugin)
	widget = plugin:CreateDockWidgetPluginGuiAsync(
		Config.WIDGET_ID,
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Bottom, false, false, 420, 96, 280, 72)
	)
	widget.Name = Config.WIDGET_ID
	widget.Title = Config.DISPLAY_NAME

	frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BorderSizePixel = 0
	frame.Parent = widget

	label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -16, 1, -16)
	label.Position = UDim2.fromOffset(8, 8)
	label.BackgroundTransparency = 1
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Font = Enum.Font.SourceSansBold
	label.TextSize = 15
	label.Parent = frame

	local toolbar = plugin:CreateToolbar(Config.DISPLAY_NAME)
	button = toolbar:CreateButton(
		"Status",
		"Show logger delivery status",
		"rbxasset://textures/ui/GuiImagePlaceholder.png"
	)
	button.ClickableWhenViewportHidden = true

	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)

	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end)
end

--[[
	Shows that the plugin cannot run at all, and why.

	@param reason string -- what stops it, in the reader's own language
]]
function StatusUi.ShowFatal(reason: string)
	paintBroken(reason)
end

--[[
	Repaints the panel from the current delivery health.

	@param health {[string]: any} -- the transport health state
]]
function StatusUi.Render(health: { [string]: any })
	if health.Healthy then
		frame.BackgroundColor3 = HEALTHY_BACKGROUND
		label.TextColor3 = HEALTHY_TEXT
		label.Text = string.format(
			"Logger aktif. Antrean %d event. Pengiriman terakhir berhasil %s.",
			health.PendingCount,
			health.LastSuccessEpoch > 0 and os.date("%H:%M:%S", health.LastSuccessEpoch) or "belum ada"
		)
	else
		paintBroken(string.format(
			"AKTIVITAS TIDAK TEREKAM.\n%s\nAntrean %d event, %d terbuang. "
				.. "Beri izin HTTP di Plugin Management, lalu hubungi PM jika tetap merah.",
			health.Reason,
			health.PendingCount,
			health.DroppedCount
		))
	end

	button:SetActive(widget.Enabled)
end

return StatusUi
