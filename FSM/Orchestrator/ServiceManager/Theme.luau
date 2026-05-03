--!strict
--[=[
	@module Theme
	@description Defines the `Theme` module and its exported API.
]=]

local Theme = {}

-- ══════════════════════════════════════════════════════════════
-- GLASS ENGINE PALETTE
-- ══════════════════════════════════════════════════════════════

Theme.Colors = {
	-- Surfaces (deep-space glass layers)
	RootBG          = Color3.fromRGB(8, 8, 14),
	GlassPrimary    = Color3.fromRGB(14, 14, 22),
	GlassSecondary  = Color3.fromRGB(20, 20, 30),
	GlassTertiary   = Color3.fromRGB(26, 26, 38),
	GlassOverlay    = Color3.fromRGB(32, 32, 46),
	CardBG          = Color3.fromRGB(22, 22, 34),

	-- Borders
	BorderPrimary   = Color3.fromRGB(48, 48, 66),
	BorderSubtle    = Color3.fromRGB(36, 36, 50),
	BorderGlow      = Color3.fromRGB(56, 152, 255),

	-- Semantic
	Accent          = Color3.fromRGB(56, 152, 255),
	AccentDim       = Color3.fromRGB(36, 100, 180),
	Success         = Color3.fromRGB(60, 210, 120),
	Warning         = Color3.fromRGB(245, 200, 70),
	Danger          = Color3.fromRGB(240, 80, 80),
	Purple          = Color3.fromRGB(155, 115, 255),
	Cyan            = Color3.fromRGB(0, 210, 225),
	Orange          = Color3.fromRGB(250, 170, 75),

	-- Text
	TextPrimary     = Color3.fromRGB(232, 234, 242),
	TextSecondary   = Color3.fromRGB(138, 142, 160),
	TextMuted       = Color3.fromRGB(82, 86, 104),
	TextOnAccent    = Color3.fromRGB(255, 255, 255),
}

Theme.Radius = {
	Lg = 12,
	Md = 8,
	Sm = 5,
	Xs = 3,
}

Theme.Transparency = {
	Glass       = 0.06,
	Overlay     = 0.35,
	HoverLift   = 0.04,
	SubPane     = 0.08,
}

Theme.Font = {
	Primary   = Font.fromEnum(Enum.Font.GothamMedium),
	Secondary = Font.fromEnum(Enum.Font.Gotham),
	Mono      = Font.fromEnum(Enum.Font.RobotoMono),
	Bold      = Font.fromEnum(Enum.Font.GothamBold),
}

Theme.TextSize = {
	Heading   = 16,
	Body      = 13,
	Caption   = 11,
	Tiny      = 9,
	Badge     = 10,
}

-- ══════════════════════════════════════════════════════════════
-- Z-INDEX TIERS — every overlay should reference these constants
-- ══════════════════════════════════════════════════════════════

Theme.ZIndex = {
	Background     = 0,    -- LayerHost backdrop
	LayerContent   = 5,    -- Default content
	Row            = 10,   -- Interactive rows / hit overlays
	RowHover       = 12,   -- Hover effects on rows
	Header         = 20,   -- Headers / perf strips above content
	Toolbar        = 25,   -- Toolbars / search bars
	Sidebar        = 30,   -- Sidebar buttons
	Breadcrumb     = 35,   -- Breadcrumb bar
	StatusBar      = 38,   -- Status bar
	TitleBar       = 40,   -- Title bar / window chrome
	Autocomplete   = 60,   -- Console autocomplete popup
	Tooltip        = 80,   -- Tooltip layer
	Toast          = 100,  -- Insight toasts
	Modal          = 200,  -- Modal overlays / dialogs
}

-- ══════════════════════════════════════════════════════════════
-- ANIMATION PRESETS
-- ══════════════════════════════════════════════════════════════

Theme.Tween = {
	Fast  = TweenInfo.new(0.15, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Med   = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Slow  = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	Bounce = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Expand = TweenInfo.new(0.32, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
	Collapse = TweenInfo.new(0.22, Enum.EasingStyle.Exponential, Enum.EasingDirection.In),
	Pulse = TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
}

-- ══════════════════════════════════════════════════════════════
-- SUBSYSTEM COLOR MAP
-- ══════════════════════════════════════════════════════════════

Theme.SubsystemColors = {
	TASKS     = Theme.Colors.Accent,
	FSM       = Theme.Colors.Cyan,
	ENTITY    = Theme.Colors.Success,
	NETWORK   = Theme.Colors.Orange,
	DATASTORE = Theme.Colors.Purple,
	INSIGHTS  = Theme.Colors.Warning,
	CONSOLE   = Color3.fromRGB(180, 220, 255),
	LOGS      = Color3.fromRGB(200, 160, 240),
}

Theme.SubsystemIcons = {
	TASKS     = "rbxassetid://7733715400", -- list icon
	FSM       = "rbxassetid://7734053495", -- workflow icon
	ENTITY    = "rbxassetid://7733717504", -- cube icon
	NETWORK   = "rbxassetid://7733960981", -- globe icon
	DATASTORE = "rbxassetid://7734042830", -- database icon
	INSIGHTS  = "rbxassetid://7743871164", -- lightbulb icon
	CONSOLE   = "rbxassetid://7734053495", -- terminal icon
	LOGS      = "rbxassetid://7733715400", -- log icon
}

Theme.SubsystemNames = {
	TASKS     = "Task Scheduler",
	FSM       = "State Machines",
	ENTITY    = "Entity Inspector",
	NETWORK   = "Network Hub",
	DATASTORE = "Data Store",
	INSIGHTS  = "Insights",
	CONSOLE   = "Console",
	LOGS      = "Log Viewer",
}
--[=[
	@description Returns the data produced by `Theme.GetDepthBackground`.
	@param depth number -- `depth` input parameter.
	@return Color3 -- Return value produced by the implementation, if any.
]=]

function Theme.GetDepthBackground(depth: number): Color3
	local base = Theme.Colors.GlassPrimary
	local lift = math.min(depth * 6, 30) / 255
	return Color3.new(
		math.min(base.R + lift, 1),
		math.min(base.G + lift, 1),
		math.min(base.B + lift, 1)
	)
end
--[=[
	@description Returns the data produced by `Theme.GetDepthTransparency`.
	@param depth number -- `depth` input parameter.
	@return number -- Return value produced by the implementation, if any.
]=]

function Theme.GetDepthTransparency(depth: number): number
	return math.max(0, Theme.Transparency.Glass - depth * 0.01)
end
--[=[
	@description Implements `Theme.ApplyGlass`.
	@param frame Frame -- `frame` input parameter.
	@param depth number? -- `depth` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Theme.ApplyGlass(frame: Frame, depth: number?)
	local d = depth or 0
	frame.BackgroundColor3 = Theme.GetDepthBackground(d)
	frame.BackgroundTransparency = Theme.GetDepthTransparency(d)
	frame.BorderSizePixel = 0

	local existing = frame:FindFirstChildOfClass("UICorner")
	if not existing then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Theme.Radius.Md)
		corner.Parent = frame
	end

	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Color = Theme.Colors.BorderSubtle
		stroke.Thickness = 1
		stroke.Transparency = 0.5
		stroke.Parent = frame
	end
end
--[=[
	@description Creates the result managed by `Theme.CreateLabel`.
	@param props { Text: string?, Size: UDim2?, Position: UDim2?, AnchorPoint: Vector2?, Color: Color3?, FontSize: number?, FontFace: Font?, Alignment: Enum.TextXAlignment?, Parent: Instance?, } -- `props` input parameter.
	@return TextLabel -- Return value produced by the implementation, if any.
]=]

function Theme.CreateLabel(props: {
	Text: string?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	Color: Color3?,
	FontSize: number?,
	FontFace: Font?,
	Alignment: Enum.TextXAlignment?,
	Parent: Instance?,
}): TextLabel
	local label = Instance.new("TextLabel")
	label.Text = props.Text or ""
	label.Size = props.Size or UDim2.new(1, 0, 0, 20)
	label.Position = props.Position or UDim2.new(0, 0, 0, 0)
	if props.AnchorPoint then label.AnchorPoint = props.AnchorPoint end
	label.BackgroundTransparency = 1
	label.TextColor3 = props.Color or Theme.Colors.TextPrimary
	label.TextSize = props.FontSize or Theme.TextSize.Body
	label.FontFace = props.FontFace or Theme.Font.Primary
	label.TextXAlignment = props.Alignment or Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.RichText = true
	if props.Parent then label.Parent = props.Parent end
	return label
end
--[=[
	@description Creates the result managed by `Theme.CreateBadge`.
	@param text string -- `text` input parameter.
	@param color Color3 -- `color` input parameter.
	@param parent Instance? -- `parent` input parameter.
	@return Frame -- Return value produced by the implementation, if any.
]=]

function Theme.CreateBadge(text: string, color: Color3, parent: Instance?): Frame
	local badge = Instance.new("Frame")
	badge.Size = UDim2.new(0, 0, 0, 18)
	badge.AutomaticSize = Enum.AutomaticSize.X
	badge.BackgroundColor3 = color
	badge.BackgroundTransparency = 0.82
	badge.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	corner.Parent = badge

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = badge

	local lbl = Instance.new("TextLabel")
	lbl.Text = text
	lbl.Size = UDim2.new(0, 0, 1, 0)
	lbl.AutomaticSize = Enum.AutomaticSize.X
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = color
	lbl.TextSize = Theme.TextSize.Badge
	lbl.FontFace = Theme.Font.Bold
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.Parent = badge

	if parent then badge.Parent = parent end
	return badge
end
--[=[
	@description Creates the result managed by `Theme.CreateIconButton`.
	@param props { Icon: string?, Label: string?, Size: UDim2?, Color: Color3?, Parent: Instance?, } -- `props` input parameter.
	@return TextButton -- Return value produced by the implementation, if any.
]=]

function Theme.CreateIconButton(props: {
	Icon: string?,
	Label: string?,
	Size: UDim2?,
	Color: Color3?,
	Parent: Instance?,
}): TextButton
	local btn = Instance.new("TextButton")
	btn.Size = props.Size or UDim2.new(0, 36, 0, 36)
	btn.BackgroundColor3 = props.Color or Theme.Colors.GlassTertiary
	btn.BackgroundTransparency = 0.4
	btn.BorderSizePixel = 0
	btn.Text = props.Label or ""
	btn.TextColor3 = Theme.Colors.TextSecondary
	btn.TextSize = Theme.TextSize.Caption
	btn.FontFace = Theme.Font.Primary
	btn.AutoButtonColor = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	corner.Parent = btn

	if props.Icon then
		local icon = Instance.new("ImageLabel")
		icon.Size = UDim2.new(0, 18, 0, 18)
		icon.Position = UDim2.new(0.5, -9, 0.5, -9)
		icon.BackgroundTransparency = 1
		icon.Image = props.Icon
		icon.ImageColor3 = Theme.Colors.TextSecondary
		icon.Parent = btn
		btn.Text = ""
	end

	if props.Parent then btn.Parent = props.Parent end
	return btn
end
--[=[
	@description Returns the data produced by `Theme.GetOrCreateChild`.
	@param parent Instance -- `parent` input parameter.
	@param name string -- `name` input parameter.
	@param factory () -> Instance -- `factory` input parameter.
	@return (Instance, boolean) -- Return value produced by the implementation, if any.
]=]

function Theme.GetOrCreateChild(parent: Instance, name: string, factory: () -> Instance): (Instance, boolean)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing, false
	end
	local created = factory()
	created.Name = name
	created.Parent = parent
	return created, true
end
--[=[
	@description Implements `Theme.ClearExcept`.
	@param parent Instance -- `parent` input parameter.
	@param keep { [string]: true } -- `keep` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Theme.ClearExcept(parent: Instance, keep: { [string]: true })
	for _, child in ipairs(parent:GetChildren()) do
		if keep[child.Name] then continue end
		if child:IsA("UICorner") or child:IsA("UIStroke") or child:IsA("UIPadding")
			or child:IsA("UIListLayout") or child:IsA("UIGridLayout") then continue end
		child:Destroy()
	end
end
--[=[
	@description Implements `Theme.ApplyProps`.
	@param inst Instance -- `inst` input parameter.
	@param props { [string]: any } -- `props` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Theme.ApplyProps(inst: Instance, props: { [string]: any })
	for k, v in pairs(props) do
		local ok, current = pcall(function() return (inst :: any)[k] end)
		if ok and current ~= v then
			pcall(function() (inst :: any)[k] = v end)
		end
	end
end

-- ══════════════════════════════════════════════════════════════
-- GLYPHS — symbols that render reliably in the default Gotham fonts
-- ══════════════════════════════════════════════════════════════
-- The Gotham font family does NOT include emoji or many pictographic
-- characters (📋 📜 ⚡ 📡 💾 🗄 ⚠ 🔴 🟡 🟢 🚪 💀 ⏳ ⏱ ◢ ⬡ etc.).
-- Those render as empty boxes (.notdef glyph). Use this table instead.
-- All entries are in Unicode blocks Gotham covers (Geometric Shapes,
-- Arrows, Misc Symbols ranges that ship with the font).
Theme.Glyph = {
	-- Status / state
	Active     = "●",  -- filled circle
	Inactive   = "○",  -- empty circle
	Warning    = "↑",  -- triangle (warning)
	Error      = "✕",  -- multiplication X
	Success    = "✓",  -- check
	Failed     = "✕",
	Stalled    = "·",  -- filled square (paused/blocked)

	-- Directional / arrows
	Right      = "▶",  -- play / right
	Left       = "◀",  -- back
	Up         = "↑",
	Down       = "↓",
	Refresh    = "",  -- circular arrow (clockwise)
	Reload     = "",  -- counter-clockwise (use plain text instead)
	Back       = "‹",
	Forward    = "›",

	-- UI affordances
	Diamond    = "◆",
	DiamondOut = "◇",
	Hexagon    = "◇",  -- hex stub (Gotham has no hex)
	Star       = "★",
	StarOut    = "☆",
	Bullet     = "•",
	GripDot    = "·",
	GripCorner = "//",  -- bottom-right grip indicator (often available)
	Search     = "›",  -- not a real magnifying glass; substitute
	Settings   = "≡",  -- hamburger / list

	-- Concept badges (ascii-friendly stand-ins for emoji)
	Lightning  = "↯",  -- if missing, fall back to text below
	Lock       = "▣",
	Unlock     = "▢",
	Persist    = "◆",  -- "persist" diamond
	Replicate  = "↗",  -- north-east arrow ("sent over network")
	Save       = "▽",
	Trash      = "▽",
	Clipboard  = "≡",
	Scroll     = "≡",  -- transition history / list
	Clock      = "○",  -- approximate
	History    = "≡",
	Database   = "▦",
	Key        = "•",
	Door       = "▥",
	Pulse      = "◉",
	Visualize  = "◆",
	Metric     = "◆",
}

-- ══════════════════════════════════════════════════════════════
-- ROW BUILDER (overlap-free, right-anchored data column cluster)
-- ══════════════════════════════════════════════════════════════

export type RowStat = {
	Text: string,
	Color: Color3?,
	Width: number?,         -- pixels; default 70
	Mono: boolean?,         -- default true
	Align: Enum.TextXAlignment?, -- default Right
	FontSize: number?,      -- default Caption
}
--[=[
	@description Creates the result managed by `Theme.CreateRow`.
	@param props { Name: string, Size: UDim2?, StatusColor: Color3?, StatusPulse: boolean?, Title: string, TitleColor: Color3?, Subtitle: string?, Stats: { RowStat }?, BackgroundColor: Color3?, BackgroundTransparency: number?, LayoutOrder: number?, Parent: Instance?, OnClick: (() -> ())?, } -- `props` input parameter.
	@return Frame -- Return value produced by the implementation, if any.
]=]

function Theme.CreateRow(props: {
	Name: string,
	Size: UDim2?,
	StatusColor: Color3?,
	StatusPulse: boolean?,
	Title: string,
	TitleColor: Color3?,
	Subtitle: string?,
	Stats: { RowStat }?,
	BackgroundColor: Color3?,
	BackgroundTransparency: number?,
	LayoutOrder: number?,
	Parent: Instance?,
	OnClick: (() -> ())?,
}): Frame
	local row = Instance.new("Frame")
	row.Name = props.Name
	row.Size = props.Size or UDim2.new(1, 0, 0, 36)
	row.BackgroundColor3 = props.BackgroundColor or Theme.Colors.GlassTertiary
	row.BackgroundTransparency = props.BackgroundTransparency or 0.85
	row.BorderSizePixel = 0
	row.LayoutOrder = props.LayoutOrder or 0
	if props.Parent then row.Parent = props.Parent end

	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0, Theme.Radius.Xs)
	rc.Parent = row

	local rp = Instance.new("UIPadding")
	rp.PaddingLeft = UDim.new(0, 10)
	rp.PaddingRight = UDim.new(0, 10)
	rp.Parent = row

	-- Status dot (left edge)
	if props.StatusColor then
		local dot = Instance.new("Frame")
		dot.Name = "StatusDot"
		dot.Size = UDim2.new(0, 6, 0, 6)
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.new(0, 0, 0.5, 0)
		dot.BackgroundColor3 = props.StatusColor
		dot.BorderSizePixel = 0
		dot.ZIndex = Theme.ZIndex.Row + 1
		dot.Parent = row
		local dc = Instance.new("UICorner")
		dc.CornerRadius = UDim.new(1, 0)
		dc.Parent = dot
	end

	-- Right-anchored stats cluster (built first so we can size the title around it)
	local rightCluster = Instance.new("Frame")
	rightCluster.Name = "RightCluster"
	rightCluster.AnchorPoint = Vector2.new(1, 0.5)
	rightCluster.Position = UDim2.new(1, 0, 0.5, 0)
	rightCluster.Size = UDim2.new(0, 0, 1, 0) -- AutomaticSize.X
	rightCluster.AutomaticSize = Enum.AutomaticSize.X
	rightCluster.BackgroundTransparency = 1
	rightCluster.ZIndex = Theme.ZIndex.Row + 1
	rightCluster.Parent = row

	local rcLayout = Instance.new("UIListLayout")
	rcLayout.FillDirection = Enum.FillDirection.Horizontal
	rcLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rcLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rcLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rcLayout.Padding = UDim.new(0, 10)
	rcLayout.Parent = rightCluster

	local stats = props.Stats or {}
	for i, stat in ipairs(stats) do
		local cell = Instance.new("TextLabel")
		cell.Name = "Stat_" .. i
		cell.Size = UDim2.new(0, stat.Width or 70, 0, 18)
		cell.BackgroundTransparency = 1
		cell.Text = stat.Text
		cell.TextColor3 = stat.Color or Theme.Colors.TextSecondary
		cell.TextSize = stat.FontSize or Theme.TextSize.Caption
		cell.FontFace = if stat.Mono == false then Theme.Font.Primary else Theme.Font.Mono
		cell.TextXAlignment = stat.Align or Enum.TextXAlignment.Right
		cell.TextTruncate = Enum.TextTruncate.AtEnd
		cell.LayoutOrder = i
		cell.RichText = true
		cell.Parent = rightCluster
	end

	-- Title (takes remaining space between status dot and right cluster)
	local titleStartX = if props.StatusColor then 12 else 0
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.new(0, titleStartX, 0.5, 0)
	-- Width: full row minus rightCluster's auto-size; we'll set width via a UISizeConstraint
	-- approach — but simpler is to use an offset relative to the right cluster.
	-- Trick: use AnchorPoint(1,0.5) and Position(1,-rightWidth-pad,0.5,0). That requires
	-- knowing rightCluster width. Easier: rely on UIListLayout in the parent.
	-- Instead we'll constrain title to (1, -rightClusterWidth - dotWidth - padding, 1, 0)
	-- by reading AbsoluteSize. We do it via a connection.
	title.Size = UDim2.new(1, -titleStartX - 100, 1, 0) -- initial; resize on cluster change
	title.BackgroundTransparency = 1
	title.Text = props.Title
	title.TextColor3 = props.TitleColor or Theme.Colors.TextPrimary
	title.TextSize = Theme.TextSize.Body
	title.FontFace = Theme.Font.Primary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.RichText = true
	title.ZIndex = Theme.ZIndex.Row + 1
	title.Parent = row

	-- Dynamically size the title to fill available space (row width - rightCluster width)
	local function syncTitleWidth()
		if not row.Parent then return end
		local rowW = row.AbsoluteSize.X
		local rcW = rightCluster.AbsoluteSize.X
		if rowW <= 0 then return end
		local available = rowW - rcW - titleStartX - 28 -- account for padding
		if available < 60 then available = 60 end
		title.Size = UDim2.new(0, available, 1, 0)
	end
	row:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncTitleWidth)
	rightCluster:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncTitleWidth)
	-- Fire once after layout is parented
	task.defer(syncTitleWidth)

	-- Click overlay (transparent button covers row)
	if props.OnClick then
		local btn = Instance.new("TextButton")
		btn.Name = "ClickOverlay"
		btn.Size = UDim2.new(1, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.ZIndex = Theme.ZIndex.Row
		btn.Parent = row
		btn.MouseButton1Click:Connect(props.OnClick)
		-- Expose callback via attribute reference for tests; tests can read
		-- this and invoke it directly to simulate a click without firing the
		-- real MouseButton1Click signal (which is read-only).
		row:SetAttribute("HasClickHandler", true)
		-- Store the raw callback in a registered handlers table
		Theme._clickHandlers = Theme._clickHandlers or {}
		Theme._clickHandlers[row] = props.OnClick
	end

	return row
end
--[=[
	@description Implements `Theme.SimulateRowClick`.
	@param row Frame -- `row` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function Theme.SimulateRowClick(row: Frame): boolean
	if not Theme._clickHandlers then return false end
	local handler = Theme._clickHandlers[row]
	if not handler then return false end
	handler()
	return true
end

return Theme
