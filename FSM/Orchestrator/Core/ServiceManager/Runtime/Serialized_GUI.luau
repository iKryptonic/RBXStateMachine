
--[[
	@description Generated UI construction script for ServiceManager.
	@return ()

	@note This file is auto-generated/serialized UI code and intentionally avoids strict typing.
]]

local function Create(className, properties)
	local instance = Instance.new(className)
	for propertyName, propertyValue in next, properties do
		if propertyName ~= "Parent" then
			instance[propertyName] = propertyValue
		end
	end
	if properties.Parent then
		instance.Parent = properties.Parent
	end
	return instance
end

local function Build()
	local ServiceManagerUI = Create("ScreenGui", {
		Name = "ServiceManagerUI",
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
	})

	local Main = Create("Frame", {
		Name = "Main",
		Size = UDim2.new(0, 980, 0, 640),
		Position = UDim2.new(0.5, -490, 0.5, -320),
		BorderSizePixel = 0,
		BackgroundColor3 = Color3.fromRGB(18, 18, 20),
		Parent = ServiceManagerUI,
	})

	Create("UICorner", { CornerRadius = UDim.new(0, 12), Parent = Main })
	Create("UIStroke", { Color = Color3.fromRGB(70, 70, 78), Transparency = 0.35, Parent = Main })
	Create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 24, 28)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(14, 14, 16)),
		}),
		Parent = Main,
	})

local Sidebar = Create("Frame", {
	Name = "Sidebar",
	ZIndex = 10,
	Size = UDim2.new(0, 96, 1, 0),
	BorderSizePixel = 0,
	BackgroundColor3 = Color3.fromRGB(16, 16, 18),
	Parent = Main,
})
Create("UICorner", { CornerRadius = UDim.new(0, 12), Parent = Sidebar })
Create("UIStroke", { Color = Color3.fromRGB(70, 70, 78), Transparency = 0.55, Parent = Sidebar })

Create("TextLabel", {
	Name = "Title",
	ZIndex = 100,
	AnchorPoint = Vector2.new(0, 0.5),
	Size = UDim2.new(1, 0, 0, 56),
	BackgroundTransparency = 1,
	Position = UDim2.new(0, 0, 0, 18),
	FontSize = Enum.FontSize.Size18,
	TextSize = 18,
	RichText = true,
	TextColor3 = Color3.fromRGB(120, 210, 255),
	Text = "<b>SM</b>",
	Font = Enum.Font.GothamBold,
	Parent = Sidebar,
})

local TabContainer = Create("Frame", {Name = "TabContainer", ZIndex = 12, Size = UDim2.new(1, 0, 1, -100), BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 70), Parent = Sidebar})

local function CreateTab(Name, Text, LayoutOrder)
	local Frame = Create("Frame", {Name = Name, ZIndex = 13, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 50, 0, 50), BackgroundTransparency = 1, Parent = TabContainer})
	if LayoutOrder then Frame.LayoutOrder = LayoutOrder end
	if Name == "CreateTask" then Frame.BackgroundColor3 = Color3.fromRGB(35, 35, 35) end
	
	local Btn = Create("TextButton", {Name = "Button", ZIndex = 14, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(1, 0, 1, 0), BorderSizePixel = 0, BackgroundColor3 = Color3.fromRGB(45, 45, 45), FontSize = Enum.FontSize.Size18, TextSize = 18, TextColor3 = Color3.fromRGB(150, 150, 150), Text = Text, Font = Enum.Font.GothamBold, Parent = Frame})
	Create("UICorner", {CornerRadius = UDim.new(0.5, 0), Parent = Btn})
	Create("UIPadding", {PaddingLeft = UDim.new(0, 15), PaddingRight = UDim.new(0, 15), Parent = Btn})
	Create("UIStroke", {Color = Color3.fromRGB(80, 80, 80), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = Btn})
	local Indicator = Create("Frame", {Name = "Indicator", ZIndex = 15, Size = UDim2.new(0.6, 0, 0, 3), Position = UDim2.new(0.2, 0, 1, -3), BorderSizePixel = 0, BackgroundColor3 = Color3.fromRGB(0, 200, 255), Visible = false, Parent = Frame})
	Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = Indicator})
	return Frame
end

CreateTab("TaskList", "T")
CreateTab("Performance", "P")
CreateTab("Console", "C")
CreateTab("FSMs", "F")
CreateTab("Visualize", "VIS")
CreateTab("Entities", "E")
CreateTab("Settings", "S")
CreateTab("Logs", "L")
CreateTab("History", "H")

Create("UIListLayout", {HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 15), Parent = TabContainer})
CreateTab("CreateTask", "N", 5)

local ModeToggle = Create("TextButton", {Name = "ModeToggle", AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.new(0, 66, 0, 26), Position = UDim2.new(0.5, 0, 1, -22), BorderSizePixel = 0, FontSize = Enum.FontSize.Size10, TextSize = 10, Text = "", Font = Enum.Font.GothamBold, Parent = Sidebar})
Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = ModeToggle})
Create("UIStroke", {ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 1.5, Parent = ModeToggle})

local ServiceToggle = Create("TextButton", {Name = "ServiceToggle", AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.new(0, 66, 0, 26), Position = UDim2.new(0.5, 0, 1, -56), BorderSizePixel = 0, FontSize = Enum.FontSize.Size10, TextSize = 10, Text = "TASKS", Font = Enum.Font.GothamBold, Parent = Sidebar})
Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = ServiceToggle})
Create("UIStroke", {ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 1.5, Parent = ServiceToggle})

Create("TextLabel", {Name = "PingIndicator", AnchorPoint = Vector2.new(0.5, 1), Size = UDim2.new(0.8, 0, 0, 20), BackgroundTransparency = 1, Position = UDim2.new(0.5, 0, 1, -80), FontSize = Enum.FontSize.Size10, TextSize = 10, RichText = true, TextColor3 = Color3.fromRGB(200, 200, 200), Text = "PING: --ms", Font = Enum.Font.Code, Parent = Sidebar})

Create("TextButton", {Name = "MinBtn", Text = "-", Size = UDim2.new(0, 20, 0, 20), Position = UDim2.new(1, -25, 0, 5), BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(200, 200, 200), Font = Enum.Font.GothamBold, TextSize = 18, Parent = Sidebar})

local Body = Create("Frame", {Name = "Body", Size = UDim2.new(1, -120, 1, -100), BackgroundTransparency = 1, Position = UDim2.new(0, 110, 0, 55), ClipsDescendants = true, Parent = Main})

-- Top bar (new, optional; does not affect existing lookups)
local TopBar = Create("Frame", {
	Name = "TopBar",
	Size = UDim2.new(1, -120, 0, 40),
	Position = UDim2.new(0, 110, 0, 10),
	BackgroundColor3 = Color3.fromRGB(16, 16, 18),
	BackgroundTransparency = 0.25,
	BorderSizePixel = 0,
	Parent = Main,
})
Create("UICorner", { CornerRadius = UDim.new(0, 10), Parent = TopBar })
Create("UIStroke", { Color = Color3.fromRGB(70, 70, 78), Transparency = 0.75, Parent = TopBar })
Create("TextLabel", {
	Name = "AppTitle",
	Size = UDim2.new(1, -20, 1, 0),
	Position = UDim2.new(0, 10, 0, 0),
	BackgroundTransparency = 1,
	Text = "Service Manager",
	TextColor3 = Color3.fromRGB(225, 225, 235),
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = TopBar,
})

local LoadingOverlay = Create("Frame", {Name = "LoadingOverlay", Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = Color3.fromRGB(10, 10, 10), BackgroundTransparency = 1, Visible = false, ZIndex = 50, Parent = Body})
Create("TextLabel", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "SYNCING...", TextColor3 = Color3.fromRGB(200, 200, 200), Font = Enum.Font.GothamBold, TextSize = 14, ZIndex = 51, Parent = LoadingOverlay})

local TaskListView = Create("Frame", {Name = "TaskListView", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local Container = Create("ScrollingFrame", {Name = "Container", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ScrollBarThickness = 2, Parent = TaskListView})
local TaskList1 = Create("Frame", {Name = "TaskList", Size = UDim2.new(0.35, 0, 1, 0), BackgroundTransparency = 1, Parent = Container})
Create("UIListLayout", {Padding = UDim.new(0, 10), Parent = TaskList1})

local function CreateSection(Name, TitleText, Color, Parent)
	local Section = Create("Frame", {Name = Name, Size = UDim2.new(1, 0, 0.5, -5), BackgroundColor3 = Color3.fromRGB(30, 30, 30), Parent = Parent})
	Create("UICorner", {Parent = Section})
	Create("TextLabel", {Name = "Title", Size = UDim2.new(1, -20, 0, 30), Position = UDim2.new(0, 10, 0, 0), BackgroundTransparency = 1, Text = TitleText, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = Color, TextXAlignment = Enum.TextXAlignment.Left, Parent = Section})
	local List = Create("ScrollingFrame", {Name = "List", Size = UDim2.new(1, 0, 1, -35), Position = UDim2.new(0, 0, 0, 35), BackgroundTransparency = 1, ScrollBarThickness = 2, Parent = Section})
	Create("UIListLayout", {Padding = UDim.new(0, 5), Parent = List})
	Create("UIPadding", {PaddingLeft = UDim.new(0, 5), Parent = List})
	return Section
end

CreateSection("ActiveSection", "ACTIVE TASKS", Color3.fromRGB(100, 255, 100), TaskList1)
CreateSection("ArchivedSection", "DEAD TASKS", Color3.fromRGB(255, 100, 100), TaskList1)

local TaskMetadata = Create("Frame", {Name = "TaskMetadata", Size = UDim2.new(0.65, -10, 1, 0), Position = UDim2.new(0.35, 10, 0, 0), BackgroundColor3 = Color3.fromRGB(30, 30, 30), Parent = Container})
Create("UICorner", {Parent = TaskMetadata})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10), Parent = TaskMetadata})

local FSMsView = Create("Frame", {Name = "FSMsView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local FSMContainer = Create("ScrollingFrame", {Name = "Container", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ScrollBarThickness = 2, Parent = FSMsView})
local StateMachineList = Create("Frame", {Name = "StateMachineList", Size = UDim2.new(0.35, 0, 1, 0), BackgroundTransparency = 1, Parent = FSMContainer})
Create("UIListLayout", {Padding = UDim.new(0, 10), Parent = StateMachineList})
local StateMachineMetadata = Create("Frame", {Name = "StateMachineMetadata", Size = UDim2.new(0.65, -10, 1, 0), Position = UDim2.new(0.35, 10, 0, 0), BackgroundColor3 = Color3.fromRGB(30, 30, 30), Parent = FSMContainer})
Create("UICorner", {Parent = StateMachineMetadata})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10), Parent = StateMachineMetadata})

local VisualizeView = Create("Frame", {Name = "VisualizeView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
Create("Frame", {Name = "GraphContainer", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = VisualizeView})

local EntitiesView = Create("Frame", {Name = "EntitiesView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local EntityContainer = Create("ScrollingFrame", {Name = "Container", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ScrollBarThickness = 2, Parent = EntitiesView})
local EntityList = Create("Frame", {Name = "EntityList", Size = UDim2.new(0.35, 0, 1, 0), BackgroundTransparency = 1, Parent = EntityContainer})
Create("UIListLayout", {Padding = UDim.new(0, 10), Parent = EntityList})
local EntityMetadata = Create("Frame", {Name = "EntityMetadata", Size = UDim2.new(0.65, -10, 1, 0), Position = UDim2.new(0.35, 10, 0, 0), BackgroundColor3 = Color3.fromRGB(30, 30, 30), Parent = EntityContainer})
Create("UICorner", {Parent = EntityMetadata})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10), Parent = EntityMetadata})

local PerformanceView = Create("Frame", {Name = "PerformanceView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local GlobalStats = Create("Frame", {Name = "GlobalStats", Size = UDim2.new(1, 0, 0, 100), Position = UDim2.new(0, 0, 0, 40), BackgroundColor3 = Color3.fromRGB(25, 25, 25), BorderSizePixel = 0, Parent = PerformanceView})
local StatsLabels = Create("Frame", {Name = "StatsLabels", Size = UDim2.new(0.25, 0, 1, 0), BackgroundTransparency = 1, Parent = GlobalStats})
Create("UIListLayout", {Parent = StatsLabels, Padding = UDim.new(0, 5), VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Left})
Create("UIPadding", {PaddingLeft = UDim.new(0, 10), Parent = StatsLabels})
Create("Frame", {Name = "GraphContainer", Size = UDim2.new(0.75, -10, 1, -10), Position = UDim2.new(0.25, 5, 0, 5), BackgroundColor3 = Color3.fromRGB(20, 20, 20), Parent = GlobalStats})

local Container1 = Create("ScrollingFrame", {Name = "Container", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 4, Parent = PerformanceView})
local TaskList2 = Create("Frame", {Name = "TaskList", Size = UDim2.new(0.35, -5, 1, -10), ClipsDescendants = true, BackgroundTransparency = 0.9, Position = UDim2.new(0, 5, 0, 5), BackgroundColor3 = Color3.fromRGB(30, 30, 30), Parent = Container1})
Create("UICorner", {Parent = TaskList2})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = TaskList2})
Create("UIPadding", {PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), Parent = TaskList2})

local TaskMetadata1 = Create("Frame", {Name = "TaskMetadata", Size = UDim2.new(0.6, -5, 1, -10), ClipsDescendants = true, BackgroundTransparency = 0.9, Position = UDim2.new(0.38, 0, 0, 5), BackgroundColor3 = Color3.fromRGB(30, 30, 30), Parent = Container1})
Create("UICorner", {Parent = TaskMetadata1})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = TaskMetadata1})
Create("UIPadding", {PaddingTop = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), Parent = TaskMetadata1})

local ConsoleView = Create("Frame", {Name = "ConsoleView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local Container2 = Create("Frame", {Name = "Container", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = ConsoleView})
local TextContainer = Create("ScrollingFrame", {Name = "TextContainer", Size = UDim2.new(1, -10, 1, -55), BackgroundTransparency = 0.1, Position = UDim2.new(0, 5, 0, 5), BorderSizePixel = 0, BackgroundColor3 = Color3.fromRGB(5, 5, 5), AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 4, Parent = Container2})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = TextContainer})
Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = TextContainer})
Create("UIPadding", {PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 15), Parent = TextContainer})

local ScanlineEffect = Create("Frame", {Name = "ScanlineEffect", ZIndex = 2, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = TextContainer})
Create("UIGradient", {Rotation = 90, Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 20, 20)), ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 0, 0)), ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 20, 20))}), Parent = ScanlineEffect})

local UserInput = Create("TextBox", {Name = "UserInput", ZIndex = 10, Size = UDim2.new(1, -10, 0, 35), Position = UDim2.new(0, 5, 1, -40), BackgroundColor3 = Color3.fromRGB(10, 10, 10), FontSize = Enum.FontSize.Size14, PlaceholderColor3 = Color3.fromRGB(0, 100, 40), TextSize = 14, TextColor3 = Color3.fromRGB(0, 255, 100), PlaceholderText = "user@rbx:~$", Text = "", Font = Enum.Font.RobotoMono, TextXAlignment = Enum.TextXAlignment.Left, Parent = Container2})
Create("UIStroke", {Color = Color3.fromRGB(80, 80, 80), Parent = UserInput})
Create("UIPadding", {PaddingLeft = UDim.new(0, 10), Parent = UserInput})
Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = UserInput})

local SettingsView = Create("Frame", {Name = "SettingsView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local Container3 = Create("ScrollingFrame", {Name = "Container", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ScrollBarThickness = 2, Parent = SettingsView})
Create("UIListLayout", {Padding = UDim.new(0, 5), Parent = Container3})

local LogsView = Create("Frame", {Name = "LogsView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local LogsContainer = Create("ScrollingFrame", {Name = "Container", Size = UDim2.new(1, 0, 1, -40), Position = UDim2.new(0, 0, 0, 40), BackgroundTransparency = 1, ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(0,0,0,0), Parent = LogsView})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = LogsContainer})

local HistoryView = Create("Frame", {Name = "HistoryView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local HistoryContainer = Create("ScrollingFrame", {Name = "Container", Size = UDim2.new(1, 0, 1, -85), Position = UDim2.new(0, 0, 0, 40), BackgroundTransparency = 1, ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(0,0,0,0), Parent = HistoryView})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5), Parent = HistoryContainer})

local HistoryControls = Create("Frame", {Name = "Controls", Size = UDim2.new(1, 0, 0, 35), Position = UDim2.new(0, 0, 1, -35), BackgroundTransparency = 1, Parent = HistoryView})
Create("TextLabel", {Name = "PageLabel", Size = UDim2.new(0, 100, 1, 0), Position = UDim2.new(0.5, -50, 0, 0), BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(200, 200, 200), Text = "1 / 1", Font = Enum.Font.GothamBold, TextSize = 14, Parent = HistoryControls})

local function CreateNavBtn(buttonName, buttonText, buttonPosition)
	local button = Create("TextButton", {Name = buttonName, Text = buttonText, Size = UDim2.new(0, 30, 1, 0), Position = buttonPosition, BackgroundColor3 = Color3.fromRGB(40,40,40), TextColor3 = Color3.new(1,1,1), Font = Enum.Font.GothamBold, TextSize = 14, Parent = HistoryControls})
	Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = button})
end
CreateNavBtn("Prev", "<", UDim2.new(0.5, -90, 0, 0))
CreateNavBtn("Next", ">", UDim2.new(0.5, 60, 0, 0))

local HistoryDetails = Create("Frame", {Name = "Details", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = HistoryView})
local HistoryDetailsBack = Create("TextButton", {Name = "Back", Size = UDim2.new(0, 80, 0, 30), BackgroundColor3 = Color3.fromRGB(45, 45, 45), Text = "< BACK", TextColor3 = Color3.fromRGB(200, 200, 200), Font = Enum.Font.GothamBold, TextSize = 14, Parent = HistoryDetails})
Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = HistoryDetailsBack})
local HistoryDetailsContent = Create("ScrollingFrame", {Name = "Content", Size = UDim2.new(1, 0, 1, -40), Position = UDim2.new(0, 0, 0, 40), BackgroundTransparency = 1, ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(0,0,0,0), Parent = HistoryDetails})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5), Parent = HistoryDetailsContent})

local CreateTaskView = Create("Frame", {Name = "CreateTaskView", Visible = false, Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Parent = Body})
local CreateTaskContainer = Create("ScrollingFrame", {Name = "Container", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 2, Parent = CreateTaskView})

Create("UIListLayout", {Padding = UDim.new(0, 10), Parent = CreateTaskContainer})

local function CreateInput(Name, Placeholder)
	local box = Create("TextBox", {Name = Name, PlaceholderText = Placeholder, Text = "", BackgroundColor3 = Color3.fromRGB(30, 30, 30), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 14, Size = UDim2.new(1, 0, 0, 40), Parent = CreateTaskContainer})
	Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = box})
end

CreateInput("TaskName", "Task Name (e.g. MyWorker)")
CreateInput("Delay", "Delay (seconds)")
CreateInput("Output", "Output Message")

Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = Create("TextButton", {Name = "RecurringToggle", Text = "Recurring: OFF", BackgroundColor3 = Color3.fromRGB(255, 120, 120), Size = UDim2.new(1, 0, 0, 30), Parent = CreateTaskContainer})})
Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = Create("TextButton", {Name = "PriorityToggle", Text = "Priority: 1", BackgroundColor3 = Color3.fromRGB(40, 40, 40), TextColor3 = Color3.new(1, 1, 1), Size = UDim2.new(1, 0, 0, 30), Parent = CreateTaskContainer})})
Create("UICorner", {CornerRadius = UDim.new(0, 6), Parent = Create("TextButton", {Name = "EventToggle", Text = "Event: Heartbeat", BackgroundColor3 = Color3.fromRGB(40, 40, 40), TextColor3 = Color3.new(1, 1, 1), Size = UDim2.new(1, 0, 0, 30), Parent = CreateTaskContainer})})
Create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = Create("TextButton", {Name = "Submit", Text = "SCHEDULE TASK", BackgroundColor3 = Color3.fromRGB(0, 200, 255), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 16, Size = UDim2.new(1, 0, 0, 50), Parent = CreateTaskContainer})})

local BottomBar = Create("Frame", {Name = "BottomBar", Size = UDim2.new(1, -120, 0, 34), Position = UDim2.new(0, 110, 1, -38), BorderSizePixel = 0, BackgroundColor3 = Color3.fromRGB(16, 16, 18), Parent = Main})
Create("UIPadding", {PaddingLeft = UDim.new(0, 15), Parent = BottomBar})
Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 30), Parent = BottomBar})

local function CreateBottomLabel(labelName)
	local label = Create("TextLabel", {Name = labelName, AutomaticSize = Enum.AutomaticSize.XY, BackgroundTransparency = 1, FontSize = Enum.FontSize.Size14, TextSize = 14, RichText = true, TextColor3 = Color3.fromRGB(180, 180, 180), Font = Enum.Font.Code, TextXAlignment = Enum.TextXAlignment.Left, Parent = BottomBar})
	Create("UIPadding", {PaddingRight = UDim.new(0, 10), Parent = label})
end
CreateBottomLabel("ServerTick")
CreateBottomLabel("ServerTime")
CreateBottomLabel("TaskCount")
CreateBottomLabel("TaskQueue")
CreateBottomLabel("UserInfo")

local References = Create("Folder", {Name = "References", Parent = Main})

local TaskCardReference = Create("TextButton", {Name = "TaskCardReference", Visible = false, Size = UDim2.new(0.95, 0, 0, 40), BackgroundColor3 = Color3.fromRGB(45, 45, 45), FontSize = Enum.FontSize.Size18, TextSize = 16, RichText = true, TextColor3 = Color3.fromRGB(230, 230, 230), Text = "", Font = Enum.Font.Gotham, Parent = References})
Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = TaskCardReference})
Create("TextLabel", {Size = UDim2.new(1, -10, 1, 0), BackgroundTransparency = 1, Position = UDim2.new(0, 5, 0, 0), FontSize = Enum.FontSize.Size12, TextSize = 12, RichText = true, TextColor3 = Color3.fromRGB(230, 230, 230), Text = "", TextXAlignment = Enum.TextXAlignment.Left, Parent = TaskCardReference})

Create("TextLabel", {Name = "ConsoleLineReference", Visible = false, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, -20, 0, 20), BackgroundTransparency = 1, FontSize = Enum.FontSize.Size14, TextSize = 14, RichText = true, TextColor3 = Color3.fromRGB(200, 200, 200), TextYAlignment = Enum.TextYAlignment.Top, Text = "", TextWrapped = true, Font = Enum.Font.RobotoMono, TextXAlignment = Enum.TextXAlignment.Left, LineHeight = 1.2, Parent = References})
Create("TextLabel", {Name = "LogLineReference", Visible = false, Size = UDim2.new(1, -10, 0, 20), BackgroundTransparency = 1, FontSize = Enum.FontSize.Size12, TextSize = 12, RichText = true, Text = "", Font = Enum.Font.Code, TextXAlignment = Enum.TextXAlignment.Left, Parent = References})

local SettingReference = Create("Frame", {Name = "SettingReference", Visible = false, Size = UDim2.new(1, -10, 0, 45), BackgroundColor3 = Color3.fromRGB(40, 40, 40), Parent = References})
Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = SettingReference})
Create("TextLabel", {Name = "Title", Size = UDim2.new(0.6, -10, 1, 0), BackgroundTransparency = 1, Position = UDim2.new(0, 10, 0, 0), FontSize = Enum.FontSize.Size24, TextSize = 20, RichText = true, TextColor3 = Color3.fromRGB(200, 200, 200), Text = "", Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, Parent = SettingReference})
local boolToggleButton = Create("TextButton", {Name = "Bool", Visible = false, Size = UDim2.new(0.3, 0, 0.7, 0), Position = UDim2.new(0.7, -5, 0.15, 0), BackgroundColor3 = Color3.fromRGB(60, 60, 60), FontSize = Enum.FontSize.Size18, TextSize = 15, RichText = true, TextColor3 = Color3.fromRGB(255, 255, 255), Text = "", Font = Enum.Font.GothamMedium, Parent = SettingReference})
Create("UICorner", {Parent = boolToggleButton})
local textValueBox = Create("TextBox", {Name = "Text", Visible = false, Size = UDim2.new(0.3, 0, 0.7, 0), Position = UDim2.new(0.7, -5, 0.15, 0), BackgroundColor3 = Color3.fromRGB(20, 20, 20), FontSize = Enum.FontSize.Size18, TextSize = 16, RichText = true, TextColor3 = Color3.fromRGB(0, 255, 255), Text = "", Font = Enum.Font.Code, Parent = SettingReference})
Create("UICorner", {Parent = textValueBox})

local TaskDataReference = Create("Frame", {Name = "TaskDataReference", Visible = false, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, -10, 0, 0), BackgroundTransparency = 0.5, BorderSizePixel = 0, BackgroundColor3 = Color3.fromRGB(30, 30, 30), Parent = References})
Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2), Parent = TaskDataReference})
Create("UIPadding", {PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = TaskDataReference})
Create("TextLabel", {Name = "Title", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 15), BackgroundTransparency = 1, FontSize = Enum.FontSize.Size11, TextSize = 11, RichText = true, TextColor3 = Color3.fromRGB(150, 150, 150), Text = "", Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, Parent = TaskDataReference})
Create("TextLabel", {Name = "Value", LayoutOrder = 2, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1, FontSize = Enum.FontSize.Size14, TextSize = 14, RichText = true, TextColor3 = Color3.fromRGB(255, 255, 255), Text = "", TextWrapped = true, TextWrap = true, Font = Enum.Font.Code, TextXAlignment = Enum.TextXAlignment.Left, Parent = TaskDataReference})
Create("UIStroke", {Color = Color3.fromRGB(255, 255, 255), ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Transparency = 0.5, Parent = TaskDataReference})
Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = TaskDataReference})

	local refs = {
		ScreenGui = ServiceManagerUI,
		Main = Main,
		Sidebar = Sidebar,
		BottomBar = BottomBar,
		Body = Body,
		TabContainer = TabContainer,
		Title = Sidebar:WaitForChild("Title"),
		References = References,
	}

	return ServiceManagerUI, refs
end

return {
	Build = Build,
}
