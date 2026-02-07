--!strict
-- @Name ServiceManagerClientEntity
-- @Author iKrypto
-- @Description Client-side entity that manages the ServiceManager UI, input handling, and network synchronization via FSM.

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

-- The Entity Definition
local ServiceManagerClientEntity = {
	Definition = {
		Name = "ServiceManagerClientEntity",
		Schema = {
			Visible = { Type = "boolean", Persist = false },
			TerminalFSM = { Type = "table", Persist = false },
			ConnectionFSM = { Type = "table", Persist = false },
			ServiceManager = { Type = "table", Persist = false },
		}
	}
}

--[[
	@description Extracts the Orchestrator and ServiceManager references from creation params.
	@param params any -- Entity creation parameters containing Context table.
	@return table -- The resolved context with Orchestrator and ServiceManager.
]]
function ServiceManagerClientEntity:GetContext(params: any)
	return {
		Orchestrator = params.Context and params.Context.Orchestrator,
		ServiceManager = params.Context and params.Context.ServiceManager
	}
end

--[[
	@description Initializes the client entity: registers sync callbacks, creates FSMs
	(UIInitialization, TabNavigation, ModeToggle, Terminal, Connection),
	hooks input, and schedules a recurring UI update task.
]]
function ServiceManagerClientEntity:Initialize()
	-- Guard: prevent double-initialization
	if self._initialized then return end
	self._initialized = true

	local Orchestrator = self.Orchestrator
	local ServiceManager = self.ServiceManager

	if not ServiceManager then
		self:Log({ Level = "ERROR", Message = "Failed to load ServiceManager module." })
		return
	end

	-- Store reference
	self.ServiceManager = ServiceManager
	self.UIRefreshRate = 0.1  -- 10Hz updates
	self.LastUIUpdate = 0

	-- NOTE: init.luau's Initialize() is the primary entry point.
	-- This entity is created at the end of that flow. Do NOT call
	-- ServiceManager:Initialize(Orchestrator) here — it would cause
	-- infinite recursion (init creates entity → entity calls init).

	-- Initialize entity structure
	ServiceManager.Entities = ServiceManager.Entities or {
		Window = nil,
		Sidebar = nil,
		BottomBar = nil,
		Tabs = {}
	}
	ServiceManager.FSMs = ServiceManager.FSMs or {
		Initialization = nil,
		TabNavigation = nil,
		ModeToggle = nil,
		Terminal = nil
	}
	
	-- Define Sync Functions (Migrated from SyncClient)
	local SyncFunctions; SyncFunctions = {
		ApplySyncData = function(data)
			ServiceManager.ReplicationMode = "event"
			if not ServiceManager or not data then return end
			
			-- Scheduler Data
			local tsData = data.Scheduler
			if tsData then
				if tsData.Tasks then
					for name, taskData in pairs(tsData.Tasks) do
						if typeof(taskData) == "table" then
							ServiceManager.ServerData.Scheduler.Tasks[name] = ServiceManager.ServerData.Scheduler.Tasks[name] or {}
							for k, v in pairs(taskData) do ServiceManager.ServerData.Scheduler.Tasks[name][k] = v end
						else
							ServiceManager.ServerData.Scheduler.Tasks[name] = taskData
						end
					end
					-- Remove stale tasks
					for name, _ in pairs(ServiceManager.ServerData.Scheduler.Tasks) do
						if not tsData.Tasks[name] then ServiceManager.ServerData.Scheduler.Tasks[name] = nil end
					end
				end
				if tsData.Logs then ServiceManager.ServerData.Scheduler.Logger.History = tsData.Logs end
				if tsData.Settings then ServiceManager.ServerData.Scheduler.Settings = tsData.Settings end
				if tsData.History then ServiceManager.ServerData.Scheduler.History = tsData.History end
				if tsData.LastFrameStats then ServiceManager.ServerData.Scheduler.LastFrameStats = tsData.LastFrameStats end
				if tsData.TaskStats then ServiceManager.ServerData.Scheduler.PerformanceManager.Stats = tsData.TaskStats end
				ServiceManager.ServerData.Scheduler.PerformanceManager.Tasks = ServiceManager.ServerData.Scheduler.Tasks
			end

			-- FSM Data
			local fsmData = data.FSM
			if fsmData then
				if fsmData.StateMachines then
					for id, stateMachineData in pairs(fsmData.StateMachines) do
						if typeof(stateMachineData) == "table" then
							ServiceManager.ServerData.FSM.StateMachines[id] = ServiceManager.ServerData.FSM.StateMachines[id] or {}
							for k, v in pairs(stateMachineData) do ServiceManager.ServerData.FSM.StateMachines[id][k] = v end
						else
							ServiceManager.ServerData.FSM.StateMachines[id] = stateMachineData
						end
					end
					-- Remove stale stateMachines
					for id, _ in pairs(ServiceManager.ServerData.FSM.StateMachines) do
						if not fsmData.StateMachines[id] then ServiceManager.ServerData.FSM.StateMachines[id] = nil end
					end
				end
				if fsmData.Settings then ServiceManager.ServerData.FSM.Settings = fsmData.Settings end
				if fsmData.Entities then ServiceManager.ServerData.FSM.Entities = fsmData.Entities end
				if fsmData.Logs then ServiceManager.ServerData.FSM.Logs.History = fsmData.Logs end
				if fsmData.History then ServiceManager.ServerData.FSM.History = fsmData.History end
			end

			if ServiceManager.Store then ServiceManager.Store:MarkDirty() end
			
			-- Notify FSM
			if self.ConnectionFSM then self.ConnectionFSM.LastSync = os.clock() end
		end,

		ApplySchedulerDelta = function(delta)
			ServiceManager.ReplicationMode = "event"
			if not ServiceManager or not delta then return end
			local tasks = ServiceManager.ServerData.Scheduler.Tasks
			if delta.Tasks then
				for name, taskData in pairs(delta.Tasks) do
					if taskData == false then
						tasks[name] = nil
					else
						if tasks[name] and typeof(taskData) == "table" then
							for k, v in pairs(taskData) do tasks[name][k] = v end
						else
							tasks[name] = taskData
						end
					end
				end
			end
			if delta.LastFrameStats then ServiceManager.ServerData.Scheduler.LastFrameStats = delta.LastFrameStats end
			if delta.TaskStats then ServiceManager.ServerData.Scheduler.PerformanceManager.Stats = delta.TaskStats end
			if ServiceManager.Store then ServiceManager.Store:MarkDirty() end
			
			-- Notify FSM
			if self.ConnectionFSM then self.ConnectionFSM.LastSync = os.clock() end
		end,

		ApplyFSMDelta = function(delta)
			if not ServiceManager or not delta then return end
			local stateMachines = ServiceManager.ServerData.FSM.StateMachines
			if delta.StateMachines then
				for id, stateMachineData in pairs(delta.StateMachines) do
					if stateMachineData == false then
						stateMachines[id] = nil
					else
						if stateMachines[id] and typeof(stateMachineData) == "table" then
							for k, v in pairs(stateMachineData) do stateMachines[id][k] = v end
						else
							stateMachines[id] = stateMachineData
						end
					end
				end
			end
			if delta.Entities then ServiceManager.ServerData.FSM.Entities = delta.Entities end
			if delta.Logs then ServiceManager.ServerData.FSM.Logs.History = delta.Logs end
			if delta.History then ServiceManager.ServerData.FSM.History = delta.History end
			if ServiceManager.Store then ServiceManager.Store:MarkDirty() end
			
			-- Notify FSM
			if self.ConnectionFSM then self.ConnectionFSM.LastSync = os.clock() end
		end,

		ApplyStateMachineStateChanged = function(stateMachineId, newState)
			if not ServiceManager or not stateMachineId or not newState then return end
			if ServiceManager.Mode == 'server' and ServiceManager.ServerData.FSM.StateMachines[stateMachineId] then
				ServiceManager.ServerData.FSM.StateMachines[stateMachineId].State = newState
				if ServiceManager.Store then ServiceManager.Store:MarkDirty() end
			end
		end,

		ApplyStateMachineDefinition = function(stateMachineName, graph, validStates)
			if not ServiceManager or not stateMachineName then return end
			ServiceManager.FSMMetadataCache[stateMachineName] = { Graph = graph, ValidStates = validStates }
			if ServiceManager.Store then ServiceManager.Store:MarkDirty() end
		end,
		
		ApplySyncPayload = function(data)
			if not data then return end
			if data.Scheduler then 
				SyncFunctions.ApplySyncData(data)
			end
		end
	}

	-- Register Callbacks
	-- CRITICAL: Register as "SyncClient" because server hardcodes this target ID
	if Orchestrator and Orchestrator.RegisterEntityCommandCallback then
		for entityMethod, entityCallback in pairs(SyncFunctions) do
			Orchestrator.RegisterEntityCommandCallback("SyncClient", entityMethod, entityCallback)
		end
	end

	-- Setup UI Visibility Controls
	local MainFrame = ServiceManager.GUI and ServiceManager.GUI.MainFrame

	local function SetVisible(visible)
		self.Visible = visible
		if MainFrame then
			MainFrame.Visible = visible
			MainFrame.Active = visible
			MainFrame.Interactable = visible
		end
	end

	-- Create UI Initialization FSM
	local UIInitializationFSM = Orchestrator.CreateStateMachine({
		StateMachineClass = "UIInitializationFSM",
		StateMachineId = "ServiceManager_UIInit",
		Context = {
			ServiceManager = ServiceManager,
			Orchestrator = Orchestrator,
			ShouldInitialize = true,
			OnReady = function()
				self:Log({ Level = "INFO", Message = "ServiceManager UI Entities Ready" })
			end,
			OnError = function(errorMsg)
				self:Log({ Level = "ERROR", Message = "ServiceManager UI Initialization Failed: " .. errorMsg })
			end
		}
	})
	self.UIInitializationFSM = UIInitializationFSM
	ServiceManager.FSMs.Initialization = UIInitializationFSM
	
	-- Create Tab Navigation FSM
	local TabNavigationFSM = Orchestrator.CreateStateMachine({
		StateMachineClass = "TabNavigationFSM",
		StateMachineId = "ServiceManager_TabNav",
		Context = {
			CurrentTab = ServiceManager.ActivePage or "TaskList",
			TargetTab = nil,
			Pages = ServiceManager.Pages,  -- Populated by init.luau before entity:Initialize()
			TabEntities = ServiceManager.Entities and ServiceManager.Entities.Tabs or {}
		}
	})
	self.TabNavigationFSM = TabNavigationFSM
	ServiceManager.FSMs.TabNavigation = TabNavigationFSM
	
	-- Create Mode Toggle FSM
	local ModeToggleFSM = Orchestrator.CreateStateMachine({
		StateMachineClass = "ModeToggleFSM",
		StateMachineId = "ServiceManager_ModeToggle",
		Context = {
			ServiceManager = ServiceManager,
			CurrentMode = ServiceManager.Mode or "client",
			TargetMode = nil,
			SidebarEntity = nil,  -- Will be set after initialization
			ConnectionFSM = nil,  -- Will be set below
			SetLoadingOverlay = function(sm, visible, text)
				local overlay = sm.GUI and sm.GUI.BodyContainer and sm.GUI.BodyContainer:FindFirstChild("LoadingOverlay")
				if overlay then
					overlay.Visible = visible
					if visible and text then
						local label = overlay:FindFirstChildWhichIsA("TextLabel", true)
						if label then label.Text = text end
					end
				end
			end
		}
	})
	self.ModeToggleFSM = ModeToggleFSM
	ServiceManager.FSMs.ModeToggle = ModeToggleFSM
	
	-- Create Terminal View FSM
	local TerminalFSM = Orchestrator.CreateStateMachine({
		StateMachineClass = "TerminalViewFSM",
		StateMachineId = "ServiceManager_TerminalView",
		Context = {
			SetVisible = SetVisible,
			IsTogglePressed = false,
			WindowEntity = nil  -- Will be set after initialization
		}
	})
	self.TerminalFSM = TerminalFSM
	ServiceManager.FSMs.Terminal = TerminalFSM
	
	-- Create Connection FSM
	local ConnectionFSM = Orchestrator.CreateStateMachine({
		StateMachineClass = "ConnectionStateMachine",
		StateMachineId = "ServiceManager_Connection",
		Context = {
			ServiceManager = ServiceManager,
			Orchestrator = Orchestrator,
			ApplySyncData = SyncFunctions.ApplySyncData,
			ApplySyncPayload = SyncFunctions.ApplySyncPayload
		}
	})
	self.ConnectionFSM = ConnectionFSM
	
	-- Link entities to FSMs after initialization completes
	task.defer(function()
		task.wait(0.2)  -- Give UIInitializationFSM time to complete
		
		if ServiceManager.Entities.Window then
			TerminalFSM.Context.WindowEntity = ServiceManager.Entities.Window
		end
		
		if ServiceManager.Entities.Sidebar then
			ModeToggleFSM.Context.SidebarEntity = ServiceManager.Entities.Sidebar
		end
		
		ModeToggleFSM.Context.ConnectionFSM = ConnectionFSM

		-- Update TabNavigationFSM context with created entities
		if ServiceManager.Entities.Tabs then
			TabNavigationFSM.Context.TabEntities = ServiceManager.Entities.Tabs
		end
		-- Ensure Pages reference is current
		if ServiceManager.Pages then
			TabNavigationFSM.Context.Pages = ServiceManager.Pages
		end
	end)
	
	-- Input Handling: F7 toggle
	self:Manage(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.KeyCode == Enum.KeyCode.F7 then
			TerminalFSM.Context.IsTogglePressed = true
		end
	end))

	-- NOTE: Tab click handlers and mode toggle button are already hooked
	-- by init.luau's HookTabButtons/Initialize. Those handlers delegate to
	-- the FSMs (TabNavigationFSM, ModeToggleFSM) when they exist, falling
	-- back to legacy inline code if they don't. No need to double-hook here.
	
	-- Schedule UI Update Task
	if Orchestrator.Scheduler then
		Orchestrator.Scheduler:Schedule({
			TaskName = "ServiceManager_UIUpdate",
			Priority = 5,  -- Medium priority (UI updates)
			Event = "RenderStepped",
			IsRecurringTask = true,
			TaskExecutionDelay = 0,
			TaskAction = function()
				self:UpdateUI()
			 end
		})
	end
	
	self:Log({ Level = "INFO", Message = "ServiceManager Client Entity Initialized (Logic v2)" })
end

--[[
	@description Performs throttled (10 Hz) UI updates: refreshes sidebar and bottom bar
	entities with live data from the ServiceManager.
]]
function ServiceManagerClientEntity:UpdateUI()
	local now = os.clock()
	if now - self.LastUIUpdate < self.UIRefreshRate then return end
	self.LastUIUpdate = now
	
	local sm = self.ServiceManager
	if not sm then return end
	
	-- Update Sidebar Entity
	if sm.Entities and sm.Entities.Sidebar then
		sm.Entities.Sidebar.Ping = sm.Ping
		sm.Entities.Sidebar.Mode = sm.Mode
		sm.Entities.Sidebar.ActiveService = sm.ActiveService
		sm.Entities.Sidebar.IsDisconnected = sm.Network and sm.Network.IsDisconnected
	end
	
	-- Update BottomBar Entity
	if sm.Entities and sm.Entities.BottomBar then
		local bottomBar = sm.Entities.BottomBar
		
		-- Server tick calculation
		local dt = now - (bottomBar._lastTickTime or now)
		bottomBar._lastTickTime = now
		bottomBar.ServerTick = dt > 0 and math.round(1 / dt) or 0
		
		-- Server time
		bottomBar.ServerTime = os.date("%I:%M:%S %p")
		
		-- Task count
		local service = sm.Services and sm.Services[sm.ActiveService]
		if service then
			local items = (sm.ActiveService == "Scheduler") and service.Tasks or service.StateMachines
			if items then
				local count = 0
				for _ in pairs(items) do count = count + 1 end
				bottomBar.TaskCount = count
			end
		end
		
		-- Running task count
		if sm.ActiveService == "Scheduler" and sm.Services.Scheduler and sm.Services.Scheduler.PerformanceManager then
			local activeTasks = sm.Services.Scheduler.PerformanceManager:GetActiveTasks()
			local count = 0
			for _ in pairs(activeTasks) do count = count + 1 end
			bottomBar.RunningTaskCount = count
		else
			bottomBar.RunningTaskCount = 0
		end
		
		-- User name
		local Players = game:GetService("Players")
		local owner = Players.LocalPlayer
		if owner then
			bottomBar.UserName = owner.Name
		end
	end
end

--[[
	@description Applies key-value state changes to the entity.
	@param changes { [string]: any } -- Key-value pairs of changed fields.
]]
function ServiceManagerClientEntity:ApplyChanges(changes: { [string]: any })
	for key, value in pairs(changes) do
		self[key] = value
	end
end

--[[
	@description Cancels all owned FSMs (Terminal, Connection, UIInitialization, TabNavigation, ModeToggle).
]]
--[[
	@description Cancels all owned FSMs (Terminal, Connection, UIInitialization, TabNavigation, ModeToggle).
]]
function ServiceManagerClientEntity:OnCleanup()
	if self.TerminalFSM then self.TerminalFSM:Cancel() end
	if self.ConnectionFSM then self.ConnectionFSM:Cancel() end
	if self.UIInitializationFSM then self.UIInitializationFSM:Cancel() end
	if self.TabNavigationFSM then self.TabNavigationFSM:Cancel() end
	if self.ModeToggleFSM then self.ModeToggleFSM:Cancel() end
end

return ServiceManagerClientEntity
