--[[
    ServiceManager.lua
    @Author: ikrypto
    @Date: 01-27-2026
    @Version: 1.0
    @Description: Generalized manager for monitoring Tasks and FSMs.
]]

-- Owner (client-only)
local Players = game:GetService("Players")
local Owner = Players.LocalPlayer
if not Owner then
	error("[ServiceManager] This module must run on the client (LocalPlayer required).")
end

-- Services
local _RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local _CollectionService = game:GetService("CollectionService")

-- ScreenGui
local RunTimeFolder = script:WaitForChild("Runtime")
local PagesFolder = RunTimeFolder:WaitForChild("Pages")

-- RunTimeFolder
local GuiProvider = require(RunTimeFolder:WaitForChild("GuiProvider") :: any)
local TemplatesModule = require(RunTimeFolder:WaitForChild("Templates") :: any)
local SidecarModule = require(RunTimeFolder:WaitForChild("Sidecar") :: any)

local NetworkRuntime = require(RunTimeFolder:WaitForChild("Network") :: any)
local ServiceProxyRuntime = require(RunTimeFolder:WaitForChild("ServiceProxy") :: any)

-- PagesFolder
-- DEPRECATED: Legacy page controllers retained for regression testing.
-- New FSM/Entity pattern: see FSM/*PageFSM.luau and Entity/*PageEntity.luau
-- These will be invoked only as fallback when FSM/Entity pages are unavailable.
local ConsolePage = require(PagesFolder:WaitForChild("ConsolePage") :: any)
local SettingsPage = require(PagesFolder:WaitForChild("SettingsPage") :: any)
local LogsPage = require(PagesFolder:WaitForChild("LogsPage") :: any)
local HistoryPage = require(PagesFolder:WaitForChild("HistoryPage") :: any)
local TaskListPage = require(PagesFolder:WaitForChild("TaskListPage") :: any)
local FSMsPage = require(PagesFolder:WaitForChild("FSMsPage") :: any)
local VisualizePage = require(PagesFolder:WaitForChild("VisualizePage") :: any)
local EntitiesPage = require(PagesFolder:WaitForChild("EntitiesPage") :: any)
local CreateTaskPage = require(PagesFolder:WaitForChild("CreateTaskPage") :: any)
local PerformancePage = require(PagesFolder:WaitForChild("PerformancePage") :: any)

local guiRefs = GuiProvider.GetOrCreate(script.Parent)
local MainGui = guiRefs.Main

-- Professional Color Palette
local COLORS = {
	["Success"] = Color3.fromRGB(160, 255, 160),
	["Warning"] = Color3.fromRGB(255, 220, 140),
	["Error"]   = Color3.fromRGB(255, 120, 120),
	["Default"] = Color3.fromRGB(220, 220, 220),
	["Prompt"]  = Color3.fromRGB(0, 255, 100),
	["Accent"]  = Color3.fromRGB(0, 200, 255),
	["DarkBG"]  = Color3.fromRGB(40, 40, 40),
	["RootBG"]  = Color3.fromRGB(25, 25, 25),
	["PanelBG"] = Color3.fromRGB(30, 30, 30),
	["SideBG"]  = Color3.fromRGB(20, 20, 20),
	["InputBG"] = Color3.fromRGB(10, 10, 10),
	["Stroke"]  = Color3.fromRGB(80, 80, 80)
}

-- ServiceManager Structure
local ServiceManager = {
	GUI = {
		["MainFrame"] = MainGui,
		["SidebarContainer"] = guiRefs.Sidebar,
		["BottomBarContainer"] = guiRefs.BottomBar,
		["BodyContainer"] = guiRefs.Body,
		["TabContainer"] = guiRefs.TabContainer,
		["Title"] = guiRefs.Title,
		["References"] = guiRefs.References,
	}

	Services = {
		Scheduler = nil,
		FSM = nil,
	}

	ServerData = {
		Scheduler = {
			Tasks = {},
			PerformanceManager = {
				GetTaskAverage = function(self, name)
					if self.Stats and self.Stats[name] then return self.Stats[name].Average end
					local task = self.Tasks and self.Tasks[name]
					return (task and task.RunCount and task.RunCount > 0) and (task.TotalRunTime / task.RunCount) or 0
				end,
				GetTaskMaximum = function(self, name)
					if self.Stats and self.Stats[name] then return self.Stats[name].MaxRunTime end
					local task = self.Tasks and self.Tasks[name]
					return task and task.MaxRunTime or 0
				end,
				GetDelayedExecutionCount = function() return 0 end,
				Stats = {},
			},
			Settings = {},
			Logger = { History = {} },
			History = {},
			LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 },
		},
		FSM = {
			StateMachines = {},
			Entities = {},
			Settings = {},
			History = {},
			Logs = { History = {} },
		}
	}

	ArchivedTasks = {}
	ArchivedFSMs = {}
	ArchivedEntities = {}
	LastClientTasks = {}
	LastEntities = {}

	ActiveService = "Scheduler",
	ActivePage = nil,
	Mode = 'client',
	RefreshRate = 0.1, 
	LastUpdate = 0,
	IsFetching = false,
	Ping = nil,
	Network = { Failures = 0, CircuitOpenUntil = 0, IsDisconnected = false, LastError = nil },
	ReplicationMode = "poll",
	HasInitialSync = false,

	-- Metadata Cache to preserve FSM structure across stateMachines of the same name
	FSMMetadataCache = {} :: { [string]: { Graph: any?, ValidStates: any? } }
}

local Templates = TemplatesModule.new(ServiceManager.GUI.References)
local ObjectReferences = {
	-- NOTE: keep these as templates; code clones them per-use.
	TaskCardReference = Templates.TaskCardReference,
	TaskDataReference = Templates.TaskDataReference,
	SettingReference = Templates.SettingReference,
	LogLineReference = Templates.LogLineReference,
	ConsoleLineReference = Templates.ConsoleLineReference,
}

-- Sidecar: typed, UI-agnostic developer helpers.
ServiceManager.Sidecar = SidecarModule.new()

-- Back-compat convenience wrappers (additive; does not change existing behavior)

--[[
	@description Returns the Orchestrator module reference from the Sidecar.
	@return any? -- The Orchestrator module, or nil if unavailable.
]]
function ServiceManager:GetOrchestrator()
	return (self.Sidecar :: any):GetOrchestrator()
end

--[[
	@description Returns the Factory module reference from the Sidecar.
	@return any? -- The Factory module, or nil if unavailable.
]]
function ServiceManager:GetFactory()
	return (self.Sidecar :: any):GetFactory()
end

--[[
	@description Forwards a named request to the Sidecar's Request handler.
	@param requestName string -- The name of the request to invoke.
	@param ... any -- Variadic arguments passed through to the request handler.
	@return any -- The result from the Sidecar request.
]]
function ServiceManager:Request(requestName: string, ...: any)
	return (self.Sidecar :: any):Request(requestName, ...)
end

--[[
	@description Returns the latest server sync payload from the Sidecar.
	@return table? -- The server sync data table, or nil if not connected.
]]
function ServiceManager:GetServerSyncData()
	return (self.Sidecar :: any):GetServerSyncData()
end

--[[
	@description Creates a new entity via the Factory through the Sidecar.
	@param classOrName any -- The entity class or registered name to instantiate.
	@param params { EntityId: string?, Context: { [any]: any } } -- Creation parameters including optional ID and context.
	@return any -- The newly created entity instance.
]]
function ServiceManager:CreateEntityFromFactory(classOrName: any, params: { EntityId: string?, Context: { [any]: any } })
	return (self.Sidecar :: any):CreateEntity(classOrName, params)
end

--[[
	@description Creates a new state machine via the Factory through the Sidecar.
	@param classOrName any -- The FSM class or registered name to instantiate.
	@param params { StateMachineId: string?, Context: { [any]: any }? } -- Creation parameters including optional ID and context.
	@return any -- The newly created state machine instance.
]]
function ServiceManager:CreateStateMachineFromFactory(classOrName: any, params: { StateMachineId: string?, Context: { [any]: any }? })
	return (self.Sidecar :: any):CreateStateMachine(classOrName, params)
end

-- Developer sidecar surface area (read-only-ish convenience).
do
	local ok, orchestratorOrErr = pcall(function()
		local orchestratorModule = RS:FindFirstChild("Orchestrator")
		return orchestratorModule and require(orchestratorModule :: any) or nil
	end)
	local Orchestrator = (ok and orchestratorOrErr) or nil

	ServiceManager.Dev = {
		Owner = Owner,
		Gui = guiRefs,
		Templates = Templates,
		Sidecar = ServiceManager.Sidecar,
		Orchestrator = Orchestrator,
		-- Convenience access to Factory registries (available after Orchestrator:RegisterComponents())
		Factory = (shared.fsm and shared.fsm.Factory) or (Orchestrator and Orchestrator.Factory) or nil,
		-- Client-side mirrors for quick inspection
		GetClientSnapshot = function()
			return {
				Scheduler = shared.fsm and shared.fsm.Scheduler,
				StateMachines = shared.fsm and shared.fsm.StateMachines,
				Entities = shared.fsm and shared.fsm.Entities,
				History = shared.fsm and shared.fsm.History,
				Logs = shared.fsm and shared.fsm.Logs,
			}
		end,
	}
end

--[[
	@description Creates a new Roblox Instance and applies the given property dictionary.
	Parent is applied last to avoid premature replication.
	@param className string -- The class name of the Instance to create.
	@param properties { [string]: any } -- A dictionary of property names to values.
	@return Instance -- The newly created and configured Instance.
]]
local function Create(className: string, properties: { [string]: any }): Instance
	local instance = Instance.new(className)
	for propertyName, propertyValue in pairs(properties) do
		if propertyName ~= "Parent" then
			(instance :: any)[propertyName] = propertyValue
		end
	end
	if properties.Parent then instance.Parent = properties.Parent end
	return instance
end

--[[
	@description Creates and plays a Quad-Out tween on the given Instance.
	@param instance Instance -- The Instance to tween.
	@param tweenProperties { [string]: any } -- Property goals for the tween.
	@param durationSeconds number? -- Duration in seconds (default 0.18).
	@return Tween -- The playing Tween object.
]]
local function Tween(instance: Instance, tweenProperties: { [string]: any }, durationSeconds: number?): Tween
	local info = TweenInfo.new(durationSeconds or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(instance, info, tweenProperties)
	tween:Play()
	return tween
end

--[[
	@description Shows or hides the loading overlay in the body container.
	Used during context-switch transitions to mask stale data.
	@param this any -- ServiceManager instance.
	@param visible boolean -- Whether the overlay should be visible.
	@param text string? -- Optional status message to display.
	@return ()
]]
local function SetLoadingOverlay(this: any, visible: boolean, text: string?)
	local overlay = this and this.GUI and this.GUI.BodyContainer and this.GUI.BodyContainer:FindFirstChild("LoadingOverlay")
	if not overlay then
		return
	end
	local overlayAny = overlay :: any
	overlayAny.Visible = visible
	if text then
		local label = overlay:FindFirstChildWhichIsA("TextLabel", true)
		if label and label:IsA("TextLabel") then
			(label :: any).Text = text
		end
	end
	-- Keep styling consistent with SyncPoll's overlay (it tweens transparency).
	if visible then
		overlayAny.BackgroundTransparency = 0.2
	else
		overlayAny.BackgroundTransparency = 1
	end
end

--[[
	@description Disconnects all RBXScriptConnections in the given array and nils each slot.
	@param connections { RBXScriptConnection }? -- Array of connections to clear.
	@return ()
]]
function ServiceManager:ClearConnections(connections: { RBXScriptConnection }?)
	if not connections then return end
	for i, conn in next, connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
		connections[i] = nil
	end
end

--[[
	@description Ensures a horizontal toolbar Frame exists at the top of the given view.
	Creates one if it does not already exist.
	@param view Instance -- The parent view container.
	@return Frame -- The existing or newly created toolbar.
]]
local function EnsureToolbar(view: Instance): Frame
	local toolbar = view:FindFirstChild("Toolbar")
	if not toolbar then
		toolbar = Create("Frame", {Name="Toolbar", Size=UDim2.new(1,0,0,35), BackgroundTransparency=1, Parent=view})
		local layout = Instance.new("UIListLayout", toolbar); layout.FillDirection = Enum.FillDirection.Horizontal; layout.Padding = UDim.new(0, 5)
	end
	return toolbar
end

--[[
	@description Creates a debounced search TextBox inside the given parent.
	Returns the existing one if already present.
	@param parent Instance -- Parent container (typically a toolbar).
	@param initialText string? -- Pre-filled search text.
	@param callback (text: string) -> () -- Debounced callback fired on text change.
	@return TextBox -- The search input element.
]]
local function CreateSearchBox(parent: Instance, initialText: string?, callback: (string) -> ()): TextBox
	if parent:FindFirstChild("Search") then return (parent :: any).Search end
	local search = Create("TextBox", {
		Name="Search", Size=UDim2.new(0,120,1,0), BackgroundColor3=Color3.fromRGB(30,30,30), TextColor3=Color3.new(1,1,1),
		Font=Enum.Font.Gotham, TextSize=12, PlaceholderText="Search...", Text=initialText or "", Parent=parent
	})
	Create("UICorner", {CornerRadius=UDim.new(0,4), Parent=search})
	Create("UIPadding", {PaddingLeft=UDim.new(0,8), Parent=search})
	local debounceToken = 0
	search:GetPropertyChangedSignal("Text"):Connect(function()
		debounceToken += 1
		local token = debounceToken
		task.delay(0.15, function()
			if token == debounceToken then
				callback(search.Text)
			end
		end)
	end)
	return search
end

--[[
	@description Creates a styled TextButton with optional click callback.
	@param parent Instance -- Parent container.
	@param text string -- Button label text.
	@param color Color3? -- Background color (defaults to DarkBG).
	@param callback (() -> ())? -- Optional click handler.
	@param width number? -- Button width in pixels (default 90).
	@return TextButton -- The created button.
]]
local function CreateButton(parent: Instance, text: string, color: Color3?, callback: (() -> ())?, width: number?): TextButton
	local btn = Create("TextButton", {
		Text=text, Size=UDim2.new(0,width or 90,1,0), BackgroundColor3=color or COLORS.DarkBG,
		TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=10, Parent=parent
	})
	Create("UICorner", {CornerRadius=UDim.new(0,4), Parent=btn})
	if callback then btn.MouseButton1Click:Connect(callback) end
	return btn
end

--[[
	@description Ensures pagination controls (Prev/Next buttons + page label) exist in the view.
	@param view Instance -- The parent view container.
	@param constants { Page: number, [string]: any } -- Shared state table containing `Page` index.
	@param updateFunc () -> () -- Callback invoked when page changes.
	@return Frame -- The controls container.
]]
local function EnsurePagination(view: Instance, constants: { Page: number }, updateFunc: () -> ()): Frame
	local controls = view:FindFirstChild("Controls")
	if not controls then
		controls = Create("Frame", {Name="Controls", Size=UDim2.new(0.35, -5, 0, 30), Position=UDim2.new(0, 5, 1, -35), BackgroundTransparency=1, Parent=view})
		local _pageLabel = Create("TextLabel", {Name="PageLabel", Size=UDim2.new(0, 80, 1, 0), Position=UDim2.new(0.5, -40, 0, 0), BackgroundTransparency=1, TextColor3=Color3.fromRGB(200, 200, 200), Text="1 / 1", Font=Enum.Font.GothamBold, TextSize=12, Parent=controls})

		local function makeBtn(name, text, pos, delta)
			CreateButton(controls, text, Color3.fromRGB(40, 40, 40), function()
				constants.Page = math.max(1, constants.Page + delta)
				updateFunc()
			end, 30).Position = pos
		end
		makeBtn("Prev", "<", UDim2.new(0.5, -80, 0, 0), -1)
		makeBtn("Next", ">", UDim2.new(0.5, 50, 0, 0), 1)
	end
	return controls
end

--[[
	@description Ensures the toast notification container exists in the main frame.
	@return Frame -- The toast container.
]]
local function CreateToastContainer(): Frame
	local container = ServiceManager.GUI.MainFrame:FindFirstChild("ToastContainer")
	if not container then
		container = Create("Frame", {
			Name="ToastContainer", Size=UDim2.new(0, 250, 1, -20), Position=UDim2.new(1, -260, 0, 10),
			BackgroundTransparency=1, Parent=ServiceManager.GUI.MainFrame
		})
		local layout = Instance.new("UIListLayout", container); layout.Padding = UDim.new(0, 5); layout.VerticalAlignment = Enum.VerticalAlignment.Bottom; layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	end
	return container
end

--[[
	@description Escapes XML/HTML special characters for Roblox RichText rendering.
	@param text string -- Raw text to sanitize.
	@return string -- Escaped text safe for RichText labels.
]]
local function EscapeRichText(text: string): string
	text = tostring(text)
	text = text:gsub("&", "&amp;")
	text = text:gsub("<", "&lt;")
	text = text:gsub(">", "&gt;")
	return text
end

--[[
	@description Converts a Color3 to a "R,G,B" string key for theme lookup.
	@param color Color3 -- The color to convert.
	@return string -- Comma-separated RGB string (e.g. "25,25,25").
]]
local function ColorKey(color: Color3): string
	return string.format("%d,%d,%d",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

--[[
	@description Displays a temporary toast notification at the bottom of the ServiceManager UI.
	Creates an animated frame that slides in, holds for 2 seconds, then fades out and self-destructs.
	@param Message string -- The text to display in the toast.
	@param Type string? -- Toast style: "Success", "Warning", "Error", or nil for accent color.
]]
function ServiceManager:Toast(Message, Type)
	local Container = CreateToastContainer()
	local Color = (Type == "Success" and COLORS.Success) or (Type == "Warning" and COLORS.Warning) or (Type == "Error" and COLORS.Error) or COLORS.Accent

	local Toast = Create("Frame", {
		Name="Toast", Size=UDim2.new(0, 0, 0, 30), BackgroundColor3=Color3.fromRGB(30, 30, 30),
		Parent=Container, BackgroundTransparency=0.1
	})
	Create("UICorner", {CornerRadius=UDim.new(0, 6), Parent=Toast})
	Create("UIStroke", {Color=Color, Transparency=0.5, Parent=Toast})

	local Label = Create("TextLabel", {
		Size=UDim2.new(0, 0, 1, 0), Position=UDim2.new(0, 10, 0, 0), BackgroundTransparency=1,
		Text=Message, TextColor3=Color3.new(1,1,1), Font=Enum.Font.GothamBold, TextSize=12,
		TextXAlignment=Enum.TextXAlignment.Left, Parent=Toast
	})

	-- Animate
	local TextSize = game:GetService("TextService"):GetTextSize(Message, 12, Enum.Font.GothamBold, Vector2.new(230, 30))
	local TargetWidth = math.max(100, TextSize.X + 20)
	Label.Size = UDim2.new(1, -10, 1, 0)

	Toast:TweenSize(UDim2.new(0, TargetWidth, 0, 30), "Out", "Quad", 0.3, true)

	task.delay(3, function()
		if Toast and Toast.Parent then
			Tween(Toast, {BackgroundTransparency=1, Size=UDim2.new(0, TargetWidth, 0, 0)}, 0.3)
			Tween(Label, {TextTransparency=1}, 0.3)
			task.wait(0.3)
			Toast:Destroy()
		end
	end)
end

--------------------------------------------------------------------------------
-- METADATA: BOTTOM BAR
--------------------------------------------------------------------------------
-- Defines the behavior and update logic for the bottom status bar elements.
local BottomBarMetadata = {
	["ServerTick"] = (function()
		local lastTime = os.clock()
		return {
			UpdateFunction = function(this)
				local now = os.clock()
				local dt = now - lastTime
				lastTime = now
				local ServerTick = dt > 0 and math.round(1 / dt) or 0
				this.ObjectReference.Text = string.format("<font color='#888888'>[TICK]</font> <font color='#A0FFA0'>%d</font>", ServerTick)
			end,
			ObjectReference = ServiceManager.GUI.BottomBarContainer:FindFirstChild("ServerTick"),
		}
	end)(),
	["ServerTime"] = {
		UpdateFunction = function(this)
			local ServerTime = os.date("%I:%M:%S %p")
			this.ObjectReference.Text = string.format("<font color='#888888'>[TIME]</font> %s", ServerTime)
		end,
		ObjectReference = ServiceManager.GUI.BottomBarContainer:FindFirstChild("ServerTime")
	},
	["TaskCount"] = {
		UpdateFunction = function(this)
			local service = ServiceManager.Services[ServiceManager.ActiveService]
			if not service then return end

			local items = (ServiceManager.ActiveService == "Scheduler") and service.Tasks or service.StateMachines
			if not items then return end

			local count = 0; for _ in next, items do count += 1 end
			local label = (ServiceManager.ActiveService == "Scheduler") and "[TASKS]" or "[JOBS]"
			this.ObjectReference.Text = string.format("<font color='#888888'>%s</font> %d", label, count)
		end,
		ObjectReference = ServiceManager.GUI.BottomBarContainer:FindFirstChild("TaskCount")
	},
	["TaskQueue"] = {
		UpdateFunction = function(this)
			if ServiceManager.ActiveService ~= "Scheduler" then
				this.ObjectReference.Text = ""
				return
			end
			local scheduler = ServiceManager.Services.Scheduler
			if not scheduler or ServiceManager.Mode ~= 'client' then return end
			local TaskQueue = scheduler.PerformanceManager:GetActiveTasks()
			local Count = 0; for _ in next, TaskQueue do Count += 1 end
			this.ObjectReference.Text = string.format("<font color='#888888'>[RUNNING]</font> %d", Count)
		end,
		ObjectReference = ServiceManager.GUI.BottomBarContainer:FindFirstChild("TaskQueue")
	},
	["UserInfo"] = {
		UpdateFunction = function(this)
			this.ObjectReference.Text = string.format("<font color='#888888'>[USER]</font> %s", Owner.Name:lower())
		end,
		ObjectReference = ServiceManager.GUI.BottomBarContainer:FindFirstChild("UserInfo")
	}
}

--------------------------------------------------------------------------------
-- PAGE DEFINITIONS
--------------------------------------------------------------------------------
-- Contains the logic, state, and update functions for each UI page (tab).

local Pages = {
	["TaskList"] = TaskListPage.Create(ServiceManager, {
		EnsureToolbar = EnsureToolbar,
		CreateSearchBox = CreateSearchBox,
		CreateButton = CreateButton,
		Create = Create,
		COLORS = COLORS,
		TaskCardReference = ObjectReferences.TaskCardReference,
		TaskDataReference = ObjectReferences.TaskDataReference,
	}),

	["FSMs"] = FSMsPage.Create(ServiceManager, {
		EnsureToolbar = EnsureToolbar,
		CreateSearchBox = CreateSearchBox,
		CreateButton = CreateButton,
		EnsurePagination = EnsurePagination,
		Create = Create,
		COLORS = COLORS,
		TaskCardReference = ObjectReferences.TaskCardReference,
		TaskDataReference = ObjectReferences.TaskDataReference,
	}),

	["Visualize"] = VisualizePage.Create(ServiceManager, { COLORS = COLORS }),

	["Entities"] = EntitiesPage.Create(ServiceManager, {
		EnsureToolbar = EnsureToolbar,
		CreateSearchBox = CreateSearchBox,
		CreateButton = CreateButton,
		EnsurePagination = EnsurePagination,
		Create = Create,
		COLORS = COLORS,
		TaskCardReference = ObjectReferences.TaskCardReference,
		TaskDataReference = ObjectReferences.TaskDataReference,
	}),

	["CreateTask"] = CreateTaskPage.Create(ServiceManager),

	["Performance"] = PerformancePage.Create(ServiceManager, {
		EnsureToolbar = EnsureToolbar,
		CreateSearchBox = CreateSearchBox,
		CreateButton = CreateButton,
		EnsurePagination = EnsurePagination,
		COLORS = COLORS,
		TaskCardReference = ObjectReferences.TaskCardReference,
		TaskDataReference = ObjectReferences.TaskDataReference,
	}),

	["Console"] = ConsolePage.Create(ServiceManager, { EscapeRichText = EscapeRichText, COLORS = COLORS }),

	["Settings"] = SettingsPage.Create(ServiceManager, { SettingReference = ObjectReferences.SettingReference }),

	["Logs"] = LogsPage.Create(ServiceManager, {
		EnsureToolbar = EnsureToolbar,
		CreateSearchBox = CreateSearchBox,
		CreateButton = CreateButton,
		EscapeRichText = EscapeRichText,
		COLORS = COLORS,
		LogLineReference = ObjectReferences.LogLineReference,
	}),

	["History"] = HistoryPage.Create(ServiceManager, {
		EnsurePagination = EnsurePagination,
		EscapeRichText = EscapeRichText,
		COLORS = COLORS,
		TaskDataReference = ObjectReferences.TaskDataReference,
		TaskCardReference = ObjectReferences.TaskCardReference,
	}),
}

-- Allow page controllers to call ServiceManager methods via `this:Method(...)`.
for _, page in next, Pages do
	if type(page) == "table" then
		local mt = getmetatable(page)
		if not mt then
			setmetatable(page, { __index = ServiceManager })
		elseif mt.__index == nil then
			mt.__index = ServiceManager
		end
	end
end

-- Expose Pages on ServiceManager so Entity/FSM layer can bridge to legacy controllers.
ServiceManager.Pages = Pages

--------------------------------------------------------------------------------
-- CORE METHODS
--------------------------------------------------------------------------------

--[[
	@description Hooks logic to the static UI for the Create Task view.
	@param this any -- ServiceManager instance
	@return ()
]]
ServiceManager.HookCreateTaskUI = function(this)
	local container = this.GUI.BodyContainer:WaitForChild("CreateTaskView"):WaitForChild("Container")
	if this._createTaskHooked then return end
	this._createTaskHooked = true

	local NameInput = container:WaitForChild("TaskName")
	local DelayInput = container:WaitForChild("Delay")
	local OutputInput = container:WaitForChild("Output")
	local RecurringToggle = container:WaitForChild("RecurringToggle")
	local PriorityToggle = container:WaitForChild("PriorityToggle")
	local EventToggle = container:WaitForChild("EventToggle")
	local SubmitButton = container:WaitForChild("Submit")

	local isRecurring = false
	RecurringToggle.MouseButton1Click:Connect(function()
		isRecurring = not isRecurring
		RecurringToggle.Text = "Recurring: " .. (isRecurring and "ON" or "OFF")
		RecurringToggle.BackgroundColor3 = isRecurring and COLORS.Success or COLORS.Error
	end)

	local priority = 1
	PriorityToggle.MouseButton1Click:Connect(function() priority = (priority % 5) + 1; PriorityToggle.Text = "Priority: " .. priority end)


	local events = {"Heartbeat", "Stepped", "PreSimulation", "PostSimulation"}
	if ServiceManager.Mode == "client" then
		table.insert(events, "RenderStepped")
	end
	local EventIndex = 1
	EventToggle.MouseButton1Click:Connect(function()
		EventIndex = (EventIndex % #events) + 1; EventToggle.Text = "Event: " .. events[EventIndex] 
	end)

	SubmitButton.MouseButton1Click:Connect(function()
		local name = NameInput.Text
		local delay = tonumber(DelayInput.Text) or 0
		local msg = OutputInput.Text

		if name == "" then 
			SubmitButton.Text = "INVALID NAME"
			task.delay(1, function() SubmitButton.Text = "SCHEDULE TASK" end)
			return 
		end
		local existingTasks = nil
		if ServiceManager.Mode == 'server' then
			existingTasks = ServiceManager.ServerData.Scheduler and ServiceManager.ServerData.Scheduler.Tasks
		else
			existingTasks = ServiceManager.Services.Scheduler and ServiceManager.Services.Scheduler.Tasks
		end
		if existingTasks and existingTasks[name] then
			SubmitButton.Text = "NAME EXISTS"
			task.delay(1, function() SubmitButton.Text = "SCHEDULE TASK" end)
			return
		end

		ServiceManager.Services.Scheduler:ScheduleTestTask(name, delay, isRecurring, priority, events[EventIndex], msg)

		SubmitButton.Text = "SCHEDULED!"
		task.wait(1)
		SubmitButton.Text = "SCHEDULE TASK"
	end)
end

--[[
	@description Applies active/inactive visuals to a sidebar tab.
	@param this any -- ServiceManager instance
	@param tab Instance -- Tab frame
	@param isActive boolean
	@return ()
]]
ServiceManager.SetTabVisual = function(this, tab, isActive)
	local btn = tab:FindFirstChild("Button") or tab:FindFirstChildWhichIsA("TextButton")
	if btn then
		btn.BackgroundColor3 = isActive and COLORS.Accent or Color3.fromRGB(45, 45, 45)
		btn.TextColor3 = isActive and Color3.new(1, 1, 1) or Color3.fromRGB(160, 160, 160)
	end
	local indicator = tab:FindFirstChild("Indicator")
	if indicator then
		indicator.Visible = isActive
	end
end

--[[
	@description Hooks sidebar tab buttons to swap pages and refresh visuals.
	@param this any -- ServiceManager instance
	@return ()
]]
ServiceManager.HookTabButtons = function(this)

	for _, Tab in next, this.GUI.TabContainer:GetChildren() do
		if not Tab:IsA("Frame") then continue end
		local btn = Tab:FindFirstChildWhichIsA("TextButton")
		if btn then
			btn.MouseEnter:Connect(function()
				if this.ActivePage ~= Tab.Name then
					Tween(btn, { BackgroundColor3 = Color3.fromRGB(60, 60, 60) }, 0.12)
				end
			end)
			btn.MouseLeave:Connect(function()
				if this.ActivePage ~= Tab.Name then
					Tween(btn, { BackgroundColor3 = Color3.fromRGB(45, 45, 45) }, 0.12)
				end
			end)
			btn.MouseButton1Click:Connect(function()
				if this.ActivePage == Tab.Name then return end

				-- If TabNavigationFSM is available, delegate to it
				if this.FSMs and this.FSMs.TabNavigation then
					this.FSMs.TabNavigation.Context.TargetTab = Tab.Name
					-- Also update ActivePage so sidebar/bottombar stay consistent
					this.ActivePage = Tab.Name
					for _, tabFrame in next, this.GUI.TabContainer:GetChildren() do
						if tabFrame:IsA("Frame") then
							this:SetTabVisual(tabFrame, tabFrame.Name == this.ActivePage)
						end
					end
					return
				end

				-- Legacy fallback: inline tab switching
				local PrevPage = Pages[this.ActivePage]
				if PrevPage then
					for _, c in next, PrevPage.Connections do c:Disconnect() end
					PrevPage.Connections = {}

					if PrevPage.Container then
						-- PrevPage.Container:ClearAllChildren() -- REMOVED: Breaks Console/CreateTask

						local View = PrevPage.Container.Parent
						if View then
							-- Destroy transient elements (rebuilt on return)
							local TransientNames = {
								["Toolbar"]=true,
								["Controls"]=true,
								["StateMachineList"]=true,
								["Search"]=true,
								["ActionsPanel"]=true,
							}
							for _, child in next, View:GetChildren() do
								if TransientNames[child.Name] then child:Destroy() end
							end

							-- Recursively clean hook markers (for pre-made elements)
							-- This handles History (Details.Back.Hooked) and Card reuse if applicable
							for _, descendant in ipairs(View:GetDescendants()) do
								if descendant.Name == "IsHooked" or descendant.Name == "Hooked" or descendant.Name == "Hover" then
									descendant:Destroy()
								end
							end

							-- Specific Cleanup for Performance GlobalStats (No markers used there)
							if this.ActivePage == "Performance" then
								local gs = View:FindFirstChild("GlobalStats")
								if gs then
									for _, btnName in ipairs({"PauseBtn", "ModeBtn"}) do
										local btn = gs:FindFirstChild(btnName)
										if btn then btn:Destroy() end
									end
								end
							end

							View.Visible = false
						end
					end

					if this.ActivePage == "Visualize" or this.ActivePage == "Settings" then
						-- Use selective clear to preserve layouts

						if this.ActivePage == "Visualize" and PrevPage.Constants.StateConnection then
							PrevPage.Constants.StateConnection:Disconnect()
							PrevPage.Constants.StateConnection = nil
						end
						for _, child in pairs(PrevPage.Container:GetChildren()) do
							if child:IsA("GuiObject") then child:Destroy() end
						end
					end
				end
				this.ActivePage = Tab.Name
				local nextView = Pages[Tab.Name].Container.Parent
				nextView.Visible = true
				nextView.Position = UDim2.new(0, 6, 0, 0)
				Tween(nextView, { Position = UDim2.new(0, 0, 0, 0) }, 0.18)
				for _, tabFrame in next, this.GUI.TabContainer:GetChildren() do
					if tabFrame:IsA("Frame") then
						this:SetTabVisual(tabFrame, tabFrame.Name == this.ActivePage)
					end
				end
				if Pages[Tab.Name].UpdateFunction then
					Pages[Tab.Name].UpdateFunction(Pages[Tab.Name])
				end
			end)
		end
	end

	for _, tabFrame in next, this.GUI.TabContainer:GetChildren() do
		if tabFrame:IsA("Frame") then
			this:SetTabVisual(tabFrame, tabFrame.Name == this.ActivePage)
		end
	end
end

--[[
	@description Updates sidebar status elements (mode, ping, service toggle).
	@param this any -- ServiceManager instance
	@return ()
]]
ServiceManager.UpdateSideBar = function(this)
	local toggleBtn = this.GUI.SidebarContainer:FindFirstChild("ModeToggle")
	local pingLabel = this.GUI.SidebarContainer:FindFirstChild("PingIndicator")
	if toggleBtn then
		local isClient = (this.Mode == 'client')
		toggleBtn.Text = isClient and "CLIENT" or "SERVER"
		toggleBtn.BackgroundColor3 = isClient and Color3.fromRGB(0, 120, 255) or Color3.fromRGB(200, 50, 50)
	end
	if pingLabel then
		pingLabel.Text = this.Ping and string.format("PING: <font color='#A0FFA0'>%dms</font>", this.Ping) or "<font color='#FF7878'>OFFLINE</font>"
	end

	local serviceBtn = this.GUI.SidebarContainer:FindFirstChild("ServiceToggle")
	if serviceBtn then
		serviceBtn.Text = this.ActiveService == "Scheduler" and "TASKS" or "FSM"
		serviceBtn.BackgroundColor3 = this.ActiveService == "Scheduler" and COLORS.Accent or COLORS.Warning
	end
end



--[[
	@description Updates the bottom status bar metadata.
	@param this any -- ServiceManager instance
	@return ()
]]
ServiceManager.UpdateBottomBar = function(this)
	for _, Metadata in next, BottomBarMetadata do
		if Metadata.UpdateFunction and Metadata.ObjectReference then Metadata:UpdateFunction() end
	end
end

--[[
	@description Sets UI connected/disconnected state and updates ping/labels.
	@param this any
	@param isDisconnected boolean
	@param reason string?
	@return ()
]]
ServiceManager.SetDisconnected = function(this, isDisconnected: boolean, reason: string?)
	NetworkRuntime.SetDisconnected(this, isDisconnected, reason)
end

--[[
	@description Records network failures and opens circuit on repeated errors.
	@param this any
	@param err string?
	@return ()
]]
ServiceManager.RecordNetworkFailure = function(this, err: string?)
	NetworkRuntime.RecordFailure(this, err)
end

--[[
	@description Records a successful network call and closes circuit.
	@param this any
	@return ()
]]
ServiceManager.RecordNetworkSuccess = function(this)
	NetworkRuntime.RecordSuccess(this)
end

--[[
	@description Applies theme colors to the UI tree based on tags and color heuristics.
	@param this any
	@return ()
]]
ServiceManager.ApplyTheme = function(this)
	local colorMap = {
		["25,25,25"] = COLORS.RootBG,
		["30,30,30"] = COLORS.PanelBG,
		["20,20,20"] = COLORS.SideBG,
		["10,10,10"] = COLORS.InputBG,
		["45,45,45"] = COLORS.DarkBG,
		["40,40,40"] = COLORS.DarkBG,
		["80,80,80"] = COLORS.Stroke,
		["60,60,60"] = COLORS.Stroke,
	}

	local function applyTo(obj)
		if obj:IsA("GuiObject") then
			local role = obj:GetAttribute("ThemeRole")
			if role == "Accent" then
				obj.BackgroundColor3 = COLORS.Accent
			elseif role == "Panel" then
				obj.BackgroundColor3 = COLORS.PanelBG
			elseif role == "Root" then
				obj.BackgroundColor3 = COLORS.RootBG
			elseif role == "Sidebar" then
				obj.BackgroundColor3 = COLORS.SideBG
			elseif role == "Input" then
				obj.BackgroundColor3 = COLORS.InputBG
			else
				local key = ColorKey(obj.BackgroundColor3)
				if colorMap[key] then
					obj.BackgroundColor3 = colorMap[key]
				end
			end
		end
		if obj:IsA("UIStroke") then
			local key = ColorKey(obj.Color)
			if colorMap[key] then
				obj.Color = colorMap[key]
			end
		end
	end

	applyTo(this.GUI.MainFrame)
	for _, descendant in ipairs(this.GUI.MainFrame:GetDescendants()) do
		applyTo(descendant)
	end
end

--[[
	@description Creates a proxy object that routes service calls to client or server.
	@param this any -- ServiceManager instance
	@param serviceName string
	@return any -- Proxy table
]]
ServiceManager.CreateServiceProxy = function(this, serviceName)
	return ServiceProxyRuntime.Create(this, serviceName)
end

--[[
	@description Shows/hides tabs based on the active service (Scheduler vs FSM).
	@param this any -- ServiceManager instance
	@return ()
]]
ServiceManager.UpdateTabVisibility = function(this)
	local isTask = this.ActiveService == "Scheduler"
	local tabs = this.GUI.TabContainer

	if tabs:FindFirstChild("TaskList") then tabs.TaskList.Visible = isTask end
	if tabs:FindFirstChild("CreateTask") then tabs.CreateTask.Visible = isTask end
	if tabs:FindFirstChild("Performance") then tabs.Performance.Visible = isTask end

	if tabs:FindFirstChild("FSMs") then tabs.FSMs.Visible = not isTask end
	if tabs:FindFirstChild("Visualize") then tabs.Visualize.Visible = not isTask end
	if tabs:FindFirstChild("Entities") then tabs.Entities.Visible = not isTask end

	-- Shared: Console, Settings, Logs, History
end



--[[
	@description Switches ServiceManager context mode and forces immediate UI refresh.
	@param this any -- ServiceManager instance
	@param nextMode string -- 'client' or 'server'
	@return boolean -- true if switched, false if invalid/no-op
]]
ServiceManager.SetMode = function(this, nextMode)
	if nextMode ~= "client" and nextMode ~= "server" then
		return false
	end
	if this.Mode == nextMode then
		return false
	end

	this.ContextSwitching = true
	this.ContextSwitchDeadline = os.clock() + 2.0
	this.Mode = nextMode
	this:UpdateSideBar()

	-- Reset sync flags so server polling/event sync won't short-circuit.
	this.HasInitialSync = false
	this.ReplicationMode = nil
	this.Ping = nil

	-- Clear server snapshots immediately so pages don't render stale data.
	if this.ServerData and this.ServerData.Scheduler then
		this.ServerData.Scheduler.Tasks = {}
		this.ServerData.Scheduler.History = {}
		this.ServerData.Scheduler.Settings = {}
		this.ServerData.Scheduler.Logger.OutputBuffer = {}
		this.ServerData.Scheduler.LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 }
		this.ServerData.Scheduler.PerformanceManager.Stats = {}
	end
	if this.ServerData and this.ServerData.FSM then
		this.ServerData.FSM.StateMachines = {}
		this.ServerData.FSM.Entities = {}
		this.ServerData.FSM.Settings = {}
		this.ServerData.FSM.History = {}
		this.ServerData.FSM.Logs.OutputBuffer = {}
	end

	SetLoadingOverlay(this, true, string.format("SWITCHING TO %s...", tostring(nextMode):upper()))

	-- Best-effort: append to legacy console if present.
	local Console = Pages and Pages["Console"]
	if Console and Console.Container then
		local LineContainer = Console.Container:FindFirstChild("TextContainer")
		if LineContainer then
			local maxOrder = 0
			for _, child in ipairs(LineContainer:GetChildren()) do
				if child:IsA("TextLabel") and child.LayoutOrder then
					maxOrder = math.max(maxOrder, child.LayoutOrder)
				end
			end

			local Line = ObjectReferences.ConsoleLineReference:Clone()
			Line.Text = string.format("Switching Mode to <font color='#FFFF00'>%s</font>...", tostring(nextMode):upper())
			Line.LayoutOrder = maxOrder + 1
			Line.Parent = LineContainer
			Line.Visible = true
		end
	end

	this.Mode = nextMode

	-- Reset per-page drilldown/selection state so we don't keep stale detail views
	-- across context switches (e.g. History drilldown, selected task/entity/FSM).
	for _, page in next, Pages do
		local constants = (page :: any).Constants
		if type(constants) == "table" then
			if constants.SelectedEntry ~= nil then constants.SelectedEntry = nil end
			if constants.SelectedTask ~= nil then constants.SelectedTask = nil end
			if constants.SelectedStateMachine ~= nil then constants.SelectedStateMachine = nil end
			if constants.SelectedEntity ~= nil then constants.SelectedEntity = nil end
			if constants.LastStateMachineId ~= nil then constants.LastStateMachineId = nil end
			if constants.LastHash ~= nil then constants.LastHash = "" end
			if constants.LastBufferHash ~= nil then constants.LastBufferHash = "" end
		end
	end

	-- Clear archived/cache data on mode switch to prevent leaks
	ServiceManager.ArchivedEntities = {}
	ServiceManager.ArchivedFSMs = {}
	ServiceManager.ArchivedTasks = {}
	ServiceManager.LastClientTasks = {}
	ServiceManager.LastStateMachines = {}
	ServiceManager.LastEntities = {}

	if this.Store then
		this.Store:MarkDirty()
	end
	-- Force an immediate page refresh so the UI invalidates right now.
	if this.ActivePage and Pages[this.ActivePage] and Pages[this.ActivePage].UpdateFunction then
		Pages[this.ActivePage]:UpdateFunction()
	end

	-- If switching to server mode, kick an immediate fetch via the Entity.
	if this.Mode == "server" then
		-- Access entity via Sidecar (which just wraps Orchestrator.GetEntity)
		if this.Sidecar then
			local entity = (this.Sidecar :: any):GetEntity("SyncClient")
			if entity and entity.ConnectionFSM then
				entity.ConnectionFSM:PerformFetch()
			end
		end
	end

	return true
end

--[[
	@description Initializes the ServiceManager UI, sets up input hooks, and starts scheduled updates.
	@param this any -- ServiceManager instance
	@param InjectedOrchestrator any? -- Orchestrator reference (optional, fallback to shared.fsm)
	@return any -- this
]]
ServiceManager.Initialize = function(this, InjectedOrchestrator)
	-- Guard: prevent double-initialization (entity's Initialize could call back here)
	if this._initialized then return this end
	this._initialized = true

	if InjectedOrchestrator then
		this.Orchestrator = InjectedOrchestrator
		this.Services.Scheduler = InjectedOrchestrator.Scheduler
	end

	-- Safety check: ensure GUI has been properly created
	if not this.GUI or not this.GUI.MainFrame then
		error("[ServiceManager] GUI.MainFrame is nil - GuiProvider failed to create GUI. Check that Orchestrator.Core.ServiceManager.Runtime.GuiProvider is working correctly.")
	end
	
	-- Layout: prefer the serialized GUI's TopBar/Body/BottomBar geometry.
	-- The old hard-coded offsets could cause the TopBar/AppTitle to overlap the Body.
	this.GUI.MainFrame.ClipsDescendants = true

	local function applyLayout()
		local main = this.GUI.MainFrame
		local sidebar = this.GUI.SidebarContainer
		local body = this.GUI.BodyContainer
		local bottomBar = this.GUI.BottomBarContainer

		-- X layout: keep a small gap after the sidebar.
		local sidebarWidth = (sidebar and sidebar.AbsoluteSize.X) or 96
		local leftOffset = math.max(0, sidebarWidth + 14)
		local rightPad = 14

		-- Y layout: if TopBar exists, place Body below it.
		local topBar = main:FindFirstChild("TopBar")
		local bodyTop = body.Position.Y.Offset
		if topBar and topBar:IsA("GuiObject") then
			bodyTop = topBar.Position.Y.Offset + topBar.AbsoluteSize.Y + 5
		else
			bodyTop = math.max(bodyTop, 25)
		end

		-- Preserve the bottom spacing by anchoring Body height against BottomBar's bottom offset.
		local bottomOffsetY = bottomBar.Position.Y.Offset
		local bodyHeightOffset = bottomOffsetY - bodyTop - 7
		if bodyHeightOffset > -20 then
			-- Fallback to current sizing if something is off (e.g. unexpected GUI edits)
			bodyHeightOffset = body.Size.Y.Offset
		end

		body.Position = UDim2.new(0, leftOffset, 0, bodyTop)
		body.Size = UDim2.new(1, -(leftOffset + rightPad), 1, bodyHeightOffset)

		bottomBar.Position = UDim2.new(0, leftOffset, 1, bottomOffsetY)
		bottomBar.Size = UDim2.new(1, -(leftOffset + rightPad), bottomBar.Size.Y.Scale, bottomBar.Size.Y.Offset)

		if topBar and topBar:IsA("GuiObject") then
			topBar.Position = UDim2.new(0, leftOffset, topBar.Position.Y.Scale, topBar.Position.Y.Offset)
			topBar.Size = UDim2.new(1, -(leftOffset + rightPad), topBar.Size.Y.Scale, topBar.Size.Y.Offset)
		end
	end

	applyLayout()
	-- Defer once so AbsoluteSize/positions are stable.
	task.defer(applyLayout)

	this:HookCreateTaskUI()
	this:ApplyTheme()

	if not this.Store then
		local Changed = Instance.new("BindableEvent")
		this.Store = {
			State = {},
			Dirty = false,
			Changed = Changed,
			Set = function(store, key, value)
				store.State[key] = value
				store.Dirty = true
				store.Changed:Fire(key, value)
			end,
			MarkDirty = function(store)
				store.Dirty = true
				store.Changed:Fire("__dirty__", true)
			end
		}
	end

	for _, view in next, Pages do
		if view.Container and view.Container:IsA("ScrollingFrame") then
			local pad = view.Container:FindFirstChildOfClass("UIPadding") or Instance.new("UIPadding", view.Container)
			pad.PaddingTop = UDim.new(0, 10); pad.PaddingBottom = UDim.new(0, 10)
		end
	end

	local toggleBtn = this.GUI.SidebarContainer:FindFirstChild("ModeToggle")
	if toggleBtn then
		toggleBtn.MouseButton1Click:Connect(function()
			-- If ModeToggleFSM is available, delegate to it
			if this.FSMs and this.FSMs.ModeToggle then
				local currentMode = this.FSMs.ModeToggle.Context.CurrentMode or "client"
				this.FSMs.ModeToggle.Context.TargetMode = (currentMode == "client") and "server" or "client"
				return
			end
			-- Legacy fallback: inline mode switching
			local nextMode = (this.Mode == 'client') and 'server' or 'client'
			this:SetMode(nextMode)
		end)
	end

	local serviceBtn = this.GUI.SidebarContainer:FindFirstChild("ServiceToggle")
	if serviceBtn then
		serviceBtn.MouseButton1Click:Connect(function()
			local Console = Pages["Console"]
			if Console and Console.Container then
				local LineContainer = Console.Container:FindFirstChild("TextContainer")
				if LineContainer then
					-- Find max LayoutOrder to append to bottom
					local maxOrder = 0
					for _, child in ipairs(LineContainer:GetChildren()) do
						if child:IsA("TextLabel") and child.LayoutOrder then
							maxOrder = math.max(maxOrder, child.LayoutOrder)
						end
					end

					local Line = ObjectReferences.ConsoleLineReference:Clone()
					Line.Text = string.format("Switching Service to <font color='#FFFF00'>%s</font>...", (this.ActiveService == "Scheduler") and 'FSM' or 'TASKS')
					Line.LayoutOrder = maxOrder + 1
					Line.Parent = LineContainer; Line.Visible = true
				end
			end

			-- Cleanup Current Page
			local PrevPage = Pages[this.ActivePage]
			if PrevPage then
				for _, c in next, PrevPage.Connections do c:Disconnect() end
				PrevPage.Connections = {}

				-- Cleanup Hooked Cards
				for _, listName in ipairs({"TaskList", "StateMachineList", "EntityList"}) do
					if PrevPage.Container:FindFirstChild(listName) then
						for _, card in next, PrevPage.Container[listName]:GetChildren() do
							if card:FindFirstChild("IsHooked") then card.IsHooked:Destroy() end
						end
					end
				end
				PrevPage.Container.Parent.Visible = false

				if this.ActivePage == "Visualize" then
					Pages.Visualize:Cleanup()
				end

				if table.find({"Logs", "TaskList", "Performance", "FSMs", "Entities", "History"}, this.ActivePage) then
					local tb = PrevPage.Container.Parent:FindFirstChild("Toolbar")
					if tb then tb:Destroy() end
				end

				if this.ActivePage == "Performance" then
					local gs = PrevPage.Container.Parent:FindFirstChild("GlobalStats")
					if gs then
						local pauseButton = gs:FindFirstChild("PauseBtn")
						if pauseButton then pauseButton:Destroy() end
						local modeButton = gs:FindFirstChild("ModeBtn")
						if modeButton then modeButton:Destroy() end
						local tooltipFrame = gs:FindFirstChild("Tooltip")
						if tooltipFrame then tooltipFrame:Destroy() end
						local graphContainer = gs:FindFirstChild("GraphContainer")
						if graphContainer then
							for _, barFrame in ipairs(graphContainer:GetChildren()) do
								if barFrame.Name:match("Bar") then
									barFrame:Destroy()
								end
							end
						end
					end
				elseif this.ActivePage == "History" then
					local controls = PrevPage.Container.Parent:FindFirstChild("Controls")
					if controls and controls:FindFirstChild("Hooked") then controls.Hooked:Destroy() end
					local details = PrevPage.Container.Parent:FindFirstChild("Details")
					if details and details:FindFirstChild("Back") and details.Back:FindFirstChild("Hooked") then details.Back.Hooked:Destroy() end
				end
			end

			if this.ActiveService == "Scheduler" then
				this.ActiveService = "FSM"
			else
				this.ActiveService = "Scheduler"
			end
			this.ActivePage = "Console" -- Reset to Console to avoid invalid pages
			this:UpdateTabVisibility()
			this:UpdateSideBar()
			for _, tabFrame in next, this.GUI.TabContainer:GetChildren() do
				if tabFrame:IsA("Frame") then
					this:SetTabVisual(tabFrame, tabFrame.Name == this.ActivePage)
				end
			end

			if Pages["Console"] then
				Pages["Console"].Container.Parent.Visible = true
				Pages["Console"]:UpdateFunction()
			end
		end)
	end

	-- Draggable Logic
	local function MakeDraggable(dragHandle, dragObject)
		local dragging, dragInput, dragStart, startPos
		dragHandle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = dragObject.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then dragging = false end
				end)
			end
		end)
		dragHandle.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				dragInput = input
			end
		end)
		UIS.InputChanged:Connect(function(input)
			if input == dragInput and dragging then
				local delta = input.Position - dragStart
				dragObject.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
			end
		end)
	end
	MakeDraggable(this.GUI.SidebarContainer, this.GUI.MainFrame)

	-- Minimize Logic
	local MinBtn = this.GUI.SidebarContainer:WaitForChild("MinBtn")

	local IsMinimized = false
	local FullSize = this.GUI.MainFrame.Size
	local FullPosition = this.GUI.MainFrame.Position
	local topBar = this.GUI.MainFrame:FindFirstChild("TopBar")
	MinBtn.MouseButton1Click:Connect(function()
		IsMinimized = not IsMinimized
		local toggle = this.GUI.SidebarContainer:FindFirstChild("ModeToggle")
		local ping = this.GUI.SidebarContainer:FindFirstChild("PingIndicator")
		local service = this.GUI.SidebarContainer:FindFirstChild("ServiceToggle")

		if IsMinimized then
			FullSize = this.GUI.MainFrame.Size
			FullPosition = this.GUI.MainFrame.Position
			this.GUI.MainFrame:TweenSize(UDim2.new(0, 80, 0, 30), "Out", "Quad", 0.3, true)
			this.GUI.BodyContainer.Visible = false
			this.GUI.BottomBarContainer.Visible = false
			this.GUI.TabContainer.Visible = false
			-- if this.GUI.Title then this.GUI.Title.Visible = false end -- Keep visible for "SM"
			if topBar and topBar:IsA("GuiObject") then topBar.Visible = false end
			if toggle then toggle.Visible = false end
			if ping then ping.Visible = false end
			if service then service.Visible = false end
			MinBtn.Text = "+"
		else
			this.GUI.MainFrame.Position = FullPosition
			this.GUI.MainFrame:TweenSize(FullSize, "Out", "Quad", 0.3, true)
			task.delay(0.3, function()
				if not IsMinimized then
					this.GUI.BodyContainer.Visible = true
					this.GUI.BottomBarContainer.Visible = true
					this.GUI.TabContainer.Visible = true
					if this.GUI.Title then this.GUI.Title.Visible = true end
					if topBar and topBar:IsA("GuiObject") then topBar.Visible = true end
					if toggle then toggle.Visible = true end
					if ping then ping.Visible = true end
					if service then service.Visible = true end
				end
			end)
			MinBtn.Text = "-"
		end
	end)

	this.Services.Scheduler = this:CreateServiceProxy("Scheduler")
	this.Services.FSM = this:CreateServiceProxy("FSM")

	this:UpdateTabVisibility()

	if this.Mode == 'client' then
		local FSM = this.Orchestrator or shared.fsm
		-- Ensure core services are available before proceeding
		if not (FSM and FSM.Scheduler) then
			local start = tick()
			repeat task.wait()
			FSM = this.Orchestrator or shared.fsm
			until (FSM and FSM.Scheduler) or (tick() - start > 5)

			if not (FSM and FSM.Scheduler) then
				warn("[ServiceManager] Timed out waiting for shared.Scheduler/FSM.")
			end
		end

		if FSM and FSM.Scheduler and FSM.Scheduler.Start then 
			FSM.Scheduler:Start() 
		end
	end

	for _, Page in next, Pages do if Page.Container then Page.Container.Parent.Visible = false end end
	this.ActivePage = "Console"
	if Pages["Console"].Container then Pages["Console"].Container.Parent.Visible = true end

	this:HookTabButtons()
	-- Initialize Client Entity & FSM layer
	local clientEntity = nil
	if this.Orchestrator and this.Orchestrator.CreateEntity then
		clientEntity = this.Orchestrator.CreateEntity({
			EntityClass = "ServiceManagerClientEntity",
			-- We alias as SyncClient because the server (ServiceManagerHost) currently sends commands to "SyncClient".
			-- This maintains backward compatibility without modifying the server code.
			EntityId = "SyncClient",
			Context = { ServiceManager = this, Orchestrator = this.Orchestrator }
		})
	end

	-- Deferred: Initialize the entity after init.luau completes, so Pages/GUI are ready.
	-- The entity creates UIInitializationFSM, TabNavigationFSM, ModeToggleFSM,
	-- TerminalViewFSM, and ConnectionStateMachine in its Initialize().
	if clientEntity then
		task.defer(function()
			if clientEntity.Initialize then
				clientEntity:Initialize()
			end
		end)
	end

	-- Initialize Page Entities & FSMs via PageInitializerFSM (Phase 4 Integration)
	if this.Orchestrator and this.Orchestrator.CreateStateMachine then
		this.Orchestrator.CreateStateMachine({
			StateMachineClass = "PageInitializerFSM",
			StateMachineId = "PageInitializer",
			Context = {
				ServiceManager = this,
				Orchestrator = this.Orchestrator,
				COLORS = COLORS
			}
		})
	end

	this.Services.Scheduler:Schedule({
		TaskName = "ServiceManagerUpdate",
		TaskAction = function() 
			this:Update() 
		end,
		IsRecurringTask = true,
		Priority = 10,
		TaskExecutionDelay = 0,
	})
	print("[ServiceManager] Scheduled ServiceManagerUpdate")
	return this
end

--[[
	@description Periodic UI update loop (tab refresh, archival logic, stats sync).
	@param this any -- ServiceManager instance
	@return ()
]]
ServiceManager.Update = function(this)
	local now = tick()
	if now - this.LastUpdate < this.RefreshRate then return end
	this.LastUpdate = now

	-- Context switch UX: hide stale data immediately and wait for new source.
	this:_UpdateContextSwitch()

	-- Archival / Sync
	this:_ArchiveClientTasks()
	this:_ArchiveFSMs()
	this:_SyncFSMHistory()
	this:_ArchiveEntities()
	this:_SyncClientMode()

	-- UI refresh
	ServiceManager:UpdateSideBar()
	ServiceManager:UpdateBottomBar()

	if this.ActivePage and Pages[this.ActivePage] then
		Pages[this.ActivePage]:UpdateFunction()
	end
end

-- Update sub-routines (decomposed for clarity and future entity-driven migration)

--[[
	@description Checks whether a client/server context switch has completed.
	Waits until the target mode's data is available or a deadline expires,
	then hides the loading overlay.
	@param this table -- The ServiceManager instance.
]]
ServiceManager._UpdateContextSwitch = function(this)
	if not this.ContextSwitching then return end
	local ready = false
	if this.Mode == 'server' then
		ready = (this.HasInitialSync == true)
	else
		local FSM = this.Orchestrator or shared.fsm
		ready = (FSM ~= nil) and ((FSM.Scheduler ~= nil) or (FSM.StateMachines ~= nil) or (FSM.Entities ~= nil))
	end
	if ready or (this.ContextSwitchDeadline and os.clock() > this.ContextSwitchDeadline) then
		this.ContextSwitching = false
		this.ContextSwitchDeadline = nil
		SetLoadingOverlay(this, false, nil)
	else
		SetLoadingOverlay(this, true, string.format("SWITCHING TO %s...", tostring(this.Mode):upper()))
	end
end

--[[
	@description Archives recurring client tasks that have been removed from the Scheduler.
	Compares current Scheduler.Tasks against the last snapshot, marking disappeared
	recurring tasks as archived. Also syncs local performance stats.
	@param this table -- The ServiceManager instance.
]]
ServiceManager._ArchiveClientTasks = function(this)
	if this.Mode ~= 'client' then return end
	local FSM = this.Orchestrator or shared.fsm
	if not (FSM and FSM.Scheduler) then return end

	local current = FSM.Scheduler.Tasks
	this.LastClientTasks = this.LastClientTasks or {}
	for name, taskData in pairs(this.LastClientTasks) do
		if taskData.IsRecurringTask and not current[name] then
			taskData.IsArchived = true
			this.ArchivedTasks[name] = taskData
		end
	end
	for name, _ in pairs(current) do
		if this.ArchivedTasks[name] then this.ArchivedTasks[name] = nil end
	end
	this.LastClientTasks = {}
	for taskName, taskData in pairs(current) do
		this.LastClientTasks[taskName] = taskData
	end

	-- Sync local stats
	if FSM.Scheduler.LastFrameStats then
		this.ServerData.Scheduler.LastFrameStats = FSM.Scheduler.LastFrameStats
	end
	if FSM.Scheduler.TaskStats then
		this.ServerData.Scheduler.PerformanceManager.Stats = FSM.Scheduler.TaskStats
	end
end

--[[
	@description Archives state machines that have disappeared since the last update.
	Preserves final state, graph, valid-states, and context for display in the
	FSMs page. Also maintains FSMMetadataCache for graph recovery.
	@param this table -- The ServiceManager instance.
]]
ServiceManager._ArchiveFSMs = function(this)
	local currentStateMachines = {}
	local FSM = this.Orchestrator or shared.fsm
	if this.Mode == 'client' and FSM and FSM.StateMachines then
		currentStateMachines = FSM.StateMachines
	elseif this.Mode == 'server' and this.ServerData.FSM.StateMachines then
		currentStateMachines = this.ServerData.FSM.StateMachines
	end

	this.LastStateMachines = this.LastStateMachines or {}
	for id, stateMachine in pairs(this.LastStateMachines) do
		if not currentStateMachines[id] then
			local finalState = stateMachine.State or "Dead"
			local history = (this.Mode == 'client' and shared.fsm and shared.fsm.History) or (this.Mode == 'server' and this.ServerData.FSM.History)
			if history then
				for _, entry in ipairs(history) do
					if entry.Id == id then finalState = entry.Status; break end
				end
			end

			local graph = stateMachine.Graph
			if not graph and stateMachine._transitions then
				graph = { Transitions = stateMachine._transitions }
			end
			local validStates = stateMachine.ValidStates or stateMachine.validStates

			this.ArchivedFSMs[id] = {
				Name = stateMachine.Name, State = finalState, Id = id, IsArchived = true,
				Context = stateMachine.Context, Graph = graph, ValidStates = validStates,
			}

			if stateMachine.Name and (graph or validStates) then
				this.FSMMetadataCache[stateMachine.Name] = {
					Graph = graph or (this.FSMMetadataCache[stateMachine.Name] and this.FSMMetadataCache[stateMachine.Name].Graph),
					ValidStates = validStates or (this.FSMMetadataCache[stateMachine.Name] and this.FSMMetadataCache[stateMachine.Name].ValidStates),
				}
			end
		else
			local stateMachineData = currentStateMachines[id]
			if stateMachineData.Name then
				local graph = stateMachineData.Graph or (stateMachineData._transitions and { Transitions = stateMachineData._transitions })
				local validStates = stateMachineData.ValidStates or stateMachineData.validStates
				if graph or validStates then
					this.FSMMetadataCache[stateMachineData.Name] = {
						Graph = graph or (this.FSMMetadataCache[stateMachineData.Name] and this.FSMMetadataCache[stateMachineData.Name].Graph),
						ValidStates = validStates or (this.FSMMetadataCache[stateMachineData.Name] and this.FSMMetadataCache[stateMachineData.Name].ValidStates),
					}
				end
			end
		end
	end
	this.LastStateMachines = {}
	for stateMachineId, stateMachineData in pairs(currentStateMachines) do
		this.LastStateMachines[stateMachineId] = stateMachineData
	end
end

--[[
	@description Cross-references the FSM history log with archived and current state machines.
	Updates archived FSMs whose terminal state was missed, and reconstructs
	entries for FSMs that completed before ServiceManager started (catch-up).
	@param this table -- The ServiceManager instance.
]]
ServiceManager._SyncFSMHistory = function(this)
	local currentStateMachines = {}
	local FSM = this.Orchestrator or shared.fsm
	if this.Mode == 'client' and FSM and FSM.StateMachines then
		currentStateMachines = FSM.StateMachines
	elseif this.Mode == 'server' and this.ServerData.FSM.StateMachines then
		currentStateMachines = this.ServerData.FSM.StateMachines
	end

	local history = (this.Mode == 'client' and FSM and FSM.History) or (this.Mode == 'server' and this.ServerData.FSM.History)
	if not history then return end

	-- Update archived FSMs with history (fix for server mode latency)
	for id, stateMachine in pairs(this.ArchivedFSMs) do
		if stateMachine.State ~= "Completed" and stateMachine.State ~= "Failed" and stateMachine.State ~= "Cancelled" then
			for _, entry in ipairs(history) do
				if entry.Id == id then
					stateMachine.State = entry.Status
					stateMachine.Error = entry.Error
					break
				end
			end
		end
	end

	-- Catch-up for state machines that finished before ServiceManager started
	for _, entry in ipairs(history) do
		if not currentStateMachines[entry.Id] and not this.ArchivedFSMs[entry.Id] then
			local recoveredGraph, recoveredValidStates = nil, nil

			if this.FSMMetadataCache[entry.Name] then
				recoveredGraph = this.FSMMetadataCache[entry.Name].Graph
				recoveredValidStates = this.FSMMetadataCache[entry.Name].ValidStates
			end
			if not recoveredGraph then
				for _, existing in pairs(this.ArchivedFSMs) do
					if existing.Name == entry.Name and existing.Graph then
						recoveredGraph = existing.Graph
						recoveredValidStates = existing.ValidStates
						break
					end
				end
			end
			if not recoveredGraph then
				for _, existing in pairs(currentStateMachines) do
					if existing.Name == entry.Name then
						local graphCandidate = existing.Graph or (existing._transitions and { Transitions = existing._transitions })
						if graphCandidate then
							recoveredGraph = graphCandidate
							recoveredValidStates = existing.ValidStates or existing.validStates
							break
						end
					end
				end
			end

			this.ArchivedFSMs[entry.Id] = {
				Name = entry.Name, State = entry.Status, Id = entry.Id, Error = entry.Error,
				IsArchived = true, Context = {}, Graph = recoveredGraph, ValidStates = recoveredValidStates,
			}
		end
	end
end

--[[
	@description Archives entities that have disappeared since the last update.
	Preserves name, ID, and data snapshot for display in the Entities page.
	@param this table -- The ServiceManager instance.
]]
ServiceManager._ArchiveEntities = function(this)
	local currentEntities = {}
	local FSM = this.Orchestrator or shared.fsm
	if this.Mode == 'client' and FSM and FSM.Entities then
		currentEntities = FSM.Entities
	elseif this.Mode == 'server' and this.ServerData.FSM.Entities then
		currentEntities = this.ServerData.FSM.Entities
	end

	this.LastEntities = this.LastEntities or {}
	for id, entity in pairs(this.LastEntities) do
		if not currentEntities[id] then
			this.ArchivedEntities[id] = { Name = entity.Name or "Unknown", Id = id, IsArchived = true, Data = entity.Data }
		end
	end
	this.LastEntities = {}
	for entityId, entityData in pairs(currentEntities) do
		this.LastEntities[entityId] = entityData
	end
end

--[[
	@description Mirrors the client-local FSM registry into ServerData so that
	UI pages can read from a uniform data source regardless of mode.
	@param this table -- The ServiceManager instance.
]]
ServiceManager._SyncClientMode = function(this)
	if this.Mode ~= 'client' then return end
	local FSM = this.Orchestrator or shared.fsm
	if not FSM then return end
	if FSM.StateMachines then
		this.ServerData.FSM.StateMachines = FSM.StateMachines
	end
end

return ServiceManager