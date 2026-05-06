--!strict
-- @Name ServiceManager/GlassGUI.luau
-- @Author iKrypto
-- @Description Programmatic Glass Engine ScreenGui builder.
-- Creates the entire UI shell: sidebar icon rail, breadcrumb bar, body container,
-- bottom status bar, and insight notification area. No serialized GUI dependency.

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)

local GlassGUI = {}
GlassGUI.__index = GlassGUI

local function ClampWindowPosition(position: UDim2, anchorPoint: Vector2, absoluteSize: Vector2, viewport: Vector2): UDim2
	local anchorX = anchorPoint.X
	local anchorY = anchorPoint.Y
	local absoluteX = viewport.X * position.X.Scale + position.X.Offset
	local absoluteY = viewport.Y * position.Y.Scale + position.Y.Offset
	local minX = absoluteSize.X * anchorX
	local maxX = viewport.X - absoluteSize.X * (1 - anchorX)
	local minY = absoluteSize.Y * anchorY
	local maxY = viewport.Y - absoluteSize.Y * (1 - anchorY)
	local clampedX = math.clamp(absoluteX, minX, maxX)
	local clampedY = math.clamp(absoluteY, minY, maxY)
	return UDim2.new(
		position.X.Scale,
		math.floor(clampedX - viewport.X * position.X.Scale),
		position.Y.Scale,
		math.floor(clampedY - viewport.Y * position.Y.Scale)
	)
end

-- ══════════════════════════════════════════════════════════════
-- CONSTRUCTOR
-- ══════════════════════════════════════════════════════════════

--[[
	Create the GlassGUI controller around a PlayerGui.
	Stores window state, callback hooks, and lazily populated instance references
	until Build materializes the visual shell.
]]
function GlassGUI.new(playerGui: PlayerGui): any
	local self = setmetatable({}, GlassGUI)
	self._playerGui = playerGui
	self._screenGui = nil :: ScreenGui?
	self._mainFrame = nil :: Frame?
	self._sidebar = nil :: Frame?
	self._breadcrumbBar = nil :: Frame?
	self._bodyContainer = nil :: Frame?
	self._statusBar = nil :: Frame?
	self._insightToast = nil :: Frame?
	self._minimized = false
	self._dragging = false
	self._dragStart = Vector2.zero
	self._frameStart = UDim2.new()
	self._sidebarButtons = {} :: { [string]: TextButton }
	self._activeSubsystem = nil :: string?
	self._onSubsystemSelected = nil :: ((name: string) -> ())?
	self._onMinimizeToggle = nil :: ((minimized: boolean) -> ())?
	self._onClose = nil :: (() -> ())?
	self._onContextToggle = nil :: ((mode: string) -> ())?
	self._onSubsystemReselected = nil :: ((name: string) -> ())?
	self._onBackClick = nil :: (() -> ())?
	self._contextMode = "client"
	self._contextPill = nil :: TextButton?
	self._backButton = nil :: TextButton?
	self._visible = false
	return self
end

-- ══════════════════════════════════════════════════════════════
-- BUILD FULL GUI
-- ══════════════════════════════════════════════════════════════

--[[
	Create and attach the full ServiceManager ScreenGui shell.
	Builds the window chrome, sidebar, breadcrumb bar, body host, status bar, and
	insight toast, then returns the finished ScreenGui instance.
]]
function GlassGUI:Build(): ScreenGui
	-- Root ScreenGui
	local sg = Instance.new("ScreenGui")
	sg.Name = "ServiceManager"
	sg.ResetOnSpawn = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.DisplayOrder = 100
	sg.IgnoreGuiInset = false
	sg.Enabled = false
	sg.Parent = self._playerGui
	self._screenGui = sg

	-- Main floating window
	local main = Instance.new("Frame")
	main.Name = "MainWindow"
	main.Size = UDim2.new(0.85, 0, 0.85, 0)
	main.Position = UDim2.new(0.5, 0, 0.5, 0)
main.AnchorPoint = Vector2.new(0.5, 0.5)
	main.BackgroundColor3 = Theme.Colors.RootBG
	main.BackgroundTransparency = 0
	main.BorderSizePixel = 0
	main.ClipsDescendants = true
	main.Parent = sg
	self._mainFrame = main

	local mainCorner = Instance.new("UICorner")
	mainCorner.CornerRadius = UDim.new(0, Theme.Radius.Lg)
	mainCorner.Parent = main

	local mainStroke = Instance.new("UIStroke")
	mainStroke.Color = Theme.Colors.BorderPrimary
	mainStroke.Thickness = 1
	mainStroke.Transparency = 0.3
	mainStroke.Parent = main

	-- Drop shadow (outer frame behind main)
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Size = UDim2.new(1, 12, 1, 12)
	shadow.Position = UDim2.new(0, -6, 0, -6)
	shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shadow.BackgroundTransparency = 0.7
	shadow.BorderSizePixel = 0
	shadow.ZIndex = -1
	shadow.Parent = main
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, Theme.Radius.Lg + 4)
	sc.Parent = shadow

	-- Build sections
	self:_BuildTitleBar(main)
	self:_BuildSidebar(main)
	self:_BuildBreadcrumbBar(main)
	self:_BuildBodyContainer(main)
	self:_BuildStatusBar(main)
	self:_BuildInsightToast(main)
	self:_SetupDragging(main)
	self:_SetupResizing(main)

	return sg
end

-- ══════════════════════════════════════════════════════════════
-- TITLE BAR (top 32px)
-- ══════════════════════════════════════════════════════════════

function GlassGUI:_BuildTitleBar(parent: Frame)
	local bar = Instance.new("Frame")
	bar.Name = "TitleBar"
	bar.Size = UDim2.new(1, 0, 0, 32)
	bar.Position = UDim2.new(0, 0, 0, 0)
	bar.BackgroundColor3 = Theme.Colors.GlassPrimary
	bar.BackgroundTransparency = 0.3
	bar.BorderSizePixel = 0
	bar.ZIndex = 20
	bar.Parent = parent

	-- Title text
	Theme.CreateLabel({
		Text = '<font color="#3898FF">◆</font> SERVICE MANAGER',
		Size = UDim2.new(0.5, 0, 1, 0),
		Position = UDim2.new(0, 50, 0, 0),
		Color = Theme.Colors.TextPrimary,
		FontSize = Theme.TextSize.Body,
		FontFace = Theme.Font.Bold,
		Parent = bar,
	})

	-- Context pill toggle (CLIENT / SERVER)
	local pill = Instance.new("TextButton")
	pill.Name = "ContextPill"
	pill.Size = UDim2.new(0, 72, 0, 22)
	pill.Position = UDim2.new(1, -170, 0, 5)
	pill.BackgroundColor3 = Theme.Colors.Accent
	pill.BackgroundTransparency = 0.75
	pill.Text = "CLIENT"
	pill.TextColor3 = Theme.Colors.Accent
	pill.TextSize = Theme.TextSize.Badge
	pill.FontFace = Theme.Font.Bold
	pill.AutoButtonColor = false
	pill.BorderSizePixel = 0
	pill.ZIndex = 21
	pill.Parent = bar
	self._contextPill = pill

	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(0, 11)
	pillCorner.Parent = pill

	local pillStroke = Instance.new("UIStroke")
	pillStroke.Name = "PillStroke"
	pillStroke.Color = Theme.Colors.Accent
	pillStroke.Thickness = 1
	pillStroke.Transparency = 0.5
	pillStroke.Parent = pill

	pill.MouseButton1Click:Connect(function()
		local nextMode = if self._contextMode == "client" then "server" else "client"
		self:SetContextMode(nextMode)
		if self._onContextToggle then
			self._onContextToggle(nextMode)
		end
	end)

	pill.MouseEnter:Connect(function()
		TweenService:Create(pill, Theme.Tween.Fast, { BackgroundTransparency = 0.5 }):Play()
	end)
	pill.MouseLeave:Connect(function()
		TweenService:Create(pill, Theme.Tween.Fast, { BackgroundTransparency = 0.75 }):Play()
	end)

	-- Minimize button
	local minBtn = Instance.new("TextButton")
	minBtn.Name = "MinimizeBtn"
	minBtn.Size = UDim2.new(0, 28, 0, 28)
	minBtn.Position = UDim2.new(1, -62, 0, 2)
	minBtn.BackgroundColor3 = Theme.Colors.GlassTertiary
	minBtn.BackgroundTransparency = 0.5
	minBtn.Text = "─"
	minBtn.TextColor3 = Theme.Colors.TextSecondary
	minBtn.TextSize = 14
	minBtn.FontFace = Theme.Font.Bold
	minBtn.AutoButtonColor = false
	minBtn.BorderSizePixel = 0
	minBtn.ZIndex = 21
	minBtn.Parent = bar

	local mc = Instance.new("UICorner")
	mc.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	mc.Parent = minBtn

	minBtn.MouseButton1Click:Connect(function()
		self:ToggleMinimize()
	end)

	-- Close button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.Size = UDim2.new(0, 28, 0, 28)
	closeBtn.Position = UDim2.new(1, -32, 0, 2)
	closeBtn.BackgroundColor3 = Theme.Colors.Danger
	closeBtn.BackgroundTransparency = 0.7
	closeBtn.Text = "✕"
	closeBtn.TextColor3 = Theme.Colors.TextSecondary
	closeBtn.TextSize = 12
	closeBtn.FontFace = Theme.Font.Bold
	closeBtn.AutoButtonColor = false
	closeBtn.BorderSizePixel = 0
	closeBtn.ZIndex = 21
	closeBtn.Parent = bar

	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	cc.Parent = closeBtn

	closeBtn.MouseButton1Click:Connect(function()
		self:Hide()
		if self._onClose then self._onClose() end
	end)

	-- Hover effects
	for _, btn in ipairs({ minBtn, closeBtn }) do
		btn.MouseEnter:Connect(function()
			TweenService:Create(btn, Theme.Tween.Fast, { BackgroundTransparency = 0.2 }):Play()
		end)
		btn.MouseLeave:Connect(function()
			TweenService:Create(btn, Theme.Tween.Fast, { BackgroundTransparency = if btn == closeBtn then 0.7 else 0.5 }):Play()
		end)
	end
end

-- ══════════════════════════════════════════════════════════════
-- SIDEBAR (left 48px icon rail)
-- ══════════════════════════════════════════════════════════════

function GlassGUI:_BuildSidebar(parent: Frame)
	local sidebar = Instance.new("Frame")
	sidebar.Name = "Sidebar"
	sidebar.Size = UDim2.new(0, 56, 1, -32) -- below title bar
	sidebar.Position = UDim2.new(0, 0, 0, 32)
	sidebar.BackgroundColor3 = Theme.Colors.GlassPrimary
	sidebar.BackgroundTransparency = 0.15
	sidebar.BorderSizePixel = 0
	sidebar.ZIndex = 15
	sidebar.Parent = parent
	self._sidebar = sidebar

	-- Right border (parented to main window so UIListLayout inside sidebar ignores it)
	local sidebarBorder = Instance.new("Frame")
	sidebarBorder.Name = "SidebarBorder"
	sidebarBorder.Size = UDim2.new(0, 1, 1, -32)
	sidebarBorder.Position = UDim2.new(0, 55, 0, 32)
	sidebarBorder.BackgroundColor3 = Theme.Colors.BorderSubtle
	sidebarBorder.BackgroundTransparency = 0.5
	sidebarBorder.BorderSizePixel = 0
	sidebarBorder.ZIndex = 16
	sidebarBorder.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = sidebar

	local topPad = Instance.new("UIPadding")
	topPad.PaddingTop = UDim.new(0, 8)
	topPad.Parent = sidebar

	-- Build subsystem icons
	local subsystems = {
		{ Id = "TASKS",     Order = 1 },
		{ Id = "FSM",       Order = 2 },
		{ Id = "ENTITY",    Order = 3 },
		{ Id = "NETWORK",   Order = 4 },
		{ Id = "DATASTORE", Order = 5 },
		{ Id = "INSIGHTS",  Order = 6 },
		{ Id = "CONSOLE",   Order = 7 },
		{ Id = "LOGS",      Order = 8 },
	}

	-- Short text labels for sidebar icons (fallback when images don't load)
	local sidebarLabels = {
		TASKS = "TSK",
		FSM = "FSM",
		ENTITY = "ENT",
		NETWORK = "NET",
		DATASTORE = "DS",
		INSIGHTS = "INS",
		CONSOLE = "CON",
		LOGS = "LOG",
	}

	for _, sub in ipairs(subsystems) do
		local btn = Instance.new("TextButton")
		btn.Name = "Nav_" .. sub.Id
		btn.Size = UDim2.new(0, 42, 0, 42)
		btn.BackgroundColor3 = Theme.SubsystemColors[sub.Id] or Theme.Colors.GlassTertiary
		btn.BackgroundTransparency = 0.75
		btn.Text = sidebarLabels[sub.Id] or sub.Id:sub(1, 3)
		btn.TextColor3 = Theme.SubsystemColors[sub.Id] or Theme.Colors.TextSecondary
		btn.TextSize = 10
		btn.FontFace = Theme.Font.Bold
		btn.AutoButtonColor = false
		btn.BorderSizePixel = 0
		btn.LayoutOrder = sub.Order
		btn.ZIndex = 16
		btn.Parent = sidebar

		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, Theme.Radius.Sm)
		bc.Parent = btn

		-- Icon
		local iconId = Theme.SubsystemIcons[sub.Id]
		if iconId then
			local icon = Instance.new("ImageLabel")
			icon.Size = UDim2.new(0, 20, 0, 20)
			icon.Position = UDim2.new(0.5, -10, 0.5, -10)
			icon.BackgroundTransparency = 1
			icon.Image = iconId
			icon.ImageColor3 = Theme.SubsystemColors[sub.Id] or Theme.Colors.TextSecondary
			icon.ZIndex = 17
			icon.Parent = btn
		end

		-- Tooltip label (shows on hover via offset below button)
		-- We'll use a frame approach for simplicity
		local tooltip = Instance.new("TextLabel")
		tooltip.Name = "Tooltip"
		tooltip.Size = UDim2.new(0, 100, 0, 22)
		tooltip.Position = UDim2.new(1, 8, 0.5, -11)
		tooltip.BackgroundColor3 = Theme.Colors.GlassOverlay
		tooltip.BackgroundTransparency = 0.1
		tooltip.Text = Theme.SubsystemNames and Theme.SubsystemNames[sub.Id] or sub.Id
		tooltip.TextColor3 = Theme.Colors.TextPrimary
		tooltip.TextSize = Theme.TextSize.Caption
		tooltip.FontFace = Theme.Font.Bold
		tooltip.BorderSizePixel = 0
		tooltip.Visible = false
		tooltip.ZIndex = 50
		tooltip.Parent = btn

		local tc = Instance.new("UICorner")
		tc.CornerRadius = UDim.new(0, Theme.Radius.Xs)
		tc.Parent = tooltip

		btn.MouseEnter:Connect(function()
			tooltip.Visible = true
			TweenService:Create(btn, Theme.Tween.Fast, {
				BackgroundTransparency = 0.5,
			}):Play()
		end)

		btn.MouseLeave:Connect(function()
			tooltip.Visible = false
			local isActive = self._activeSubsystem == sub.Id
			TweenService:Create(btn, Theme.Tween.Fast, {
				BackgroundTransparency = if isActive then 0.4 else 0.75,
			}):Play()
		end)

		btn.MouseButton1Click:Connect(function()
			if self._activeSubsystem == sub.Id then
				-- Re-clicking active subsystem navigates back to root
				if self._onSubsystemReselected then
					self._onSubsystemReselected(sub.Id)
				end
			else
				self:SelectSubsystem(sub.Id)
			end
		end)

		self._sidebarButtons[sub.Id] = btn
	end
end

-- ══════════════════════════════════════════════════════════════
-- BREADCRUMB BAR (horizontal bar below title, right of sidebar)
-- ══════════════════════════════════════════════════════════════

function GlassGUI:_BuildBreadcrumbBar(parent: Frame)
	local bar = Instance.new("Frame")
	bar.Name = "BreadcrumbBar"
	bar.Size = UDim2.new(1, -56, 0, 32)
	bar.Position = UDim2.new(0, 56, 0, 32)
	bar.BackgroundColor3 = Theme.Colors.GlassSecondary
	bar.BackgroundTransparency = 0.5
	bar.BorderSizePixel = 0
	bar.ZIndex = 10
	bar.ClipsDescendants = true
	bar.Parent = parent
	self._breadcrumbBar = bar

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = bar

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.Parent = bar

	-- Bottom border (parented to main window so UIListLayout inside bar ignores it)
	local breadcrumbBorder = Instance.new("Frame")
	breadcrumbBorder.Name = "BreadcrumbBorder"
	breadcrumbBorder.Size = UDim2.new(1, -56, 0, 1)
	breadcrumbBorder.Position = UDim2.new(0, 56, 0, 63) -- 32 title + 32 breadcrumb - 1
	breadcrumbBorder.BackgroundColor3 = Theme.Colors.BorderSubtle
	breadcrumbBorder.BackgroundTransparency = 0.6
	breadcrumbBorder.BorderSizePixel = 0
	breadcrumbBorder.ZIndex = 11
	breadcrumbBorder.Parent = parent

	-- Back button (visible only when drilled down into a detail view)
	local backBtn = Instance.new("TextButton")
	backBtn.Name = "BackBtn"
	backBtn.Size = UDim2.new(0, 26, 0, 22)
	backBtn.BackgroundColor3 = Theme.Colors.GlassTertiary
	backBtn.BackgroundTransparency = 0.4
	backBtn.Text = "\u{2039}"
	backBtn.TextColor3 = Theme.Colors.TextSecondary
	backBtn.TextSize = 16
	backBtn.FontFace = Theme.Font.Bold
	backBtn.AutoButtonColor = false
	backBtn.BorderSizePixel = 0
	backBtn.LayoutOrder = -1
	backBtn.ZIndex = 12
	backBtn.Visible = false
	backBtn.Parent = bar
	self._backButton = backBtn

	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	backCorner.Parent = backBtn

	backBtn.MouseEnter:Connect(function()
		TweenService:Create(backBtn, Theme.Tween.Fast, {
			BackgroundTransparency = 0.15,
			TextColor3 = Theme.Colors.Accent,
		}):Play()
	end)
	backBtn.MouseLeave:Connect(function()
		TweenService:Create(backBtn, Theme.Tween.Fast, {
			BackgroundTransparency = 0.4,
			TextColor3 = Theme.Colors.TextSecondary,
		}):Play()
	end)
	backBtn.MouseButton1Click:Connect(function()
		if self._onBackClick then self._onBackClick() end
	end)
end

--[[
	Rebuild the breadcrumb bar from the navigator's current crumb trail.
	Intermediate crumbs become clickable when a handler is supplied, while the
	first crumb retains subsystem coloring for orientation.
]]
function GlassGUI:UpdateBreadcrumbs(crumbs: { { Id: string, Label: string, Depth: number } }, onCrumbClick: ((id: string) -> ())?)
	local bar = self._breadcrumbBar
	if not bar then return end

	-- Clear existing crumbs (keep UIListLayout, UIPadding, border, BackBtn)
	for _, child in ipairs(bar:GetChildren()) do
		if (child:IsA("TextButton") or child:IsA("TextLabel")) and child.Name ~= "BackBtn" then
			child:Destroy()
		end
	end

	-- Show/hide back button based on navigation depth
	if self._backButton then
		self._backButton.Visible = #crumbs > 1
	end

	for i, crumb in ipairs(crumbs) do
		local isFirst = i == 1
		local isLast = i == #crumbs

		-- Separator
		if i > 1 then
			local sep = Theme.CreateLabel({
				Text = "›",
				Size = UDim2.new(0, 14, 0, 22),
				Color = Theme.Colors.TextMuted,
				FontSize = Theme.TextSize.Body,
				Alignment = Enum.TextXAlignment.Center,
				Parent = bar,
			})
			sep.LayoutOrder = (i - 1) * 2
		end

		-- Crumb button (first crumb uses subsystem color for clear identification)
		local subsystemColor = isFirst and Theme.SubsystemColors[crumb.Id] or nil
		local btn = Instance.new("TextButton")
		btn.Name = "Crumb_" .. crumb.Id
		btn.Size = UDim2.new(0, 0, 0, 22)
		btn.AutomaticSize = Enum.AutomaticSize.X
		btn.BackgroundTransparency = 1
		btn.Text = crumb.Label
		btn.TextColor3 = if isFirst and subsystemColor then subsystemColor
			elseif isLast then Theme.Colors.TextPrimary
			else Theme.Colors.TextSecondary
		btn.TextSize = if isFirst then Theme.TextSize.Body else Theme.TextSize.Caption
		btn.FontFace = if isFirst or isLast then Theme.Font.Bold else Theme.Font.Primary
		btn.AutoButtonColor = false
		btn.BorderSizePixel = 0
		btn.LayoutOrder = i * 2
		btn.ZIndex = 11
		btn.Parent = bar

		if not isLast and onCrumbClick then
			local restColor = if isFirst and subsystemColor then subsystemColor else Theme.Colors.TextSecondary
			btn.MouseButton1Click:Connect(function()
				onCrumbClick(crumb.Id)
			end)
			btn.MouseEnter:Connect(function()
				TweenService:Create(btn, Theme.Tween.Fast, { TextColor3 = Theme.Colors.Accent }):Play()
			end)
			btn.MouseLeave:Connect(function()
				TweenService:Create(btn, Theme.Tween.Fast, { TextColor3 = restColor }):Play()
			end)
		end
	end
end

-- ══════════════════════════════════════════════════════════════
-- BODY CONTAINER (main content area)
-- ══════════════════════════════════════════════════════════════

function GlassGUI:_BuildBodyContainer(parent: Frame)
	local body = Instance.new("Frame")
	body.Name = "BodyContainer"
	body.Size = UDim2.new(1, -56, 1, -88) -- below breadcrumb, above status bar
	body.Position = UDim2.new(0, 56, 0, 64) -- 32 title + 32 breadcrumb
	body.BackgroundColor3 = Theme.Colors.RootBG
	body.BackgroundTransparency = 0
	body.BorderSizePixel = 0
	body.ClipsDescendants = true
	body.ZIndex = 5
	body.Parent = parent
	self._bodyContainer = body

	-- Regular Frame host for Z-axis layers (NOT a ScrollingFrame—
	-- Scale-based children need a fixed-size parent, not auto-canvas)
	local host = Instance.new("Frame")
	host.Name = "LayerHost"
	host.Size = UDim2.new(1, -8, 1, -4)
	host.Position = UDim2.new(0, 4, 0, 2)
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.ClipsDescendants = true
	host.ZIndex = 6
	host.Parent = body
end

--[[
	Return the LayerHost frame used by ZAxisNavigator for subsystem content.
]]
function GlassGUI:GetBodyContainer(): Frame?
	if not self._bodyContainer then return nil end
	return self._bodyContainer:FindFirstChild("LayerHost") :: Frame?
end

-- ══════════════════════════════════════════════════════════════
-- STATUS BAR (bottom 24px)
-- ══════════════════════════════════════════════════════════════

function GlassGUI:_BuildStatusBar(parent: Frame)
	local bar = Instance.new("Frame")
	bar.Name = "StatusBar"
	bar.Size = UDim2.new(1, 0, 0, 24)
	bar.Position = UDim2.new(0, 0, 1, -24)
	bar.BackgroundColor3 = Theme.Colors.GlassPrimary
	bar.BackgroundTransparency = 0.2
	bar.BorderSizePixel = 0
	bar.ZIndex = 20
	bar.Parent = parent
	self._statusBar = bar

	-- Top border
	local border = Instance.new("Frame")
	border.Size = UDim2.new(1, 0, 0, 1)
	border.Position = UDim2.new(0, 0, 0, 0)
	border.BackgroundColor3 = Theme.Colors.BorderSubtle
	border.BackgroundTransparency = 0.6
	border.BorderSizePixel = 0
	border.ZIndex = 21
	border.Parent = bar

	-- Connection status indicator
	local connDot = Instance.new("Frame")
	connDot.Name = "ConnDot"
	connDot.Size = UDim2.new(0, 6, 0, 6)
	connDot.Position = UDim2.new(0, 8, 0.5, -3)
	connDot.BackgroundColor3 = Theme.Colors.Success
	connDot.BackgroundTransparency = 0
	connDot.BorderSizePixel = 0
	connDot.ZIndex = 22
	connDot.Parent = bar
	local cd = Instance.new("UICorner")
	cd.CornerRadius = UDim.new(1, 0)
	cd.Parent = connDot

	-- Status text
	local statusLabel = Theme.CreateLabel({
		Text = "CONNECTED",
		Size = UDim2.new(0.3, 0, 1, 0),
		Position = UDim2.new(0, 20, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Parent = bar,
	})
	statusLabel.Name = "StatusLabel"
	statusLabel.ZIndex = 22

	-- Insight count
	local insightLabel = Theme.CreateLabel({
		Text = "0 insights",
		Size = UDim2.new(0.2, 0, 1, 0),
		Position = UDim2.new(0.58, 0, 0, 0),
		Color = Theme.Colors.Warning,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Alignment = Enum.TextXAlignment.Center,
		Parent = bar,
	})
	insightLabel.Name = "InsightLabel"
	insightLabel.ZIndex = 22

	-- FPS / perf
	local perfLabel = Theme.CreateLabel({
		Text = "-- fps",
		Size = UDim2.new(0.2, 0, 1, 0),
		Position = UDim2.new(0.8, 0, 0, 0),
		Color = Theme.Colors.TextMuted,
		FontSize = Theme.TextSize.Tiny,
		FontFace = Theme.Font.Mono,
		Alignment = Enum.TextXAlignment.Right,
		Parent = bar,
	})
	perfLabel.Name = "PerfLabel"
	perfLabel.ZIndex = 22

	local perfPad = Instance.new("UIPadding")
	perfPad.PaddingRight = UDim.new(0, 8)
	perfPad.Parent = perfLabel
end

--[[
	Apply a partial status snapshot to the bottom status bar widgets.
	Callers can update connection state, insight count, and FPS independently.
]]
function GlassGUI:UpdateStatusBar(props: {
	Connected: boolean?,
	Mode: string?,
	InsightCount: number?,
	FPS: number?,
})
	local bar = self._statusBar
	if not bar then return end

	if props.Connected ~= nil then
		local dot = bar:FindFirstChild("ConnDot") :: Frame?
		local lbl = bar:FindFirstChild("StatusLabel") :: TextLabel?
		if dot then
			dot.BackgroundColor3 = if props.Connected then Theme.Colors.Success else Theme.Colors.Danger
		end
		if lbl then
			lbl.Text = if props.Connected then "CONNECTED" else "DISCONNECTED"
		end
	end

	if props.InsightCount ~= nil then
		local lbl = bar:FindFirstChild("InsightLabel") :: TextLabel?
		if lbl then
			lbl.Text = tostring(props.InsightCount) .. " insights"
			lbl.TextColor3 = if props.InsightCount > 0 then Theme.Colors.Warning else Theme.Colors.TextMuted
		end
	end

	if props.FPS ~= nil then
		local lbl = bar:FindFirstChild("PerfLabel") :: TextLabel?
		if lbl then
			lbl.Text = string.format("%.0f fps", props.FPS)
			lbl.TextColor3 = if props.FPS >= 55 then Theme.Colors.Success
				elseif props.FPS >= 30 then Theme.Colors.Warning
				else Theme.Colors.Danger
		end
	end
end

-- ══════════════════════════════════════════════════════════════
-- INSIGHT TOAST (bottom-right overlay notification)
-- ══════════════════════════════════════════════════════════════

function GlassGUI:_BuildInsightToast(parent: Frame)
	local toast = Instance.new("Frame")
	toast.Name = "InsightToast"
	toast.Size = UDim2.new(0, 260, 0, 60)
	toast.Position = UDim2.new(1, -270, 1, -90)
	toast.BackgroundColor3 = Theme.Colors.GlassOverlay
	toast.BackgroundTransparency = 0.1
	toast.BorderSizePixel = 0
	toast.Visible = false
	toast.ZIndex = 50
	toast.Parent = parent
	self._insightToast = toast

	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, Theme.Radius.Md)
	tc.Parent = toast

	local ts = Instance.new("UIStroke")
	ts.Color = Theme.Colors.Warning
	ts.Thickness = 1
	ts.Transparency = 0.4
	ts.Parent = toast

	local tp = Instance.new("UIPadding")
	tp.PaddingLeft = UDim.new(0, 10)
	tp.PaddingRight = UDim.new(0, 10)
	tp.PaddingTop = UDim.new(0, 8)
	tp.Parent = toast

	local titleLabel = Theme.CreateLabel({
		Text = "",
		Size = UDim2.new(1, 0, 0, 16),
		Color = Theme.Colors.Warning,
		FontSize = Theme.TextSize.Body,
		FontFace = Theme.Font.Bold,
		Parent = toast,
	})
	titleLabel.Name = "ToastTitle"
	titleLabel.ZIndex = 51

	local descLabel = Theme.CreateLabel({
		Text = "",
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.new(0, 0, 0, 20),
		Color = Theme.Colors.TextSecondary,
		FontSize = Theme.TextSize.Caption,
		Parent = toast,
	})
	descLabel.Name = "ToastDesc"
	descLabel.ZIndex = 51
	descLabel.TextWrapped = true
end

--[[
	Show a temporary insight notification in the bottom-right overlay.
	Severity controls the accent color, while duration determines auto-dismiss.
]]
function GlassGUI:ShowInsightToast(title: string, description: string, severity: string?, duration: number?)
	local toast = self._insightToast
	if not toast then return end

	local severityColors = {
		CRITICAL = Theme.Colors.Danger,
		WARNING = Theme.Colors.Warning,
		INFO = Theme.Colors.Accent,
		SUGGESTION = Theme.Colors.Purple,
	}
	local color = severityColors[severity or "INFO"] or Theme.Colors.Accent

	local stroke = toast:FindFirstChildOfClass("UIStroke")
	if stroke then stroke.Color = color end

	local titleLbl = toast:FindFirstChild("ToastTitle") :: TextLabel?
	if titleLbl then
		titleLbl.Text = "↯ " .. title
		titleLbl.TextColor3 = color
	end

	local descLbl = toast:FindFirstChild("ToastDesc") :: TextLabel?
	if descLbl then descLbl.Text = description end

	-- Animate in
	toast.Position = UDim2.new(1, -10, 1, -90)
	toast.Visible = true
	TweenService:Create(toast, Theme.Tween.Bounce, {
		Position = UDim2.new(1, -270, 1, -90),
	}):Play()

	-- Auto-dismiss
	task.delay(duration or 4, function()
		if toast and toast.Visible then
			local tw = TweenService:Create(toast, Theme.Tween.Fast, {
				Position = UDim2.new(1, -10, 1, -90),
			})
			tw:Play()
			tw.Completed:Connect(function()
				toast.Visible = false
			end)
		end
	end)
end

-- ══════════════════════════════════════════════════════════════
-- SIDEBAR SELECTION
-- ══════════════════════════════════════════════════════════════

--[[
	Update sidebar selection visuals and optionally notify the orchestrator about
	a subsystem change.
]]
function GlassGUI:SelectSubsystem(id: string, suppressCallback: boolean?)
	local prev = self._activeSubsystem
	self._activeSubsystem = id

	-- Update button visuals
	for subId, btn in pairs(self._sidebarButtons) do
		local isActive = subId == id
		local color = Theme.SubsystemColors[subId] or Theme.Colors.GlassTertiary

		TweenService:Create(btn, Theme.Tween.Fast, {
			BackgroundTransparency = if isActive then 0.35 else 0.75,
			BackgroundColor3 = if isActive then color else Theme.Colors.GlassTertiary,
		}):Play()

		-- Active indicator bar
		local indicator = btn:FindFirstChild("ActiveIndicator")
		if isActive then
			if not indicator then
				indicator = Instance.new("Frame")
				indicator.Name = "ActiveIndicator"
				indicator.Size = UDim2.new(0, 3, 0.7, 0)
				indicator.Position = UDim2.new(0, -1, 0.15, 0)
				indicator.BackgroundColor3 = color
				indicator.BackgroundTransparency = 0
				indicator.BorderSizePixel = 0
				indicator.ZIndex = 18
				indicator.Parent = btn

				local ic = Instance.new("UICorner")
				ic.CornerRadius = UDim.new(0, 2)
				ic.Parent = indicator
			end
		else
			if indicator then indicator:Destroy() end
		end
	end

	if not suppressCallback and self._onSubsystemSelected and id ~= prev then
		self._onSubsystemSelected(id)
	end
end

-- ══════════════════════════════════════════════════════════════
-- WINDOW CONTROLS
-- ══════════════════════════════════════════════════════════════

--[[
	Show the window, using a reduced first-show path because Roblox will not tween
	freshly enabled ScreenGuis reliably on the same frame.
]]
function GlassGUI:Show()
	if not self._screenGui then return end
	local wasEnabled = self._screenGui.Enabled
	self._screenGui.Enabled = true
	self._visible = true

	local main = self._mainFrame
	if main then
		local targetSize = self._restoreSize or self._userSize or UDim2.new(0.85, 0, 0.85, 0)
		if not wasEnabled then
			-- First show: set final state directly (tween cannot run on freshly-enabled ScreenGui)
			main.Size = targetSize
			main.BackgroundTransparency = 0
		else
			-- Subsequent shows: animate from collapsed state
			main.Size = UDim2.new(0, 700, 0, 20)
			main.BackgroundTransparency = 0.5
			TweenService:Create(main, Theme.Tween.Expand, {
				Size = targetSize,
				BackgroundTransparency = 0,
			}):Play()
		end
	end
end

--[[
	Animate the window closed and disable the ScreenGui when the collapse completes.
]]
function GlassGUI:Hide()
	if not self._screenGui then return end
	local main = self._mainFrame
	if main then
		local tw = TweenService:Create(main, Theme.Tween.Collapse, {
			Size = UDim2.new(0, 700, 0, 20),
			BackgroundTransparency = 0.8,
		})
		tw:Play()
		tw.Completed:Connect(function()
			if self._screenGui then
				self._screenGui.Enabled = false
			end
			self._visible = false
		end)
	end
end

--[[
	Return whether the GUI is currently marked visible.
]]
function GlassGUI:IsVisible(): boolean
	return self._visible
end

--[[
	Toggle between minimized and expanded window states.
	Preserves the user's last resized dimensions so restore returns to the same
	working layout.
]]
function GlassGUI:ToggleMinimize()
	self._minimized = not self._minimized
	local main = self._mainFrame
	if not main then return end

	if self._minimized then
		-- Stash the current size so Restore returns to it (the user may have
		-- resized; we don't want to lose their layout).
		self._restoreSize = main.Size
		local curW = main.AbsoluteSize.X
		TweenService:Create(main, Theme.Tween.Collapse, {
			Size = UDim2.new(0, math.max(curW, 740), 0, 32),
		}):Play()
	else
		-- Restore to the stashed size, falling back to the user-resized size,
		-- and finally to the default scale-based size if nothing was tracked.
		local target = self._restoreSize or self._userSize or UDim2.new(0.85, 0, 0.85, 0)
		TweenService:Create(main, Theme.Tween.Expand, {
			Size = target,
		}):Play()
	end

	if self._onMinimizeToggle then
		self._onMinimizeToggle(self._minimized)
	end
end

-- ══════════════════════════════════════════════════════════════
-- DRAGGING
-- ══════════════════════════════════════════════════════════════

function GlassGUI:_SetupDragging(main: Frame)
	local titleBar = main:FindFirstChild("TitleBar") :: Frame?
	if not titleBar then return end

	-- Invisible drag handle covers the title bar text area
	local handle = Instance.new("TextButton")
	handle.Name = "DragHandle"
	handle.Size = UDim2.new(0.7, 0, 1, 0)
	handle.Position = UDim2.new(0, 0, 0, 0)
	handle.BackgroundTransparency = 1
	handle.Text = ""
	handle.ZIndex = 19
	handle.Parent = titleBar

	-- All connections are stored in self._connections so Destroy() can release
	-- them. Anonymous Connect on UserInputService leaks for the lifetime of the
	-- script; without this list, repeated Initialize/Destroy doubles the count
	-- and the callbacks fire against a destroyed frame on the next mouse move.
	self._connections = self._connections or {}

	table.insert(self._connections, handle.MouseButton1Down:Connect(function()
		self._dragging = true
		self._dragStart = UserInputService:GetMouseLocation()
		self._frameStart = main.Position
	end))

	table.insert(self._connections, UserInputService.InputChanged:Connect(function(input)
		if not self._dragging then return end
		if not main.Parent then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			local mouse = UserInputService:GetMouseLocation()
			local delta = mouse - self._dragStart
			local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
			local desired = UDim2.new(
				self._frameStart.X.Scale,
				self._frameStart.X.Offset + delta.X,
				self._frameStart.Y.Scale,
				self._frameStart.Y.Offset + delta.Y
			)
			main.Position = ClampWindowPosition(desired, main.AnchorPoint, main.AbsoluteSize, viewport)
		end
	end))

	table.insert(self._connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self._dragging = false
		end
	end))
end

-- ══════════════════════════════════════════════════════════════
-- RESIZING (bottom-right corner grip)
-- ══════════════════════════════════════════════════════════════

function GlassGUI:_SetupResizing(main: Frame)
	local MIN_WIDTH = 600
	local MIN_HEIGHT = 360

	-- Visible grip handle in the bottom-right corner
	local grip = Instance.new("TextButton")
	grip.Name = "ResizeGrip"
	grip.Size = UDim2.new(0, 18, 0, 18)
	grip.AnchorPoint = Vector2.new(1, 1)
	grip.Position = UDim2.new(1, -2, 1, -2)
	grip.BackgroundTransparency = 1
	grip.Text = "//"
	grip.TextColor3 = Theme.Colors.TextMuted
	grip.TextSize = 14
	grip.FontFace = Theme.Font.Bold
	grip.AutoButtonColor = false
	grip.ZIndex = Theme.ZIndex.StatusBar + 1
	grip.Parent = main

	local resizing = false
	local startMouse: Vector2 = Vector2.zero
	local startAbsoluteSize: Vector2 = main.AbsoluteSize

	self._connections = self._connections or {}

	table.insert(self._connections, grip.MouseEnter:Connect(function()
		grip.TextColor3 = Theme.Colors.Accent
	end))
	table.insert(self._connections, grip.MouseLeave:Connect(function()
		if not resizing then grip.TextColor3 = Theme.Colors.TextMuted end
	end))

	table.insert(self._connections, grip.MouseButton1Down:Connect(function()
		resizing = true
		startMouse = UserInputService:GetMouseLocation()
		startAbsoluteSize = main.AbsoluteSize
		-- Track the user's resized size so minimize/restore preserves it.
		self._userSize = main.Size
		grip.TextColor3 = Theme.Colors.Accent
	end))

	table.insert(self._connections, UserInputService.InputChanged:Connect(function(input)
		if not resizing then return end
		if not main.Parent then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local mouse = UserInputService:GetMouseLocation()
		local delta = mouse - startMouse
		local newWidth = math.max(MIN_WIDTH, startAbsoluteSize.X + delta.X)
		local newHeight = math.max(MIN_HEIGHT, startAbsoluteSize.Y + delta.Y)
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)
		newWidth = math.min(newWidth, viewport.X - 40)
		newHeight = math.min(newHeight, viewport.Y - 40)
		main.Size = UDim2.new(0, newWidth, 0, newHeight)
		main.Position = ClampWindowPosition(main.Position, main.AnchorPoint, Vector2.new(newWidth, newHeight), viewport)
		self._userSize = main.Size
	end))

	table.insert(self._connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and resizing then
			resizing = false
			grip.TextColor3 = Theme.Colors.TextMuted
		end
	end))
end

-- ══════════════════════════════════════════════════════════════
-- CALLBACKS
-- ══════════════════════════════════════════════════════════════

-- Register a callback fired when the active subsystem changes.
function GlassGUI:OnSubsystemSelected(callback: (name: string) -> ())
	self._onSubsystemSelected = callback
end

-- Register a callback fired after minimize state changes.
function GlassGUI:OnMinimizeToggle(callback: (minimized: boolean) -> ())
	self._onMinimizeToggle = callback
end

-- Register a callback fired when the close button is pressed.
function GlassGUI:OnClose(callback: () -> ())
	self._onClose = callback
end

-- Register a callback fired when the client/server pill is toggled.
function GlassGUI:OnContextToggle(callback: (mode: string) -> ())
	self._onContextToggle = callback
end

-- Register a callback fired when the breadcrumb back button is pressed.
function GlassGUI:OnBackClick(callback: () -> ())
	self._onBackClick = callback
end

-- Register a callback fired when the current subsystem is clicked again.
function GlassGUI:OnSubsystemReselected(callback: (name: string) -> ())
	self._onSubsystemReselected = callback
end

--[[
	Update the client/server mode pill to reflect the orchestrator's active mode.
]]
function GlassGUI:SetContextMode(mode: string)
	self._contextMode = mode
	local pill = self._contextPill
	if not pill then return end

	local isServer = mode == "server"
	local color = if isServer then Theme.Colors.Purple else Theme.Colors.Accent
	local text = if isServer then "SERVER" else "CLIENT"

	pill.Text = text
	TweenService:Create(pill, Theme.Tween.Fast, {
		BackgroundColor3 = color,
		TextColor3 = color,
	}):Play()

	local stroke = pill:FindFirstChild("PillStroke") :: UIStroke?
	if stroke then
		TweenService:Create(stroke, Theme.Tween.Fast, { Color = color }):Play()
	end
end

-- ══════════════════════════════════════════════════════════════
-- CLEANUP
-- ══════════════════════════════════════════════════════════════

--[[
	Disconnect all retained GUI event handlers and destroy the ScreenGui shell.
]]
function GlassGUI:Destroy()
	-- Release all stored connections (drag, resize, hover, button clicks).
	-- Without this, UserInputService callbacks survive the ScreenGui's destroy
	-- and would write to a torn-down Frame on the next mouse event.
	if self._connections then
		for _, conn in ipairs(self._connections) do
			pcall(function() conn:Disconnect() end)
		end
		table.clear(self._connections)
	end
	if self._screenGui then
		self._screenGui:Destroy()
		self._screenGui = nil
	end
	table.clear(self._sidebarButtons)
	self._mainFrame = nil
	self._sidebar = nil
	self._breadcrumbBar = nil
	self._bodyContainer = nil
	self._statusBar = nil
	self._insightToast = nil
end

return GlassGUI
