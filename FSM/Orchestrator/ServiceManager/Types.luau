--!strict


export type LogLevel = "INFO" |"WARN" |"ERROR" |"DEBUG"

-- Z-Axis depth layer descriptor
export type DepthLayer = {
	Id: string,
	ParentId: string?,
	Depth: number,
	Label: string,
	ContentBuilder: ((context: LayerContext) -> ())?,
	IsExpanded: boolean,
	Timestamp: number,
}

-- Context passed into each layer when it expands
export type LayerContext = {
	LayerId: string,
	ParentLayerId: string?,
	Depth: number,
	DataKey: string?,
	DataValue: any?,
	Breadcrumbs: { string },
	Subsystem: string?,
	Orchestrator: any,
}

-- Subsystem descriptor for behavior tree orchestration
export type SubsystemDescriptor = {
	Name: string,
	Icon: string,
	Color: Color3,
	Priority: number,
	Module: any?,
	IsActive: boolean,
	LastTick: number,
	TickBudgetMs: number,
}

-- Insight severity for analytics engine
export type InsightSeverity = "CRITICAL" |"WARNING" |"INFO" |"SUGGESTION"

-- Diagnostic insight produced by the analytics engine
export type Insight = {
	Id: string,
	Severity: InsightSeverity,
	Subsystem: string,
	Title: string,
	Description: string,
	Metric: number?,
	Threshold: number?,
	Timestamp: number,
	RelatedIds: { string }?,
}

-- Animation tween descriptor
export type TweenSpec = {
	Property: string,
	Target: any,
	Duration: number,
	EasingStyle: Enum.EasingStyle?,
	EasingDirection: Enum.EasingDirection?,
	Delay: number?,
}

-- Glass Engine theme tokens
export type ThemeTokens = {
	-- Surfaces
	RootBG: Color3,
	GlassPrimary: Color3,
	GlassSecondary: Color3,
	GlassTertiary: Color3,
	GlassOverlay: Color3,
	CardBG: Color3,
	-- Borders
	BorderPrimary: Color3,
	BorderSubtle: Color3,
	BorderGlow: Color3,
	-- Semantic
	Accent: Color3,
	AccentDim: Color3,
	Success: Color3,
	Warning: Color3,
	Danger: Color3,
	Purple: Color3,
	Cyan: Color3,
	Orange: Color3,
	-- Text
	TextPrimary: Color3,
	TextSecondary: Color3,
	TextMuted: Color3,
	TextOnAccent: Color3,
	-- Radii
	RadiusLg: number,
	RadiusMd: number,
	RadiusSm: number,
	RadiusXs: number,
	-- Transparency
	GlassTransparency: number,
	OverlayTransparency: number,
}

-- Reactive store change event
export type StoreChange = {
	Key: string,
	OldValue: any,
	NewValue: any,
	Timestamp: number,
}

-- Breadcrumb entry for Z-axis nav
export type Breadcrumb = {
	LayerId: string,
	Label: string,
	Depth: number,
}

-- SubPane descriptor for recursive drill-down
export type SubPane = {
	Id: string,
	ParentId: string?,
	Title: string,
	DataKey: string?,
	DataValue: any?,
	Builder: ((frame: Frame, context: LayerContext) -> ())?,
	Children: { SubPane }?,
}

return nil
