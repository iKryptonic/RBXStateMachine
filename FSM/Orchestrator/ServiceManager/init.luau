--!strict


local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ReactiveStore = require(script.ReactiveStore)
local ZAxisNavigator = require(script.ZAxisNavigator)
local AnimationController = require(script.AnimationController)
local AnalyticsEngine = require(script.AnalyticsEngine)
local ServiceBrain = require(script.ServiceBrain)
local GlassGUI = require(script.GlassGUI)
local Theme = require(script.Theme)

-- Subsystem modules
local TasksModule = require(script.Subsystems.TasksModule)
local FSMModule = require(script.Subsystems.FSMModule)
local EntityModule = require(script.Subsystems.EntityModule)
local NetworkModule = require(script.Subsystems.NetworkModule)
local DataStoreModule = require(script.Subsystems.DataStoreModule)
local InsightsModule = require(script.Subsystems.InsightsModule)
local ConsoleModule = require(script.Subsystems.ConsoleModule)
local LogsModule = require(script.Subsystems.LogsModule)
local ProfilerModule = require(script.Subsystems.ProfilerModule)

-- ══════════════════════════════════════════════════════════════
-- MODULE
-- ══════════════════════════════════════════════════════════════

local ServiceManager = {}

-- Internal state (set during Initialize)
local _initialized = false
local _orchestrator: any = nil
local _store: any = nil
local _navigator: any = nil
local _animationController: any = nil
local _analyticsEngine: any = nil
local _gui: any = nil
local _brainTree: ((ctx: any) -> string)? = nil
local _contextMode: string = "client"-- "client" | "server"
local _activeSubsystem: string? = nil
local _lastDataRefresh: number = 0
local _dataRefreshInterval: number = 2.0 -- refresh data every 2s (avoids excessive UI rebuilds)
local _serverData: any = nil
local _serverPollConnection: RBXScriptConnection? = nil
local _subsystemModules: { [string]: any } = {}
local _logs: { { Level: string, Message: string, Timestamp: number } } = {}
local _fpsAccum: number = 0
local _fpsFrames: number = 0
local _lastFPS: number = 60


function ServiceManager.Initialize(Orchestrator: any)
	if _initialized then return end
	_initialized = true
	ServiceManager._initialized = true
	_orchestrator = Orchestrator

	-- 1. Initialize the behavior tree builder
	ServiceBrain.Initialize(Orchestrator)

	-- 2. Create core systems
	_store = ReactiveStore.new({
		["nexus.mode"] = "client",
		["nexus.connected"] = true,
		["nexus.activeSubsystem"] = nil,
	})
	_animationController = AnimationController.new()
	_analyticsEngine = AnalyticsEngine.new()

	-- 3. Create subsystem module instances
	_subsystemModules = {
		TASKS = TasksModule.new(),
		FSM = FSMModule.new(),
		ENTITY = EntityModule.new(),
		NETWORK = NetworkModule.new(),
		DATASTORE = DataStoreModule.new(),
		INSIGHTS = InsightsModule.new(),
		CONSOLE = ConsoleModule.new(),
		LOGS = LogsModule.new(),
		PROFILER = ProfilerModule.new(),
	}

	-- 4. Build GUI
	if RunService:IsClient() then
		local player = Players.LocalPlayer
		if player then
			local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
			_gui = GlassGUI.new(playerGui)
			_gui:Build()
			_SetupGUICallbacks()
		end
	end

	-- 5. Create Z-axis navigator (needs body container from GUI)
	local bodyContainer = _gui and _gui:GetBodyContainer()
	if bodyContainer then
		_navigator = ZAxisNavigator.new(bodyContainer :: Frame)
		_RegisterRootLayers()
	end

	-- 6. Build the behavior tree
	_brainTree = ServiceBrain.Build()

	-- 7. Register scheduler task for the brain tick
	if Orchestrator.Scheduler then
		Orchestrator.Scheduler:Schedule({
			TaskName = "ServiceManagerBrainTick",
			Priority = 15, -- Background priority
			Event = "Heartbeat",
			IsRecurringTask = true,
			TaskExecutionDelay = 0,
			TaskAction = function()
				_TickBrain()
			end,
		})
	end

	-- 8. FPS tracking + per-frame perf strip animation
	if RunService:IsClient() then
		RunService.RenderStepped:Connect(function(dt)
			_fpsAccum + = dt
			_fpsFrames + = 1
			if _fpsAccum >= 0.5 then
				_lastFPS = _fpsFrames / _fpsAccum
				_fpsAccum = 0
				_fpsFrames = 0
			end
			-- Drive the TASKS perf strip at frame rate so EMA smoothing
			-- produces visibly fluid number transitions instead of 2s jumps.
			local tasksMod = _subsystemModules and _subsystemModules.TASKS
			if tasksMod and tasksMod._TickPerfStrip then
				ServiceManager._lastFPS = _lastFPS
				ServiceManager._orchestrator = _orchestrator
				ServiceManager._contextMode = _contextMode
				ServiceManager._serverData = _serverData
				pcall(tasksMod._TickPerfStrip, tasksMod, ServiceManager, dt)
			end
		end)
	end

	-- 9. Start server polling if client
	if RunService:IsClient() then
		_StartServerPolling()
	end

	-- 10. Debug bridge for cross-VM testing (Studio command bar / execute_luau).
	-- Listen for commands written to ReplicatedStorage:GetAttribute("ServiceManagerCmd").
	-- Format: "context:server" / "context:client" / "subsystem:FSM" / "click:<dot.path>" / "step:<N|live>"
	if RunService:IsClient() then
		local rs = game:GetService("ReplicatedStorage")
		local function dispatch(cmd: string?)
			if type(cmd) ~= "string" or cmd == "" then return end
			local kind, arg = cmd:match("^([^:]+):(.+)$")
			if kind == "context" then
				ServiceManager.SetContextMode(arg)
			elseif kind == "subsystem" then
				ServiceManager.SwitchSubsystem(arg)
			elseif kind == "fsmDetail" then
				-- Drill into the FSM detail layer for the given FSM id (server context)
				local fsmMod = _subsystemModules and _subsystemModules.FSM
				if fsmMod and _navigator then
					local cache = (fsmMod :: any)._fsmCache or {}
					local fsmData = cache[arg] or ((fsmMod :: any)._completedFSMs or {})[arg] or ((fsmMod :: any)._failedFSMs or {})[arg]
					if fsmData then
						(_navigator :: any)._animating = false;
						_navigator:ExpandLayer({
							Id = "fsm.detail." .. arg,
							ParentId = "FSM",
							Label = arg,
							Builder = function(f, ctx) (fsmMod :: any):_BuildFSMDetailLayer(f, ctx) end,
							Context = { Nexus = ServiceManager, FSMId = arg, FSMData = fsmData },
						})
					end
				end
			elseif kind == "fsmViz" then
				local fsmMod = _subsystemModules and _subsystemModules.FSM
				if fsmMod and _navigator then
					local cache = (fsmMod :: any)._fsmCache or {}
					local fsmData = cache[arg] or ((fsmMod :: any)._completedFSMs or {})[arg] or ((fsmMod :: any)._failedFSMs or {})[arg]
					if fsmData then
						(_navigator :: any)._animating = false;
						_navigator:ExpandLayer({
							Id = "fsm.visualizer." .. arg,
							ParentId = "fsm.detail." .. arg,
							Label = "Graph",
							Builder = function(f, ctx) (fsmMod :: any):_BuildGraphLayer(f, ctx) end,
							Context = { Nexus = ServiceManager, FSMId = arg, FSMData = fsmData },
						})
					end
				end
			elseif kind == "step" then
				if _navigator then
					local layers = (_navigator :: any)._layers or {}
					for _, layer in pairs(layers) do
						if layer.Context and layer.Id and string.find(layer.Id,"fsm.visualizer") then
							if arg == "live" then
								layer.Context.PlaybackMode = "live"
								layer.Context.PlaybackStep = nil
							else
								local n = tonumber(arg)
								if n then
									layer.Context.PlaybackMode = "step"
									layer.Context.PlaybackStep = n
								end
							end
						end
					end
					_navigator:RebuildCurrentLayer()
				end
			elseif kind == "netDetail" then
				local netMod = _subsystemModules and _subsystemModules.NETWORK
				if netMod and _navigator then
					-- find item data in netMod's caches
					local itemData = ((netMod :: any)._commandCache or {})[arg]
						or ((netMod :: any)._eventBusCache or {})[arg]
						or ((netMod :: any)._serverCallbacks or {})[arg]
					if itemData then
						(_navigator :: any)._animating = false
						_navigator:ExpandLayer({
							Id = "network.detail." .. arg,
							ParentId = "NETWORK",
							Label = arg,
							Builder = function(f, ctx) (netMod :: any):_BuildNetworkDetailLayer(f, ctx) end,
							Context = { Nexus = ServiceManager, ItemName = arg, ItemData = itemData },
						})
					end
				end
			elseif kind == "netCalls" then
				local netMod = _subsystemModules and _subsystemModules.NETWORK
				if netMod and _navigator then
					local itemData = ((netMod :: any)._commandCache or {})[arg]
						or ((netMod :: any)._eventBusCache or {})[arg]
						or ((netMod :: any)._serverCallbacks or {})[arg]
					if itemData then
						(_navigator :: any)._animating = false
						_navigator:ExpandLayer({
							Id = "network.calls." .. arg,
							ParentId = "network.detail." .. arg,
							Label = "Calls",
							Builder = function(f, ctx) (netMod :: any):_BuildCallsHistoryLayer(f, ctx) end,
							Context = {
								Nexus = ServiceManager,
								ItemName = arg,
								ItemData = itemData,
								RecentCalls = itemData.RecentCalls or {},
							},
						})
					end
				end
			elseif kind == "consolePush" then
				-- Test/debug helper: push a synthetic line into the console
				-- output buffer. Used by integration tests to verify that
				-- buffered lines survive context switches and layer rebuilds.
				local consoleMod = _subsystemModules and _subsystemModules.CONSOLE
				if consoleMod and (consoleMod :: any)._PushLine then
					pcall(function()
						(consoleMod :: any):_PushLine("INFO", arg)
					end)
				end
			elseif kind == "consoleEnter" then
				-- Test/debug helper: simulate user typing `arg` then pressing
				-- Enter on the console input box. Returns the post-enter Text
				-- via attribute "ServiceManagerResult" so callers can verify
				-- whitespace/leading-space regressions.
				local consoleMod = _subsystemModules and _subsystemModules.CONSOLE
				local inputBox = consoleMod and (consoleMod :: any)._inputBox
				if inputBox then
					inputBox:CaptureFocus()
					task.wait(0.1)
					inputBox.Text = arg
					task.wait(0.1)
					-- Simulate Enter via :ReleaseFocus(true) — fires FocusLost(enterPressed=true).
					inputBox:ReleaseFocus(true)
					task.wait(0.3)
					rs:SetAttribute("ServiceManagerResult",
						string.format("text=%q,len=%d,cursor=%d,focused=%s",
							inputBox.Text, #inputBox.Text, inputBox.CursorPosition,
							tostring(inputBox:IsFocused())))
				end
			elseif kind == "dumpCalls" then
				-- Test/debug helper: dump the ArgsStruct of the most recent
				-- call for the given network item via ServiceManagerResult.
				local netMod = _subsystemModules and _subsystemModules.NETWORK
				if netMod then
					local d = ((netMod :: any)._commandCache or {})[arg]
						or ((netMod :: any)._eventBusCache or {})[arg]
					if d and d.RecentCalls and #d.RecentCalls > 0 then
						local last = d.RecentCalls[#d.RecentCalls]
						local lines = {}
						table.insert(lines,"Args=" .. tostring(last.Args))
						if last.ArgsStruct then
							table.insert(lines,"ArgsStruct.n=" .. tostring(last.ArgsStruct.n))
							for i = 1, last.ArgsStruct.n or 0 do
								local v = last.ArgsStruct[i]
								table.insert(lines, string.format("[%d] type=%s", i, type(v)))
								if type(v) == "table" then
									for k, val in pairs(v) do
										table.insert(lines, string.format("  .%s = %s (%s)", tostring(k), tostring(val), type(val)))
									end
								end
							end
						else
							table.insert(lines,"NO ArgsStruct")
						end
						rs:SetAttribute("ServiceManagerResult", table.concat(lines,"\n"))
					else
						rs:SetAttribute("ServiceManagerResult","no calls for " .. tostring(arg))
					end
				end
			end
		end
		-- Initial dispatch + watch
		dispatch(rs:GetAttribute("ServiceManagerCmd") :: any)
		rs:GetAttributeChangedSignal("ServiceManagerCmd"):Connect(function()
			dispatch(rs:GetAttribute("ServiceManagerCmd") :: any)
		end)
	end

	_Log("INFO","ServiceManager initialized")
end


function ServiceManager.Show()
	if _gui then
		_gui:Show()
		-- Default to TASKS if no subsystem selected
		if not _activeSubsystem then
			ServiceManager.SwitchSubsystem("TASKS")
		end
	end
end


function ServiceManager.Hide()
	if _gui then _gui:Hide() end
end


function ServiceManager.Toggle()
	if _gui then
		if _gui:IsVisible() then
			ServiceManager.Hide()
		else
			ServiceManager.Show()
		end
	end
end


function ServiceManager.SwitchSubsystem(name: string)
	if not _subsystemModules[name] then return end
	_activeSubsystem = name
	_store:Set("nexus.activeSubsystem", name)

	-- Pre-fetch data so the builder has content on the first render
	local module = _subsystemModules[name]
	if module and module.FetchData then
		pcall(module.FetchData, module, ServiceManager)
	end

	-- Navigate the Z-axis to the root layer of this subsystem
	if _navigator then
		_navigator:NavigateToRoot(name)
	end

	-- Update GUI sidebar (suppress callback to prevent recursive SwitchSubsystem calls)
	if _gui then
		_gui:SelectSubsystem(name, true)
	end

	-- Force immediate data refresh
	_lastDataRefresh = 0
end
--[=[
	@description Updates module state through `ServiceManager.SetContextMode`.
]=]

function ServiceManager.SetContextMode(mode: string)
	if mode ~= "client" and mode ~= "server" then return end
	if mode == _contextMode then return end -- noop on same-mode click

	local previousMode = _contextMode
	_contextMode = mode
	_store:Set("nexus.mode", mode)

	if _gui then
		_gui:SetContextMode(mode)
		_gui:UpdateStatusBar({ Mode = mode })
		-- Hide insight toast that was for previous context.
		local toast = (_gui :: any)._insightToast
		if toast and toast.Visible then toast.Visible = false end
	end

	-- Stop any pulses anchored to drill-down frames we're about to discard.
	if _animationController and (_animationController :: any)._pulses then
		for id, _ in pairs((_animationController :: any)._pulses) do
			pcall(function() _animationController:StopPulse(id) end)
		end
	end

	-- When switching to server mode, immediately poll for server data SYNCHRONOUSLY
	-- so the UI doesn't render an empty state for one frame while waiting for the
	-- 2s poll cycle. The Request call is itself non-blocking enough on the client
	-- (it's a RemoteFunction:InvokeServer round-trip).
	if mode == "server" then
		local success, data = pcall(function()
			return _orchestrator.Request("ServiceManager_ServerSnapshot")
		end)
		if success and data then
			_serverData = data
			ServiceManager._serverData = data
			_store:Set("nexus.connected", true)
		else
			_store:Set("nexus.connected", false)
			_Log("WARN","Server poll failed on mode switch: " .. tostring(data))
		end
	end

	-- Drop drill-down stack: a layer captured in old context is stale (its
	-- Context table holds references to client/server-specific data).
	-- Re-rendering the root for the active subsystem gives the user a fresh
	-- view of the new context's data.
	if _navigator and _activeSubsystem then
		_navigator:NavigateToRoot(_activeSubsystem)
	end

	-- Push a context-switch divider into the console output buffer so the
	-- user can see history but knows where the boundary is. We don't clear
	-- history because that loses useful debugging context.
	local consoleMod = _subsystemModules and _subsystemModules.CONSOLE
	if consoleMod and (consoleMod :: any)._PushLine then
		pcall(function()
			(consoleMod :: any):_PushLine(
				"SYSTEM",
				string.format("─── context: %s → %s ───", string.upper(previousMode or "?"), string.upper(mode))
			)
		end)
	end

	-- Reset the perf graph history so the FPS sparkline doesn't jump between
	-- client-VM and server-reported values (causes "janky" lines at the seam).
	local tasksMod = _subsystemModules and _subsystemModules.TASKS
	if tasksMod then
		if (tasksMod :: any)._perfHistory then table.clear((tasksMod :: any)._perfHistory) end
		local sp = (tasksMod :: any)._smoothPerf
		local pp = (tasksMod :: any)._prevPerf
		if sp then sp.FPS = 60; sp.MemoryMB = 0; sp.ActiveTasks = 0; sp.FrameBudgetMs = 0 end
		if pp then pp.FPS = 60; pp.MemoryMB = 0; pp.ActiveTasks = 0; pp.FrameBudgetMs = 0 end
		local pd = (tasksMod :: any)._perfDirections
		if pd then pd.FPS = 0; pd.MemoryMB = 0; pd.ActiveTasks = 0; pd.FrameBudgetMs = 0 end
	end

	-- Force every subsystem to re-fetch on the next tick.
	_lastDataRefresh = 0

	_Log("INFO","Context mode switched to: " .. mode)
end


function ServiceManager.GetStore(): any
	return _store
end


function ServiceManager.Destroy()
	if _serverPollConnection then
		_serverPollConnection:Disconnect()
		_serverPollConnection = nil
	end

	if _navigator then _navigator:Destroy() end
	if _animationController then
		-- Stop all pulses
		for id, _ in pairs(_animationController._pulses) do
			_animationController:StopPulse(id)
		end
	end
	if _analyticsEngine then _analyticsEngine:Destroy() end
	if _store then _store:Destroy() end
	if _gui then _gui:Destroy() end

	for _, mod in pairs(_subsystemModules) do
		if mod.Destroy then mod:Destroy() end
	end

	table.clear(_subsystemModules)
	table.clear(_logs)
	_initialized = false
	_Log("INFO","ServiceManager destroyed")
end

-- ══════════════════════════════════════════════════════════════
-- PROPERTIES (used by ServiceBrain context)
-- ══════════════════════════════════════════════════════════════

-- These are accessed by the brain tree via the context object
ServiceManager._initialized = _initialized
ServiceManager.ActiveSubsystem = _activeSubsystem
ServiceManager._lastDataRefresh = _lastDataRefresh
ServiceManager._dataRefreshInterval = _dataRefreshInterval
ServiceManager.Store = _store
ServiceManager._analyticsEngine = _analyticsEngine
ServiceManager._animationController = _animationController
ServiceManager._subsystemModules = _subsystemModules
ServiceManager._orchestrator = _orchestrator
ServiceManager._contextMode = _contextMode
ServiceManager._serverData = _serverData
ServiceManager._navigator = _navigator
ServiceManager._logs = _logs
ServiceManager._lastFPS = _lastFPS
ServiceManager._Log = nil -- Will be set after _Log is defined below

-- ══════════════════════════════════════════════════════════════
-- PRIVATE: BRAIN TICK
-- ══════════════════════════════════════════════════════════════

function _TickBrain()
	if not _initialized or not _brainTree then return end
	if _gui and not _gui:IsVisible() then return end -- don't tick when hidden

	-- Update live properties for the context object
	ServiceManager._initialized = _initialized
	ServiceManager.ActiveSubsystem = _activeSubsystem
	ServiceManager._lastDataRefresh = _lastDataRefresh
	ServiceManager._dataRefreshInterval = _dataRefreshInterval
	ServiceManager.Store = _store
	ServiceManager._analyticsEngine = _analyticsEngine
	ServiceManager._animationController = _animationController
	ServiceManager._subsystemModules = _subsystemModules
	ServiceManager._orchestrator = _orchestrator
	ServiceManager._contextMode = _contextMode
	ServiceManager._serverData = _serverData
	ServiceManager._navigator = _navigator
	ServiceManager._logs = _logs
	ServiceManager._lastFPS = _lastFPS
	ServiceManager._Log = _Log

	-- Run the behavior tree
	local context = { Nexus = ServiceManager }
	local ok, result = pcall(_brainTree :: any, context)
	if not ok then
		_Log("ERROR","Brain tick failed: " .. tostring(result))
	end

	-- Sync _lastDataRefresh back from the module
	_lastDataRefresh = ServiceManager._lastDataRefresh

	-- Update status bar with live data
	if _gui then
		local insightCount = 0
		if _analyticsEngine then
			insightCount = #_analyticsEngine:GetActiveInsights()
		end
		_gui:UpdateStatusBar({
			Connected = _store:Get("nexus.connected") ~= false,
			Mode = _contextMode,
			InsightCount = insightCount,
			FPS = _lastFPS,
		})

		-- Show toast for new critical insights
		if _analyticsEngine then
			local insights = _analyticsEngine:GetActiveInsights()
			for _, insight in ipairs(insights) do
				if insight.Severity == "CRITICAL" and not insight._toasted then
					insight._toasted = true
					_gui:ShowInsightToast(
						insight.Title,
						insight.Description,
						insight.Severity,
						5
					)
					break -- one toast at a time
				end
			end
		end
	end
end


function ServiceManager:_SyncClientContext()
	-- Client mode: data comes directly from the Orchestrator module
	-- No additional sync needed for client context
end

-- ══════════════════════════════════════════════════════════════
-- PRIVATE: SERVER POLLING
-- ══════════════════════════════════════════════════════════════

function _StartServerPolling()
	if not RunService:IsClient() then return end

	-- Poll server snapshot regardless of context mode so the FSM/Network/Entity
	-- pages can show a UNION of client + server data with origin badges.
	-- Cadence is faster in server mode (2s) and slower in client mode (5s) to
	-- limit network load when not actively viewing server data.
	task.spawn(function()
		while _initialized do
			local success, data = pcall(function()
				return _orchestrator.Request("ServiceManager_ServerSnapshot")
			end)

			if success and data then
				_serverData = data
				ServiceManager._serverData = data
				_store:Set("nexus.connected", true)
				if _contextMode == "server" then
					-- Force brain to re-fetch subsystem data with new server snapshot
					_lastDataRefresh = 0
				end
			else
				_store:Set("nexus.connected", false)
				if _contextMode == "server" then
					_Log("WARN","Server poll failed: " .. tostring(data))
				end
			end

			task.wait(if _contextMode == "server" then 2 else 5)
		end
	end)
end

-- ══════════════════════════════════════════════════════════════
-- PRIVATE: REGISTER Z-AXIS ROOT LAYERS
-- ══════════════════════════════════════════════════════════════

function _RegisterRootLayers()
	if not _navigator then return end

	local subsystems = {"TASKS","FSM","ENTITY","NETWORK","DATASTORE","INSIGHTS","CONSOLE","LOGS","PROFILER" }
	for _, name in ipairs(subsystems) do
		local module = _subsystemModules[name]
		if module then
			_navigator:RegisterRootLayer(name, name, function(frame: Frame, ctx: any)
				ctx = ctx or {}
				ctx.Nexus = ServiceManager
				module:BuildRootLayer(frame, ctx)
			end)
		end
	end

	-- Hook breadcrumb changes to update the GUI breadcrumb bar
	_navigator:OnBreadcrumbChanged(function(crumbs)
		if _gui then
			_gui:UpdateBreadcrumbs(crumbs, function(layerId: string)
				_navigator:CollapseToLayer(layerId)
			end)
		end
	end)
end

-- ══════════════════════════════════════════════════════════════
-- PRIVATE: GUI CALLBACKS
-- ══════════════════════════════════════════════════════════════

function _SetupGUICallbacks()
	if not _gui then return end

	-- Sidebar subsystem selection
	_gui:OnSubsystemSelected(function(name: string)
		ServiceManager.SwitchSubsystem(name)
	end)

	-- Context toggle handler
	_gui:OnContextToggle(function(mode: string)
		ServiceManager.SetContextMode(mode)
	end)

	-- Close handler
	_gui:OnClose(function()
		-- Just hide, don't destroy
	end)

	-- Minimize handler
	_gui:OnMinimizeToggle(function(minimized: boolean)
		_Log("INFO", if minimized then"Window minimized" else"Window restored")
	end)

	-- Back button handler — navigate up one level in the drill-down stack
	_gui:OnBackClick(function()
		if _navigator then
			local crumbs = _navigator:GetBreadcrumbs()
			if #crumbs >= 2 then
				local target = crumbs[#crumbs - 1]
				_navigator:CollapseToLayer(target.Id)
			end
		end
	end)

	-- Re-clicking active subsystem returns to its root view
	_gui:OnSubsystemReselected(function(name: string)
		if _navigator then
			_navigator:NavigateToRoot(name)
		end
		_lastDataRefresh = 0
	end)
end

-- ══════════════════════════════════════════════════════════════
-- PRIVATE: LOGGING
-- ══════════════════════════════════════════════════════════════

function _Log(level: string, message: string)
	local entry = {
		Level = level,
		Message = message,
		Timestamp = os.clock(),
	}
	table.insert(_logs, entry)
	if #_logs > 500 then table.remove(_logs, 1) end

	if _orchestrator and _orchestrator.Logger then
		_orchestrator.Logger:Log({ Level = level, Message = "[ServiceManager] " .. message })
	end
end

-- Now that _Log is defined, set it on the module table
ServiceManager._Log = _Log


function ServiceManager.RegisterServerHandlers(Orchestrator: any)
	if not RunService:IsServer() then return end

	-- Idempotency guard: if RegisterServerHandlers is called twice (hot-reload,
	-- plugin re-init, dev-tools reattach), the second call would double-register
	-- the StateMachineRegistered listener and start writing to _fsmShadow twice.
	-- This guard makes re-registration a no-op so the framework stays stable
	-- across multi-init scenarios.
	if ServiceManager._serverHandlersRegistered then
		_Log("WARN","RegisterServerHandlers called twice; ignoring second registration")
		return
	end
	ServiceManager._serverHandlersRegistered = true

	-- ── Shadow FSM Registry ──────────────────────────────────────
	-- The Factory auto-unregisters & destroys FSMs on completion/failure/cancel,
	-- so by the time the client polls, finished FSMs are gone from the real registry.
	-- This shadow keeps a serialised snapshot of every FSM that ever existed so the
	-- ServiceManager FSM page can always display them. Bounded LRU eviction
	-- prevents unbounded growth on long-running servers.
	local SHADOW_CAP = 200
	local _fsmShadow: { [string]: any } = {}

	-- Track insertion order for FIFO eviction. Most-recently-touched at the back.
	local _fsmShadowOrder: { string } = {}
	local function _touchShadow(id: string)
		-- O(N) but cap is small (200); fine.
		for i, v in ipairs(_fsmShadowOrder) do
			if v == id then
				table.remove(_fsmShadowOrder, i)
				break
			end
		end
		table.insert(_fsmShadowOrder, id)
		while #_fsmShadowOrder > SHADOW_CAP do
			local oldest = table.remove(_fsmShadowOrder, 1)
			if oldest then _fsmShadow[oldest :: string] = nil end
		end
	end

	local function _CaptureFSMSnapshot(id: string, fsm: any): any
		local stateNames = {}
		if fsm._states then
			for sName, _ in pairs(fsm._states) do
				table.insert(stateNames, sName)
			end
		end
		local status = "active"
		if fsm.IsActive == false then
			if fsm.Error or fsm._error then
				status = "failed"
			else
				status = "completed"
			end
		end

		-- Build transition history from Logger if available. Copy the array
		-- so the shadow has its own ring buffer — otherwise BaseStateMachine's
		-- Destroy() does `table.clear(self.TransitionHistory)` which would
		-- wipe the shadow's history too (shared table reference). The shadow
		-- needs to outlive the live FSM so the visualizer can step through
		-- transitions even after the FSM completed.
		local transitionHistory = {}
		local src = fsm.TransitionHistory or fsm._transitionHistory
		if type(src) == "table" then
			for i, e in ipairs(src) do
				transitionHistory[i] = e
			end
		end
		-- _transitions is a static config (state → allowed states), shallow-copy
		-- to detach from the FSM's reference for the same reason.
		local transitionsCopy
		if type(fsm._transitions) == "table" then
			transitionsCopy = {}
			for k, v in pairs(fsm._transitions) do
				if type(v) == "table" then
					local arr = {}
					for i, x in ipairs(v) do arr[i] = x end
					transitionsCopy[k] = arr
				else
					transitionsCopy[k] = v
				end
			end
		end

		return {
			Name = fsm.Name or id,
			State = fsm.State,
			CurrentState = fsm.State,
			IsActive = fsm.IsActive,
			Status = status,
			Priority = fsm.Priority,
			StateDuration = fsm.StateDuration or 0,
			TotalDuration = fsm.TotalDuration or 0,
			TransitionCount = fsm.TransitionCount or 0,
			States = stateNames,
			TransitionHistory = transitionHistory,
			_transitions = transitionsCopy,
			CreatedAt = fsm.CreatedAt or fsm._createdAt or os.clock(),
			LastTransition = fsm.LastTransitionTime or fsm._lastTransitionTime or 0,
			Error = fsm.Error or fsm._error,
			IsStalled = fsm.IsStalled or fsm._isStalled or false,
			EntityId = fsm.EntityId or fsm._entityId
				or (fsm.Context and type(fsm.Context) == "table" and fsm.Context.EntityId),
			Perf = fsm.Perf or {},
			ManagedInstances = (function()
				if type(fsm.GetManagedInstances) ~= "function" then return nil end
				local ok3, managed = pcall(fsm.GetManagedInstances, fsm)
				if not ok3 or not managed or #managed == 0 then return nil end
				local list = {}
				for _, entry in ipairs(managed) do
					table.insert(list, {
						Label = entry.Label,
						ClassName = entry.Instance and entry.Instance.ClassName or "?",
						Name = entry.Instance and entry.Instance.Name or "?",
						CreatedAt = entry.CreatedAt,
					})
				end
				return list
			end)(),
		}
	end

	-- Seed the shadow with any FSMs that already exist
	pcall(function()
		local Factory = Orchestrator.Factory
		if Factory and Factory.Registry then
			for id, fsm in pairs(Factory.Registry.GetAllStateMachines()) do
				_fsmShadow[id] = _CaptureFSMSnapshot(id, fsm)
				_touchShadow(id)
			end
		end
	end)

	-- Watch for newly registered FSMs and track their lifecycle
	-- NOTE: We store a reference to the live FSM object in _fsmLiveRefs so we can
	-- detect completion at snapshot time. We cannot rely on Completed/Failed/Cancelled
	-- signal handlers because the Factory's cleanup runs first and destroys the FSM
	-- (and its signals) before our handlers fire.
	local _fsmLiveRefs: { [string]: any } = {}

	pcall(function()
		local Factory = Orchestrator.Factory
		if Factory and Factory.Registry and Factory.Registry.StateMachineRegistered then
			Factory.Registry.StateMachineRegistered:Connect(function(id: string, fsm: any)
				-- Capture initial snapshot and keep a live reference
				_fsmShadow[id] = _CaptureFSMSnapshot(id, fsm)
				_fsmLiveRefs[id] = fsm
				_touchShadow(id)

				-- Update on state change (fires DURING execution, before destroy)
				if fsm.StateChanged then
					fsm.StateChanged:Connect(function(newState: string)
						if _fsmShadow[id] then
							local prevState = _fsmShadow[id].CurrentState
							_fsmShadow[id].State = newState
							_fsmShadow[id].CurrentState = newState
							_fsmShadow[id].TransitionCount = fsm.TransitionCount or (_fsmShadow[id].TransitionCount + 1)
							_fsmShadow[id].StateDuration = fsm.StateDuration or 0
							_fsmShadow[id].TotalDuration = fsm.TotalDuration or 0
							_fsmShadow[id].LastTransition = os.clock()

							-- Append the rich entry (Args, WaitSpan, ContextSnapshot, TransitionId)
							-- that BaseStateMachine.ChangeState just appended to the FSM. Copy
							-- it into the shadow's own history so it survives the FSM's destroy.
							if prevState ~= newState then
								local hist = _fsmShadow[id].TransitionHistory
								if type(hist) == "table" then
									local liveHist = fsm.TransitionHistory
									local entry
									if type(liveHist) == "table" and #liveHist > 0 then
										local src = liveHist[#liveHist]
										-- Shallow-copy so subsequent table.clear on the FSM
										-- doesn't blow away our entry.
										entry = {
											From = src.From,
											To = src.To,
											Time = src.Time,
											Args = src.Args,
											WaitSpan = src.WaitSpan,
											ContextSnapshot = src.ContextSnapshot,
											TransitionId = src.TransitionId,
										}
									else
										-- Fallback (FSM didn't keep history for some reason)
										entry = {
											From = prevState or "(start)",
											To = newState,
											Time = os.clock(),
										}
									end
									table.insert(hist, entry)
									-- Cap shadow history at 100 to mirror the FSM's cap
									while #hist > 100 do table.remove(hist, 1) end
								end
							end
						end
					end)
				end
			end)
		end
	end)

	Orchestrator.RegisterServerRequestCallback("ServiceManager_ServerSnapshot", function(_player: Player)
		local Factory = Orchestrator.Factory
		local Scheduler = Orchestrator.Scheduler
		local NetworkManager = Orchestrator.NetworkManager

		local snapshot: { [string]: any } = {}

		-- Tasks — wrapped in { List = {}, Performance = {} } to match TasksModule expectations
		if Scheduler then
			local taskList = {}
			local allTasks = Scheduler.Tasks or {}
			local running = Scheduler._running or {}
			for name, taskDef in pairs(allTasks) do
				local perf = taskDef.Perf or taskDef._perf or {}
				local runCount = taskDef.RunCount or 0
				local totalRunTime = taskDef.TotalRunTime or 0
				local avgTimeMs = if runCount > 0 then (totalRunTime / runCount) * 1000 else 0
				taskList[name] = {
					Name = name,
					-- Status is derived in the consumer (TasksModule) which
					-- tracks per-fetch deltas to distinguish ACTIVE/IDLE.
					-- We don't pre-compute it here because we have no
					-- "previous tick" to diff against on the server side.
					Status = nil,
					Priority = taskDef.Priority or 5,
					Event = taskDef.Event,
					IsRecurringTask = taskDef.IsRecurringTask,
					-- Use RunCount (the actual field) — the legacy
					-- ExecutionCount alias was always nil so the dashboard
					-- showed 0 executions for everything in server mode.
					RunCount = runCount,
					ExecutionCount = runCount,
					LastRun = taskDef.LastRunTime or 0,
					LastRunTime = taskDef.LastRunTime or 0,
					-- IsRunning: the task is currently mid-execution. The
					-- Scheduler tracks this via _running[name] = task object.
					IsRunning = running[name] ~= nil,
					-- Pass Delay through so the consumer can adapt the
					-- ACTIVE_WINDOW to the task's recurrence cadence (a 5s
					-- recurring task should stay ACTIVE between ticks).
					TaskExecutionDelay = taskDef.Delay or 0,
					Delay = taskDef.Delay or 0,
					AvgTimeMs = (perf.AvgExecutionTime and perf.AvgExecutionTime * 1000) or avgTimeMs,
					MaxTimeMs = (perf.MaxExecutionTime and perf.MaxExecutionTime * 1000) or ((taskDef.MaxRunTime or 0) * 1000),
					Errors = taskDef.Errors or taskDef.ErrorCount or 0,
					Perf = perf,
				}
			end

			local perfData = {}
			if Scheduler.PerformanceManager then
				local pm = Scheduler.PerformanceManager
				perfData = {
					FPS = pm.FPS or 0,
					FrameBudget = pm.FrameBudget or 0,
					TasksPerFrame = pm.TasksPerFrame or 0,
					MemoryMB = collectgarbage("count") / 1024,
					ActiveTasks = pm.ActiveTasks or 0,
				}
			end

			snapshot.Tasks = {
				List = taskList,
				Performance = perfData,
			}
		end

		-- FSMs — use shadow registry so completed/failed FSMs are still visible
		-- 1. Update shadow for any FSMs still alive in the registry
		if Factory and Factory.Registry then
			local liveIds: { [string]: boolean } = {}
			pcall(function()
				for id, fsm in pairs(Factory.Registry.GetAllStateMachines()) do
					_fsmShadow[id] = _CaptureFSMSnapshot(id, fsm)
					_fsmLiveRefs[id] = fsm
					_touchShadow(id)
					liveIds[id] = true
				end
			end)

			-- 2. For shadow entries NOT in the live registry, infer final status
			--    The Factory destroys FSMs on completion/failure/cancel so they
			--    disappear from the registry. We use the cached live ref to
			--    read IsActive and Error before marking.
			for id, shadow in pairs(_fsmShadow) do
				if not liveIds[id] and shadow.Status == "active" then
					local ref = _fsmLiveRefs[id]
					if ref then
						-- FSM was destroyed — read its final state
						local err = rawget(ref,"Error") or rawget(ref,"_error")
						local lastState = rawget(ref,"State") or shadow.CurrentState
						shadow.CurrentState = lastState
						shadow.State = lastState
						shadow.IsActive = false
						if err then
							shadow.Status = "failed"
							shadow.Error = tostring(err)
						else
							shadow.Status = "completed"
						end
					else
						-- No live ref available; assume completed
						shadow.IsActive = false
						shadow.Status = "completed"
					end
				end
			end
		end
		snapshot.FSM = { StateMachines = _fsmShadow }

		-- Entities — flat map, matches EntityModule expectations
		if Factory and Factory.Registry then
			local entities = {}
			for id, entity in pairs(Factory.Registry.GetAllEntities()) do
				local pp = entity._privateProperties
				local schemaKeys = {}
				local dataMap = {}

				if pp and pp.Schema then
					for key, def in pairs(pp.Schema) do
						table.insert(schemaKeys, {
							Key = key,
							Type = def.Type or "any",
							Persist = def.Persist or false,
							Replicate = def.Replicate or false,
						})
					end
				end

				if pp and pp.Data then
					for key, val in pairs(pp.Data) do
						dataMap[key] = {
							Key = key,
							Value = tostring(val),
							Type = typeof(val),
						}
					end
				end

				-- Flatten version history (rich form { Version, Time, Changes })
				-- to flat per-field entries, matching the local extractor.
				-- Without this, entities viewed in the SERVER context show 0
				-- history entries even when the live entity has full history.
				local versionHistory = {}
				if pp and pp._versionHistory and type(pp._versionHistory) == "table" then
					for _, vEntry in ipairs(pp._versionHistory) do
						if vEntry.Changes then
							for fieldName, change in pairs(vEntry.Changes) do
								table.insert(versionHistory, {
									Version = vEntry.Version,
									Time = vEntry.Time,
									Field = fieldName,
									From = change.From,
									To = change.To,
								})
							end
						end
					end
				end

				entities[id] = {
					Name = pp and pp.Name or id,
					ClassName = pp and pp.Name or "Unknown",
					IsValid = pp and pp.IsValid or false,
					Version = pp and pp.Version or 0,
					SchemaKeys = schemaKeys,
					Data = dataMap,
					VersionHistory = versionHistory,
				}
			end
			snapshot.Entities = entities
		end

		-- Network — includes EventBuses, Commands, and Remotes to match NetworkModule expectations
		if NetworkManager then
			local network: { [string]: any } = {}
			network.EventBuses = {}
			network.Commands = {}
			network.Remotes = {}

			if NetworkManager.EventBuses then
				for name, bus in pairs(NetworkManager.EventBuses) do
					local subCount = 0
					pcall(function()
						if type(bus) == "table" then
							if bus._handlers then subCount = #bus._handlers
							elseif bus._connections then subCount = #bus._connections
							elseif bus._subscribers then subCount = #bus._subscribers end
						end
					end)
					local busStats = NetworkManager._busStats and NetworkManager._busStats[name]
					network.EventBuses[name] = {
						Name = name,
						Type = "EventBus",
						Subscribers = subCount,
						MessageCount = busStats and busStats.Count or 0,
						LastFired = busStats and busStats.LastFired or 0,
						RecentCalls = busStats and busStats.RecentCalls or {},
						IsActive = subCount > 0,
					}
				end
			end

			if NetworkManager.ServerRequestCallbacksSync then
				for name, _ in pairs(NetworkManager.ServerRequestCallbacksSync) do
					local stats = NetworkManager._invokeStats and NetworkManager._invokeStats[name]
					local rstats = NetworkManager._remoteStats and NetworkManager._remoteStats["Remote:ServerRequest:" .. name]
					network.Commands[name] = {
						Name = name,
						Type = "ServerRequest",
						HasHandler = true,
						Subscribers = 1,
						MessageCount = stats and stats.Count or (rstats and rstats.Count) or 0,
						LastInvoked = stats and stats.LastInvoked or (rstats and rstats.LastFired) or 0,
						RecentCalls = (rstats and rstats.RecentCalls) or {},
						Properties = { Mode = "Sync" },
					}
				end
			end

			if NetworkManager.ServerRequestCallbacksAsync then
				for name, _ in pairs(NetworkManager.ServerRequestCallbacksAsync) do
					if not network.Commands[name] then
						local stats = NetworkManager._invokeStats and NetworkManager._invokeStats[name]
						local rstats = NetworkManager._remoteStats and NetworkManager._remoteStats["Remote:ServerRequest:" .. name]
						network.Commands[name] = {
							Name = name,
							Type = "ServerRequest",
							HasHandler = true,
							Subscribers = 1,
							MessageCount = stats and stats.Count or (rstats and rstats.Count) or 0,
							LastInvoked = stats and stats.LastInvoked or (rstats and rstats.LastFired) or 0,
							RecentCalls = (rstats and rstats.RecentCalls) or {},
							Properties = { Mode = "Async" },
						}
					end
				end
			end

			if NetworkManager.EntityCommandCallbacks then
				for entityId, commands in pairs(NetworkManager.EntityCommandCallbacks) do
					if type(commands) == "table" then
						for cmdName, _ in pairs(commands) do
							local fullName = entityId ..":" .. cmdName
							local stats = NetworkManager._invokeStats and NetworkManager._invokeStats[fullName]
							local rstats = NetworkManager._remoteStats and NetworkManager._remoteStats["Remote:EntityCommand:" .. fullName]
							network.Commands[fullName] = {
								Name = fullName,
								Type = "EntityCommand",
								HasHandler = true,
								Subscribers = 1,
								MessageCount = stats and stats.Count or (rstats and rstats.Count) or 0,
								LastInvoked = stats and stats.LastInvoked or (rstats and rstats.LastFired) or 0,
								RecentCalls = (rstats and rstats.RecentCalls) or {},
								Properties = { EntityId = entityId, Command = cmdName },
							}
						end
					end
				end
			end

			if NetworkManager.RemoteEvents then
				for name, re in pairs(NetworkManager.RemoteEvents) do
					local rstats = NetworkManager._remoteStats and NetworkManager._remoteStats["Remote:" .. name]
					network.Remotes[name] = {
						Name = name,
						Type = "RemoteEvent",
						ClassName = typeof(re) == "Instance" and re.ClassName or "Signal",
						MessageCount = rstats and rstats.Count or 0,
						LastFired = rstats and rstats.LastFired or 0,
						RecentCalls = rstats and rstats.RecentCalls or {},
					}
				end
			end

			-- Also include remote instances directly on NM
			local remoteNames = {"OrchestratorEvent","OrchestratorFunction","EntityUpdateEvent","EntityCommandEvent" }
			for _, remoteName in ipairs(remoteNames) do
				local remote = NetworkManager[remoteName]
				if remote and not network.Remotes[remoteName] then
					local rstats = NetworkManager._remoteStats and NetworkManager._remoteStats["Remote:" .. remoteName]
					network.Remotes[remoteName] = {
						Name = remoteName,
						Type = (typeof(remote) == "Instance" and remote.ClassName) or "RemoteFunction",
						ClassName = typeof(remote) == "Instance" and remote.ClassName or "Signal",
						MessageCount = rstats and rstats.Count or 0,
						LastFired = rstats and rstats.LastFired or 0,
						RecentCalls = rstats and rstats.RecentCalls or {},
					}
				end
			end

			-- Server callback list
			network.ServerCallbacks = {}
			if NetworkManager.ServerRequestCallbacksSync then
				for name, _ in pairs(NetworkManager.ServerRequestCallbacksSync) do
					network.ServerCallbacks[name] = { Name = name, Type = "ServerRequest", Mode = "Sync" }
				end
			end
			if NetworkManager.ServerRequestCallbacksAsync then
				for name, _ in pairs(NetworkManager.ServerRequestCallbacksAsync) do
					if not network.ServerCallbacks[name] then
						network.ServerCallbacks[name] = { Name = name, Type = "ServerRequest", Mode = "Async" }
					end
				end
			end

			snapshot.Network = network
		end

		-- DataStore — matches DataStoreModule expectations
		if Factory and Factory.Registry then
			local stores: { [string]: any } = { Stores = {}, Operations = {} }
			local dsEntity = Factory.Registry.GetEntity("DataStoreSystem")
			if dsEntity then
				local pp = dsEntity._privateProperties
				if pp and pp.Data then
					for key, val in pairs(pp.Data) do
						stores.Stores[key] = {
							Name = key,
							FieldCount = if type(val) == "table" then _CountKeys(val) else 0,
							Status = "active",
							Version = pp.Version or 0,
						}
					end
				end
			end
			snapshot.DataStore = stores
		end

		-- System metrics
		snapshot.Memory = collectgarbage("count") -- KB
		snapshot.Timestamp = os.clock()

		-- Instance memory audit — surfaces Roblox engine memory (mesh/texture data)
		-- that gcinfo() can't see. Identifies heavy services and top offenders.
		do
			local instMem: { [string]: any } = { Services = {}, TopOffenders = {}, TotalDescendants = 0 }
			local serviceNames = {"ReplicatedStorage","Workspace","ServerScriptService","ServerStorage","Lighting","StarterGui","StarterPlayer","SoundService"}
			for _, svcName in ipairs(serviceNames) do
				local ok2, svc = pcall(function() return game:GetService(svcName) end)
				if ok2 and svc then
					local c = 0
					for _ in svc:GetDescendants() do c + = 1 end
					instMem.Services[svcName] = c
					instMem.TotalDescendants + = c
				end
			end
			-- Top offenders: children of RS/Workspace with many descendants
			local rs2 = game:FindFirstChild("ReplicatedStorage")
			if rs2 then
				for _, child in rs2:GetChildren() do
					local c = 0
					for _ in child:GetDescendants() do c + = 1 end
					if c > 50 then
						table.insert(instMem.TopOffenders, { Name = child.Name, Class = child.ClassName, Count = c, Service = "RS" })
					end
				end
			end
			for _, child in game.Workspace:GetChildren() do
				local c = 0
				for _ in child:GetDescendants() do c + = 1 end
				if c > 100 then
					table.insert(instMem.TopOffenders, { Name = child.Name, Class = child.ClassName, Count = c, Service = "WS" })
				end
			end
			table.sort(instMem.TopOffenders, function(a, b) return a.Count > b.Count end)
			if #instMem.TopOffenders > 15 then
				local trimmed = {}
				for i = 1, 15 do trimmed[i] = instMem.TopOffenders[i] end
				instMem.TopOffenders = trimmed
			end
			-- Count PlayerGui per player
			for _, player in game.Players:GetPlayers() do
				local pg = player:FindFirstChild("PlayerGui")
				if pg then
					local c = 0
					for _ in pg:GetDescendants() do c + = 1 end
					instMem.Services["PlayerGui:" .. player.Name] = c
					instMem.TotalDescendants + = c
				end
			end
			-- Detect duplicate assets (cloned multiple times)
			local assetsFolder = rs2 and rs2:FindFirstChild("Assets")
			if assetsFolder then
				local nameCounts: {[string]: number} = {}
				for _, child in assetsFolder:GetChildren() do
					nameCounts[child.Name] = (nameCounts[child.Name] or 0) + 1
				end
				local dupes = {}
				for name, count in pairs(nameCounts) do
					if count > 1 then
						table.insert(dupes, { Name = name, Count = count })
					end
				end
				if #dupes > 0 then
					table.sort(dupes, function(a, b) return a.Count > b.Count end)
					instMem.DuplicateAssets = dupes
				end
			end
			-- Aggregate managed Instance counts from active FSMs
			local fsmInstanceOwnership = {}
			if Factory and Factory.Registry then
				pcall(function()
					for fsmId, fsm in pairs(Factory.Registry.GetAllStateMachines()) do
						if type(fsm.GetManagedInstances) == "function" then
							local ok3, managed = pcall(fsm.GetManagedInstances, fsm)
							if ok3 and managed and #managed > 0 then
								fsmInstanceOwnership[fsmId] = #managed
							end
						end
					end
				end)
			end
			if next(fsmInstanceOwnership) then
				instMem.FSMOwnership = fsmInstanceOwnership
			end
			-- Orphan detection: Workspace children that aren't characters, terrain,
			-- camera, or known game objects — potential FSM leaks
			local orphans = {}
			local knownNames = { Camera = true, Terrain = true, Baseplate = true, SpawnLocation = true }
			for _, child in game.Workspace:GetChildren() do
				if child:IsA("Camera") or child:IsA("Terrain") then continue end
				if knownNames[child.Name] then continue end
				-- Characters are Models with a Humanoid
				if child:IsA("Model") and child:FindFirstChildOfClass("Humanoid") then continue end
				-- Folders are usually intentional
				if child:IsA("Folder") then continue end
				-- Check for suspicious objects (small parts, hitboxes, clones)
				local desc = 0
				for _ in child:GetDescendants() do desc + = 1 end
				local isSuspicious = child.Name:lower():find("hitbox")
					or child.Name:lower():find("clone")
					or child.Name:lower():find("projectile")
					or (child:IsA("BasePart") and not child.Anchored and desc == 0)
				if isSuspicious then
					table.insert(orphans, {
						Name = child.Name,
						Class = child.ClassName,
						Age = math.floor(os.clock() - (child:GetAttribute("_CreatedAt") or os.clock())),
					})
				end
			end
			if #orphans > 0 then
				instMem.SuspectedOrphans = orphans
			end
			snapshot.InstanceMemory = instMem
		end

		-- Aggregate server log history.We pull from the Orchestrator's central
		-- Logger and any per-subsystem Loggers we know about. Capped at 200
		-- most-recent entries so the snapshot stays small.
		do
			local logs: { any } = {}
			local seen = {}
			local function ingest(loggerLike: any)
				if type(loggerLike) ~= "table" then return end
				local entries = loggerLike.History
				if type(entries) ~= "table" then return end
				local source = loggerLike.Source or "Server"
				for _, e in ipairs(entries) do
					if type(e) == "table" and not seen[e] then
						seen[e] = true
						-- Tag with source. Original entry is shared with the
						-- live Logger so we shallow-copy before mutating.
						local copy = {
							Timestamp = e.Timestamp,
							Time = e.Timestamp or e.Time,
							Level = e.Level,
							Message = e.Message,
							OperationId = e.OperationId,
							Data = e.Data,
							Source = e.Source or source,
						}
						table.insert(logs, copy)
					end
				end
			end
			ingest(Orchestrator.Logger)
			-- Walk known subsystem objects that hold a .Logger (Scheduler, Factory,
			-- NetworkManager, Registry, etc.) so server logs from those stream too.
			local sources = { Orchestrator.Scheduler, Orchestrator.NetworkManager, Orchestrator.Factory }
			for _, s in ipairs(sources) do
				if type(s) == "table" and s.Logger then
					ingest(s.Logger)
				end
			end
			table.sort(logs, function(a, b)
				return (a.Time or 0) < (b.Time or 0)
			end)
			if #logs > 200 then
				local trimmed = {}
				for i = #logs - 199, #logs do
					table.insert(trimmed, logs[i])
				end
				logs = trimmed
			end
			snapshot.Logs = logs
		end

		return snapshot
	end, false)

	_Log("INFO","ServiceManager server handlers registered")
end

-- ══════════════════════════════════════════════════════════════
-- UTILITIES
-- ══════════════════════════════════════════════════════════════

function _CountKeys(tbl: { [any]: any }): number
	local count = 0
	for _ in pairs(tbl) do count + = 1 end
	return count
end

return ServiceManager
