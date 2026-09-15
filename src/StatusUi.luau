--[[
	StatusUi - Delivery status panel

	Shows whether activity is reaching the collector, and opens itself when it
	is not.

	- Builds the docked panel and its toolbar button
	- Paints the panel from the current delivery health
	- Shows a fault that stops the plugin running at all
	- Offers an address to be entered by hand whenever the panel is red

	Note: the panel forces itself open on trouble, because a silent logger
	looks exactly like a working one.
]]

-- // VARIABLES // --
-- | Modules | --
local Config = require(script.Parent.Config)
local Deployment = require(script.Parent.Deployment)

-- | Constants | --
local HEALTHY_BACKGROUND = Color3.fromRGB(30, 62, 38)
local HEALTHY_TEXT = Color3.fromRGB(196, 240, 206)
local BROKEN_BACKGROUND = Color3.fromRGB(120, 26, 26)
local BROKEN_TEXT = Color3.fromRGB(255, 226, 226)
local FIELD_BACKGROUND = Color3.fromRGB(28, 28, 28)
local FIELD_TEXT = Color3.fromRGB(235, 235, 235)

local FORM_HEIGHT = 92

-- | State Management | --
local StatusUi = {}

local owningPlugin
local widget
local frame
local label
local button
local form
local urlBox
local tokenBox


-- // FUNCTIONS // --
--[[
	Builds one labelled input inside the form.

	@param order number -- position from the top of the form
	@return TextBox -- the field the reader types into
]]
local function buildField(order: number, caption: string, placeholder: string): TextBox
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 24)
	row.Position = UDim2.fromOffset(0, (order - 1) * 28)
	row.BackgroundTransparency = 1
	row.Parent = form

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(0, 74, 1, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.SourceSans
	title.TextSize = 14
	title.TextColor3 = BROKEN_TEXT
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = caption
	title.Parent = row

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, -74, 1, 0)
	box.Position = UDim2.fromOffset(74, 0)
	box.BackgroundColor3 = FIELD_BACKGROUND
	box.BorderSizePixel = 0
	box.Font = Enum.Font.Code
	box.TextSize = 13
	box.TextColor3 = FIELD_TEXT
	box.PlaceholderText = placeholder
	box.ClearTextOnFocus = false
	box.Text = ""
	box.Parent = row

	return box
end

--[[
	Builds the form that takes a collector address by hand, kept hidden until
	something is wrong with the one already in use.
]]
local function buildForm()
	form = Instance.new("Frame")
	form.Size = UDim2.new(1, -16, 0, FORM_HEIGHT)
	form.Position = UDim2.new(0, 8, 1, -(FORM_HEIGHT + 8))
	form.BackgroundTransparency = 1
	form.Visible = false
	form.Parent = frame

	urlBox = buildField(1, "URL", "https://script.google.com/macros/.../exec")
	tokenBox = buildField(2, "Token", "token yang sama dengan collector")

	local save = Instance.new("TextButton")
	save.Size = UDim2.new(0, 150, 0, 24)
	save.Position = UDim2.fromOffset(74, 56)
	save.BackgroundColor3 = FIELD_BACKGROUND
	save.BorderSizePixel = 0
	save.Font = Enum.Font.SourceSansBold
	save.TextSize = 14
	save.TextColor3 = FIELD_TEXT
	save.Text = "Simpan lalu muat ulang"
	save.Parent = form

	save.Activated:Connect(function()
		if urlBox.Text == "" or tokenBox.Text == "" then
			return
		end
		Deployment.Enter(owningPlugin, urlBox.Text, tokenBox.Text)
		save.Text = "Tersimpan. Restart Studio"
	end)
end

--[[
	Paints the panel in its broken colours and offers the form.
]]
local function paintBroken(text: string)
	frame.BackgroundColor3 = BROKEN_BACKGROUND
	label.TextColor3 = BROKEN_TEXT
	label.Text = text
	form.Visible = true
	widget.Enabled = true
end

--[[
	Returns the supervisor's line, ready to append to whatever the panel says.
]]
local function announcementSuffix(): string
	local announcement = Deployment.Announcement()
	return if announcement == "" then "" else "\n" .. announcement
end

--[[
	Builds the status panel and its toolbar button.
]]
function StatusUi.Build(plugin: Plugin)
	owningPlugin = plugin

	widget = plugin:CreateDockWidgetPluginGuiAsync(
		Config.WIDGET_ID,
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Bottom, false, false, 460, 190, 320, 150)
	)
	widget.Name = Config.WIDGET_ID
	widget.Title = Config.DISPLAY_NAME

	frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BorderSizePixel = 0
	frame.Parent = widget

	label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -16, 1, -(FORM_HEIGHT + 24))
	label.Position = UDim2.fromOffset(8, 8)
	label.BackgroundTransparency = 1
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Font = Enum.Font.SourceSansBold
	label.TextSize = 15
	label.Parent = frame

	buildForm()

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
	Repaints the panel from the current delivery health, from what the
	supervisor has set, and from whether this build is still accepted.
]]
function StatusUi.Render(health: { [string]: any })
	if not health.Healthy then
		paintBroken(string.format(
			"AKTIVITAS TIDAK TEREKAM.\n%s\nAntrean %d event, %d terbuang. "
				.. "Beri izin HTTP di Plugin Management, lalu hubungi PM jika tetap merah.%s",
			health.Reason,
			health.PendingCount,
			health.DroppedCount,
			announcementSuffix()
		))
	elseif Deployment.IsOutdated() then
		paintBroken(string.format(
			"Versi plugin usang. Terpasang %s, minimum %s.\n"
				.. "Perekaman tetap jalan. Jalankan ulang installer untuk memperbarui.%s",
			Config.VERSION,
			Deployment.RequiredVersion(),
			announcementSuffix()
		))
	else
		frame.BackgroundColor3 = HEALTHY_BACKGROUND
		label.TextColor3 = HEALTHY_TEXT
		form.Visible = false
		label.Text = string.format(
			"Logger aktif%s. Versi %s. Antrean %d event. Pengiriman terakhir berhasil %s.%s",
			if Deployment.IsPaused() then ", pengiriman ditahan PM" else "",
			Config.VERSION,
			health.PendingCount,
			health.LastSuccessEpoch > 0 and os.date("%H:%M:%S", health.LastSuccessEpoch) or "belum ada",
			announcementSuffix()
		)
	end

	button:SetActive(widget.Enabled)
end

return StatusUi
