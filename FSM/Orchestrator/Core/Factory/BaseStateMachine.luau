--!strict
--[=[
	@Name BaseStateMachine
	@Author iKrypto
	@Description Abstract Base State Machine class for managing states and transitions
	in the Orchestrator FSM system. Provides a centralized heartbeat loop, priority-based
	update scheduling, state registration/transition validation, sub-machine composition,
	performance telemetry, and signal-driven lifecycle events (Completed, Failed, Cancelled,
	StateChanged). Subclasses extend via `BaseStateMachine.Extend()` and override
	`RegisterStates()` / `OnCleanup()`.

	@usage
	local MyFSM = BaseStateMachine.Extend({
		className = "MyFSM",
		validStates = { "Idle", "Running", "Done" },
		TerminalStates = { "Done" },
		InitialState = "Idle",
	})

	function MyFSM:RegisterStates()
		self:AddState("Idle", function(fsm) ... end, { "Running" })
		self:AddState("Running", function(fsm) ... end, { "Done", "Idle" })
	end

	local instance = MyFSM.new({ Id = "abc" })
	instance:Start()
]=]

local RunService = game:GetService("RunService")

local BaseStateMachine = {}

local Logger, Signal, Settings, Initialized;


--[=[
	Bootstraps the BaseStateMachine module with the shared framework utilities.
	Stores Logger, Signal, and Settings in module-local upvalues used by every
	subsequent `new()` call. No-ops after the first successful call.

	@param Util table -- Shared Orchestrator utilities; must expose `Util.Logger.new`,
	       `Util.Signal`, and `Util.Settings`.
	@reads Initialized
	@writes Logger, Signal, Settings, Initialized
]=]
function BaseStateMachine.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Settings = Util.Settings
	Logger = Util.Logger.new({ Name = "BaseStateMachine" })
	Signal = Util.Signal

	Logger:Log({ Level = "INFO", Message = "BaseStateMachine initialized" })
end

local function xpcallHandler(err)
	return debug.traceback(tostring(err))
end

local function __index(t, k)
	-- Support inheritance by looking up the key in the class (metatable)
	local mt = getmetatable(t :: any) :: any
	if type(k) == "string" and k:lower() == "super" and type(t) == "table" and t ~= BaseStateMachine then
		local parentMeta = getmetatable(mt)
		if type(parentMeta) == "table" and parentMeta.__index then
			return parentMeta.__index
		end
		return parentMeta;
	end

	if mt then
		local classMember = mt[k]
		if classMember ~= nil then return classMember end
	end

	local context = rawget(t,"Context")
	if context and context[k] ~= nil then
		return context[k]
	end

	return nil
end
local function __tostring(t)
	return string.format("BaseStateMachine(%s) %s : [%s]", t.Id or "-id-", t.Name or "-name-", t._activeStateName or "-state-")
end

BaseStateMachine.__index = __index
BaseStateMachine.__tostring = __tostring

-- Standard Priority Levels
BaseStateMachine.Priorities = {
	Render = 1, -- Runs every frame
	High = 2, -- Runs every 2 frames
	Medium = 5, -- Runs every 5 frames
	Low = 10, -- Runs every 10 frames
	Background = 30, -- Runs every 30 frames (0.5s at 60fps)
}

-- Centralized update loop variables
local ActiveMachines = {} :: { [any]: boolean }
local GlobalHeartbeat: RBXScriptConnection? = nil
local GlobalFrameCount = 0

local function initPerf(self: any)
	if rawget(self,"Perf") ~= nil then
		return
	end
	rawset(self,"Perf", {
		UpdateCount = 0,
		TotalUpdateTime = 0,
		MaxUpdateTime = 0,
		LastUpdateTime = 0,
		AvgUpdateTime = 0,

		LastMemKB = nil,
		LastMemKBDelta = nil,
		MaxMemKBDelta = 0,
		TotalMemKBDelta = 0,
		_NextMemSampleAt = 0,
		_MemSampleInterval = 1.0,
	})
end


--[=[
	Low-level constructor that allocates and returns a raw BaseStateMachine
	instance table. Validates and stores the priority (clamped to ≥1),
	allocates the four lifecycle signals (Completed, Failed, Cancelled,
	StateChanged), constructs the `validStates` and `TerminalStates` lookup
	sets, initialises the `Perf` telemetry block, and sets up all runtime
	tracking fields (StateDuration, TransitionHistory, WaitSpan, etc.).
	Most code should use a subclass constructor from `BaseStateMachine.Extend`
	rather than calling this directly.

	@param params { Id, Name, ValidStates?, TerminalStates?, InitialState?,
	       Context?, Priority?, TransitionHistoryMax? } -- Construction parameters.
	       `Id` is the unique FSM identifier used in logs and Registry.
	       `ValidStates` populates the allowlist checked on every `AddState` and
	       `ChangeState` call. `TerminalStates` are auto-finished on entry.
	       `Priority` controls heartbeat update cadence (1 = every frame).
	@return any -- Raw FSM instance; call `:Start()` to begin execution.
	@reads Logger, Signal, Initialized
	@writes self.* (all instance fields)
]=]
function BaseStateMachine.new(params: { Id: string, Name: string, ValidStates: {string}?, TerminalStates: {string}?, InitialState: string?, Context: any?, Priority: number? })
	local self = setmetatable({}, BaseStateMachine)

	self.Id = params.Id
	self.Name = params.Name or "BaseStateMachine"
	self.Logger = (Logger and Logger.new({ Name = self.Name })) or error("BaseStateMachine: Logger not initialized. Did you call BaseStateMachine.Initialize(Util)?")

	-- Context must be a table. Reject non-table assignment defensively so
	-- user code like `fsm.Context = "oops"` doesn't silently break __index.
	local ctx = params.Context or {}
	if type(ctx) ~= "table" then
		self.Logger:Log({ Level = "WARN", Message = string.format("Context must be a table, got %s. Using empty table.", type(ctx)) })
		ctx = {}
	end
	self.Context = ctx

	-- Priority must be a positive integer. Clamp defensively so a bad value
	-- doesn't crash the heartbeat's modular-offset math or cause division by zero.
	local pri = params.Priority or BaseStateMachine.Priorities.Render
	if type(pri) ~= "number" or pri < 1 then
		pri = 1
	end
	self.Priority = math.floor(pri)
	self._offset = math.random(0, self.Priority - 1)
	self._accumulatedDt = 0
	self._states = {} :: { [string]: any }
	self._transitions = {} :: { [string]: {string} }
	self._cleanupTasks = {} :: { any }
	self._managedInstances = {} :: { { Instance: Instance, Label: string, CreatedAt: number } }
	self._legacyCleanup = {} :: {[(() -> ())?]: any}?
	self._connection = nil :: RBXScriptConnection?
	-- Ring buffer of transitions for the visualizer's history panel.
	-- Each entry: { From: string?, To: string, Time: number }
	self.TransitionHistory = {} :: { { From: string?, To: string, Time: number } }
	-- Clamp to a sane range so users can't accidentally set this to 10M.
	local histMax = 30
	if type(params) == "table" and type((params :: any).TransitionHistoryMax) == "number" then
		histMax = math.clamp(math.floor((params :: any).TransitionHistoryMax), 10, 500)
	end
	self._transitionHistoryMax = histMax
	self._started = false

	initPerf(self)

	self.CurrentState = nil :: any?
	self.State = nil :: string?
	self._activeStateName = nil :: string?
	self.StateDuration = 0
	self.TotalDuration = 0
	self.WaitSpan = 0
	self.TransitionCount = 0
	self._transitionId = 0
	-- Pending one-shot timed transition (set by :ScheduleTransition).
	-- Auto-cancelled on every ChangeState because :ChangeState resets it
	-- when the state actually flips. Polled by :_Update against StateDuration.
	self._pendingTimedTransition = nil :: { TargetState: string, FireAt: number, Args: {any}? }?

	self.validStates = {} :: { [string]: boolean }
	local validStatesList = params.ValidStates or (params :: any).validStates
	if validStatesList then
		for _, stateName in ipairs(validStatesList) do
			self.validStates[stateName] = true
		end
	end

	self.TerminalStates = {} :: { [string]: boolean }
	local terminalStatesList = params.TerminalStates or (params :: any).terminalStates
	if terminalStatesList then
		for _, stateName in ipairs(terminalStatesList) do
			if not self.validStates[stateName] then
				self.Logger:Log({
					Level = "WARN",
					Message = string.format("TerminalState '%s' is not in ValidStates.", stateName)
				})
				continue
			end
			self.TerminalStates[stateName] = true
		end
	end

	self.IsActive = false
	self.initialState = params.InitialState or (validStatesList and validStatesList[1]) or nil

	if self.initialState and next(self.validStates) and not self.validStates[self.initialState] then
		self.Logger:Log({
			Level = "WARN",
			Message = string.format("InitialState '%s' is not in ValidStates.", self.initialState)
		})
		self.initialState = nil
	end

	self._completed = (Signal and Signal.new()) or error("BaseStateMachine: Signal not initialized. Did you call BaseStateMachine.Initialize(Util)?")
	self._failed = (Signal and Signal.new()) or error("BaseStateMachine: Signal not initialized. Did you call BaseStateMachine.Initialize(Util)?")
	self._cancelled = (Signal and Signal.new()) or error("BaseStateMachine: Signal not initialized. Did you call BaseStateMachine.Initialize(Util)?")
	self._stateChanged = (Signal and Signal.new()) or error("BaseStateMachine: Signal not initialized. Did you call BaseStateMachine.Initialize(Util)?")

	self.Completed = self._completed
	self.Failed = self._failed
	self.Cancelled = self._cancelled
	self.StateChanged = self._stateChanged
	return self
end


--[=[
	Returns the Orchestrator instance accessible from this FSM. Checks
	`self.Context._Orchestrator` first (injected by the Orchestrator when it
	creates FSMs), then falls back to `shared.fsm.Orchestrator` for FSMs
	created outside the factory. Returns nil if neither route resolves.

	@return any? -- Orchestrator instance, or nil.
	@reads self.Context._Orchestrator, shared.fsm
	@writes None
]=]
function BaseStateMachine:GetOrchestrator()
	if self.Context and self.Context._Orchestrator then
		return self.Context._Orchestrator
	end

	local sharedFsm = (shared :: any).fsm
	if sharedFsm then
		return sharedFsm.Orchestrator or sharedFsm
	end

	return nil
end


--[=[
	Convenience shortcut that resolves an entity by id through the Orchestrator.
	Equivalent to `self:GetOrchestrator().GetEntity(entityId)`.
	Returns nil when the Orchestrator is unavailable or the entity is not
	registered.

	@param entityId string -- Unique entity identifier to look up.
	@return any? -- Entity instance, or nil.
	@reads self.Context._Orchestrator (via GetOrchestrator)
	@writes None
]=]
function BaseStateMachine:GetEntity(entityId: string)
	local orchestrator = self:GetOrchestrator()
	if orchestrator and orchestrator.GetEntity then
		return orchestrator.GetEntity(entityId)
	end

	return nil
end

local function isTerminalState(self: any, stateName: string): boolean
	local setTable = rawget(self,"TerminalStates")
	if type(setTable) == "table" and setTable[stateName] == true then
		return true
	end
	return false
end


--[=[
	Creates and returns a new FSM subclass. `extensionParams` is stored as
	`Subclass.Definition` and propagated to the base constructor. The returned
	Subclass inherits all BaseStateMachine methods via a static metatable and
	exposes a `.new(...)` constructor that creates an instance, sets its
	instance metatable (including the `super` shortcut), and calls
	`RegisterStates` immediately so all state handlers are registered before
	`Start` is called.

	@param extensionParams { className, validStates?, terminalStates?,
	       InitialState?, context?, Priority? } -- Class definition fields.
	       `className` is used as the FSM display name and log prefix.
	       `validStates` enforces the allowed state name set at both
	       `AddState` and `ChangeState` time.
	@return table -- Subclass with `.new`, `.Definition`, and inherited methods.
	@reads None
	@writes None (returns a new table per call)
]=]
function BaseStateMachine.Extend(extensionParams: {className: string, validStates: {string}?, terminalStates: {string}?, InitialState: string?, context: { [any]: any }?, Priority: number?})
	-- This is the Class Table (where methods like MyClass:Method() will live)
	local Subclass = {}
	Subclass.__index = Subclass
	Subclass.Definition = extensionParams

	-- Static inheritance: make Subclass inherit from BaseStateMachine
	setmetatable(Subclass, { __index = BaseStateMachine })
	--[=[
		@description Creates a concrete FSM instance for the subclass returned by `BaseStateMachine.Extend`. The first variadic argument is treated as the constructor context table, merged with the extension defaults to choose the instance id, valid-state metadata, initial state, priority, and exposed context. After the metatable is installed, `RegisterStates` is invoked immediately so subclass overrides register states against the fully initialized object.
		@param ... any -- Optional constructor arguments; the first value is expected to be a table containing `Id` or `StateMachineId` plus any per-instance context fields.
		@return any -- Initialized subclass instance with base signals, context, and registered states ready for `:Start()`.
		@reads extensionParams.className, extensionParams.validStates, extensionParams.terminalStates, extensionParams.InitialState, extensionParams.Priority
		@writes self.Id, self.Name, self.Context, self.Priority, self._states, self._transitions
	]=]

	function Subclass.new(...)
		local fsmArguments = {...}
		local ctorArgs = fsmArguments[1] or {} :: any
		-- Create the instance data using the base constructor
		-- We use dot syntax here to ensure we get the raw table structure from Base
		local self = BaseStateMachine.new({
			Id = ctorArgs.Id or ctorArgs.StateMachineId,
			Name = extensionParams.className,
			ValidStates = extensionParams.validStates or extensionParams.ValidStates,
			TerminalStates = extensionParams.terminalStates or extensionParams.TerminalStates,
			InitialState = extensionParams.InitialState or extensionParams.initialState or (extensionParams.validStates and extensionParams.validStates[1]) or nil,
			Context = ctorArgs,
			Priority = extensionParams.Priority or BaseStateMachine.Priorities.Render
		})

		-- Define the metatable for this specific instance
		local instanceMetatable = {
			-- Custom __index to handle Context shortcuts and Inheritance
			__index = __index,
			-- Custom tostring
			__tostring = __tostring,
			__metatable = Subclass
		}

		-- A. SETUP METATABLE FIRST
		setmetatable(self :: any, instanceMetatable)

		-- B. NOW REGISTER STATES (Object now recognizes overrides)
		if self.RegisterStates then
			self.RegisterStates(self)
		else
			self.Logger:Log({
				Level = "WARN",
				Message = string.format("Subclass '%s' did not implement 'RegisterStates'.", extensionParams.className),
				OperationId = self.Id
			})
		end

		return self
	end

	return Subclass
end


--[=[
	Registers a state handler under `name`. `state` can be a plain function
	`(fsm, ...args)` or a table with optional `OnEnter`, `OnLeave`,
	`OnHeartbeat`, `Transitions`, `Timeout`, and `OnTimeout` hooks.
	`validOutcomes` is an allowlist of state names that may be transitioned
	to from this state; an empty/absent list allows all transitions.
	Warns if called after `:Start()` since late-registered states may miss
	in-flight transitions.

	@param name string -- State name; must be in `validStates` if that set is non-empty.
	@param state any -- Function or table defining the state's behavior.
	@param validOutcomes {string}? -- Allowed destination states from this state.
	@reads self.validStates, self._started
	@writes self._states[name], self._transitions[name]
]=]
function BaseStateMachine:AddState(name: string, state: any, validOutcomes: {string}?)
	if self._started then
		self.Logger:Log({
			Level = "WARN",
			Message = string.format(
				"AddState('%s') called after :Start(). Late-registered states may miss transitions in flight. "
				.."Register all states before calling :Start().",
				name),
			OperationId = self.Id,
		})
	end
	if next(self.validStates) and not self.validStates[name] then
		self.Logger:Log
		{
			Level = "ERROR",
			Message = string.format("State '%s' is not in the validStates list.", name),
			OperationId = self.Id
		}
		return
	end
	self._states[name] = state
	self._transitions[name] = validOutcomes or {}
end


--[=[
	Registers a composite state that owns a nested sub-FSM for the duration
	the parent FSM is in that state. On `OnEnter` a new `subMachineClass`
	instance is created (sharing the parent's Context), signal connections
	route sub-machine Completed/Failed/Cancelled to the configured
	`transitions.OnCompleted / OnFailed / OnCancelled` target states (or
	propagate upward as Finish/Fail/Cancel when no target is specified).
	On `OnLeave` all connections are disconnected and the sub-machine is
	cancelled if still active.

	@param name string -- State name for the composite state in the parent FSM.
	@param subMachineClass any -- FSM subclass created by `BaseStateMachine.Extend`.
	@param config { Transitions: { OnCompleted?, OnFailed?, OnCancelled? },
	       InitialState: string, StoreReference: string? } -- Wiring config.
	       `StoreReference` names a Context key where the live sub-machine
	       instance is stored while active.
	@reads self.validStates, config.Transitions, config.InitialState
	@writes self._states[name], self._transitions[name],
	        self.Context[config.StoreReference] (while sub-machine is active)
]=]
function BaseStateMachine:AddSubMachine(name: string, subMachineClass: any, config: any)
	local subMachineState = {}:: any;
	local transitions = config.Transitions;
	local initialSubState = config.InitialState;
	local storeReference = config.StoreReference; -- Uses config.StoreReference as defined in type

	local FailureMessage = (if not transitions then
		"AddSubMachine called without transitions configuration."
		elseif not initialSubState then
		"AddSubMachine called without initial sub-state configuration."
		else
		"");

	if FailureMessage ~= "" then
		self.Logger:Log
		{
			Level = "ERROR",
			Message = FailureMessage,
			OperationId = self.Id
		}
		return
	end


	--[=[
		State lifecycle hook called by the parent FSM when it enters the composite
		state. Instantiates the sub-machine, connects result signals, optionally
		stores the instance in the parent Context, and calls `sub:Start()`.

		@param fsm any -- The parent BaseStateMachine instance.
		@reads subMachineClass, transitions, initialSubState, storeReference
		@writes self.Machine, self._connections, fsm.Context[storeReference]
	]=]
	function subMachineState:OnEnter(fsm)
		self._connections = {}
		self.Machine = subMachineClass.new({
			StateMachineId = fsm.Id::string .."." .. name,
			Context = fsm.Context -- Shared context allows data passing
		})

		-- Store reference in context if requested
		if storeReference then
			fsm.Context[storeReference] = self.Machine
		end

		-- Handle Completion
		table.insert(self._connections, self.Machine.Completed:Connect(function()
			if transitions.OnCompleted then
				fsm:ChangeState({ Name = transitions.OnCompleted })
			else
				fsm:Finish() -- Default: Propagate completion up
			end
		end))

		-- Handle Failure
		table.insert(self._connections, self.Machine.Failed:Connect(function(reason)
			if transitions.OnFailed then
				fsm:ChangeState({ Name = transitions.OnFailed, Args = { reason } })
			else
				fsm:Fail(reason) -- Default: Propagate failure up
			end
		end))

		-- Handle Cancellation
		table.insert(self._connections, self.Machine.Cancelled:Connect(function()
			if transitions.OnCancelled then
				fsm:ChangeState({ Name = transitions.OnCancelled })
			else
				fsm:Cancel() -- Default: Propagate cancellation up
			end
		end))

		self.Machine:Start({ State = initialSubState})
	end


	--[=[
		State lifecycle hook called by the parent FSM when it leaves the composite
		state. Disconnects all signal connections accumulated in `_connections` and
		cancels the sub-machine if it is still running.

		@param fsm any -- The parent BaseStateMachine instance (unused, but required by the OnLeave contract).
		@reads self._connections, self.Machine.IsActive
		@writes self._connections = nil, self.Machine = nil
	]=]
	function subMachineState:OnLeave(fsm)
		if self._connections then
			for _, conn in ipairs(self._connections) do
				conn:Disconnect()
			end
			self._connections = nil
		end
		if self.Machine and self.Machine.IsActive then
			self.Machine:Cancel()
		end
		self.Machine = nil
	end

	local validOutcomes = {}
	if transitions.OnCompleted then table.insert(validOutcomes, transitions.OnCompleted) end
	if transitions.OnFailed then table.insert(validOutcomes, transitions.OnFailed) end
	if transitions.OnCancelled then table.insert(validOutcomes, transitions.OnCancelled) end

	self:AddState(name, subMachineState, validOutcomes)
end


--[=[
	Registers `object` for automatic cleanup when `Destroy` is called. Supports
	Roblox `Instance` (`:Destroy()`), `RBXScriptConnection` (`:Disconnect()`),
	functions (called directly), and tables with a `.Destroy` method.

	@param object any -- Resource to track.
	@return any -- Returns `object` unchanged for chaining.
	@reads None
	@writes self._cleanupTasks (appends)
]=]
function BaseStateMachine:Manage(object: any)
	table.insert(self._cleanupTasks, object)
	return object
end


--[=[
	Records a managed Instance in `_managedInstances` for diagnostics and
	optionally adds it to the cleanup list so it is destroyed on `Destroy`.
	When `trackOnly` is true the Instance is only tracked (visible in
	`GetManagedInstances`) but not destroyed during cleanup.

	@param inst Instance -- The Roblox Instance to track.
	@param label string? -- Human-readable label for the visualizer; defaults to `inst.Name`.
	@param trackOnly boolean? -- When true, skip adding to the cleanup list. Default false.
	@return Instance -- Returns `inst` for chaining.
	@reads None
	@writes self._managedInstances (appends), self._cleanupTasks (appends unless trackOnly)
]=]
function BaseStateMachine:TrackInstance(inst: Instance, label: string?, trackOnly: boolean?): Instance
	table.insert(self._managedInstances, {
		Instance = inst,
		Label = label or inst.Name,
		CreatedAt = os.clock(),
		TrackOnly = trackOnly or false,
	})
	if not trackOnly then
		table.insert(self._cleanupTasks, inst)
	end
	return inst
end


--[=[
	Returns the list of tracked instances, pruning any that have been destroyed
	(i.e. whose `.Parent` is nil) before returning. The internal
	`_managedInstances` list is compacted in place.

	@return { any } -- Array of live `{ Instance, Label, CreatedAt, TrackOnly }` entries.
	@reads self._managedInstances
	@writes self._managedInstances (removes stale entries)
]=]
function BaseStateMachine:GetManagedInstances(): { any }
	-- Prune destroyed Instances before returning
	local alive = {}
	for _, entry in ipairs(self._managedInstances) do
		if entry.Instance and entry.Instance.Parent ~= nil then
			table.insert(alive, entry)
		end
	end
	self._managedInstances = alive
	return alive
end


--[=[
	Disconnects the global RunService.Heartbeat connection and sets
	`_ExternalLoop = true`, preventing any future `Start` call from
	re-registering the heartbeat. Use this when the hosting system
	manages its own update loop and drives `BaseStateMachine.Step` manually.

	@reads GlobalHeartbeat
	@writes GlobalHeartbeat = nil, BaseStateMachine._ExternalLoop = true
]=]
function BaseStateMachine.DisableInternalLoop()
	if GlobalHeartbeat then
		GlobalHeartbeat:Disconnect()
		GlobalHeartbeat = nil
	end
	BaseStateMachine._ExternalLoop = true
end


--[=[
	The shared per-frame update driver, connected to RunService.Heartbeat by
	`Start`. Increments `GlobalFrameCount`, then iterates `ActiveMachines` and
	calls `_Update(dt)` on each machine whose priority and random offset align
	with the current frame. Render-priority (Priority=1) machines are updated
	inline; all others are wrapped in `task.spawn` for isolation. Delta time
	is accumulated across skipped frames so lower-priority machines receive
	the correct total elapsed time.

	@param dt number -- Delta time in seconds from RunService.Heartbeat.
	@reads GlobalFrameCount, ActiveMachines, machine.IsActive, machine.Priority
	@writes GlobalFrameCount, machine._accumulatedDt
]=]
function BaseStateMachine.Step(dt: number)
	GlobalFrameCount += 1
	for machine in pairs(ActiveMachines) do
		if machine.IsActive then
			-- Accumulate delta time for skipped frames
			machine._accumulatedDt += dt

			if (GlobalFrameCount + machine._offset) % machine.Priority == 0 then
				local stepDt = machine._accumulatedDt
				machine._accumulatedDt = 0
				-- OPTIMIZATION: Run Render priority inline to avoid task.spawn overhead
				-- This requires Render priority state machines to NOT yield.
				if machine.Priority == 1 then
					local success, err = xpcall(machine._Update, xpcallHandler, machine, stepDt)
					if not success then
						machine.Logger:Log({
							Level = "ERROR",
							Message = string.format("Runtime Error in %s: %s", machine.Name, tostring(err)),
							OperationId = machine.Id
						})
					end
				else
					-- Isolate errors to prevent one machine from crashing the loop
					task.spawn(function()
						local success, err = xpcall(machine._Update, xpcallHandler, machine, stepDt)
						if not success then
							machine.Logger:Log({
								Level = "ERROR",
								Message = string.format("Runtime Error in %s: %s", machine.Name, tostring(err)),
								OperationId = machine.Id
							})
						end
					end)
				end
			end
		end
	end
end


--[=[
	Activates the FSM by registering it in `ActiveMachines` and transitioning
	to the initial state. If the global heartbeat is not yet running and
	`_ExternalLoop` is false, the heartbeat connection is created here.
	Fails with an ERROR log if no start state can be determined, or if the
	initial `ChangeState` call does not successfully enter a state (which
	would leave `_activeStateName` nil and leak the machine in ActiveMachines).
	Idempotent: already-active machines return immediately.

	@param params { State: string?, Args: {any}? }? -- Optional override for the
	       initial state and its entry arguments. Defaults to `self.initialState`.
	@reads self.IsActive, self.initialState, BaseStateMachine._ExternalLoop
	@writes self.IsActive, self._started, ActiveMachines, GlobalHeartbeat
]=]
function BaseStateMachine:Start(params: { State: string?, Args: {any}? }?)
	if self.IsActive then return end
	self.IsActive = true
	self._started = true
	local startParams = params or {}

	local startState = startParams.State or self.initialState or self.InitialState
	if not startState then
		-- validation already warned if InitialState was bad, but if it's nil entirely:
		self.Logger:Log({ Level = "ERROR", Message = "No Start State provided and no InitialState defined." })
		self.IsActive = false
		return
	end

	-- self.InitialState is just a property, we don't necessarily overwrite it here unless we want to track "what it started with this time"
	-- effectively current runtime initial state
	-- self.InitialState = startState
	-- Register to centralized loop
	ActiveMachines[self] = true
	if not GlobalHeartbeat and not BaseStateMachine._ExternalLoop then
		GlobalHeartbeat = RunService.Heartbeat:Connect(BaseStateMachine.Step)
	end

	self.Logger:Log
	{
		Level = "DEBUG",
		Message = "StateMachine Started. Initial State: " .. tostring(startState),
		OperationId = self.Id
	}

	self:ChangeState
	{
		Name = startState,
		Args = startParams.Args
	}

	if self.IsActive and self._activeStateName == nil then
		self.IsActive = false
		ActiveMachines[self] = nil
		if next(ActiveMachines) == nil and GlobalHeartbeat then
			GlobalHeartbeat:Disconnect()
			GlobalHeartbeat = nil
		end
		self.Logger:Log({
			Level = "ERROR",
			Message = string.format("Failed to enter initial state '%s'. StateMachine stopped to avoid leaking an active machine.", tostring(startState)),
			OperationId = self.Id,
		})
	end
end


--[=[
	Internal per-frame update called by `BaseStateMachine.Step`. Handles three
	sequential concerns each tick:
	  1. Deferred external state write: if `self.State` was set externally
	     (not equal to `_activeStateName`) triggers `ChangeState`.
	  2. WaitSpan re-entry: a positive `WaitSpan` schedules a `ScheduleTransition`
	     self-loop so the current state is re-entered after the delay.
	  3. Active state evaluation: fires the `_pendingTimedTransition` if its
	     deadline has passed, checks `currentState.Transitions` conditions, handles
	     `Timeout`/`OnTimeout`, and calls `OnHeartbeat` for object-based states.
	Records performance telemetry in `Perf` after each tick.

	@param dt number -- Frame delta time, accumulated across priority-skipped frames.
	@reads self.IsActive, self.State, self._activeStateName, self.WaitSpan,
	       self._pendingTimedTransition, self.CurrentState, self.Perf
	@writes self.StateDuration, self.TotalDuration, self.Perf, self._pendingTimedTransition
]=]
function BaseStateMachine:_Update(dt: number)
	if not self.IsActive then return end

	-- Deferred state transition: detect if State was set externally (e.g. fsm.State = "X")
	local pendingState = rawget(self,"State")
	local activeState = rawget(self,"_activeStateName")
	if pendingState ~= nil and pendingState ~= activeState then
		-- Different state requested: clear pending then trigger transition
		self.State = activeState
		self:ChangeState({ Name = pendingState })
		if not self.IsActive then return end
	else
		-- Same state with WaitSpan: schedule delayed self-transition (re-entry).
		-- We use the same StateDuration-poll mechanism as :ScheduleTransition
		-- instead of the legacy threaded-delay approach. Benefits:
		--   - No orphaned scheduler closures if the FSM is destroyed
		--   - Cancellation is automatic when state changes (handled in
		--     ChangeState's `name != _activeStateName` branch)
		--   - Polling against StateDuration is FPS-aware, not wallclock —
		--     so a paused/throttled FSM doesn't fire the re-entry early.
		-- Read WaitSpan defensively — user code can write `fsm.WaitSpan = nil`,
		-- which would crash `nil > 0`. The field is xpcall'd by the heartbeat
		-- so the error would be silently swallowed but the FSM would skip
		-- the rest of its frame.
		local ws = rawget(self,"WaitSpan") or 0
		if type(ws) == "number" and ws > 0 then
			local reentryDelay = ws
			self.WaitSpan = 0
			-- Self-re-entry is just a scheduled transition to the current
			-- state. Same-state ChangeState does NOT clear the pending slot
			-- (only different-state changes do), so the cycle continues
			-- naturally: action sets WaitSpan → framework schedules
			-- re-entry → ChangeState fires action again → action sets
			-- WaitSpan → ...
			self._pendingTimedTransition = {
				TargetState = activeState,
				FireAt = self.StateDuration + reentryDelay,
				Args = nil,
			}
		end
	end

	initPerf(self)
	local perf = (self :: any).Perf
	local t0 = os.clock()
	local mem0: number? = nil
	local now = t0
	if perf and now >= (perf._NextMemSampleAt or 0) then
		perf._NextMemSampleAt = now + (perf._MemSampleInterval or 1.0)
		mem0 = gcinfo()
	end

	self.TotalDuration += dt
	self.StateDuration += dt

	-- Pending one-shot timed transition (set by :ScheduleTransition).
	-- Fire when StateDuration crosses FireAt. Auto-cleared on ChangeState
	-- (so leaving the state cancels the timer for free — no boilerplate
	-- guards in user state actions, no leaked task.delay closures).
	local pending = self._pendingTimedTransition
	if pending and self.StateDuration >= pending.FireAt then
		local target = pending.TargetState
		local args = pending.Args
		self._pendingTimedTransition = nil
		self:ChangeState({ Name = target, Args = args })
		-- Record perf for the early exit (mirrors the table-Transitions branch below).
		local t1 = os.clock()
		local elapsed = t1 - t0
		if perf then
			perf.UpdateCount = (perf.UpdateCount or 0) + 1
			perf.LastUpdateTime = elapsed
			perf.TotalUpdateTime = (perf.TotalUpdateTime or 0) + elapsed
			perf.AvgUpdateTime = perf.TotalUpdateTime / perf.UpdateCount
			perf.MaxUpdateTime = math.max(perf.MaxUpdateTime or 0, elapsed)
		end
		return
	end

	-- Call OnHeartbeat for object-based states
	local currentState = self.CurrentState
	if typeof(currentState) == "table" then
		if currentState.Transitions then
			for _, transition in ipairs(currentState.Transitions) do
				if transition.Condition(self, dt) then
					self:ChangeState({ Name = transition.TargetState, Args = transition.Args })
					-- Still record perf on early exit
					local t1 = os.clock()
					local elapsed = t1 - t0
					if perf then
						perf.UpdateCount = (perf.UpdateCount or 0) + 1
						perf.LastUpdateTime = elapsed
						perf.TotalUpdateTime = (perf.TotalUpdateTime or 0) + elapsed
						perf.AvgUpdateTime = perf.TotalUpdateTime / perf.UpdateCount
						perf.MaxUpdateTime = math.max(perf.MaxUpdateTime or 0, elapsed)
						if mem0 ~= nil then
							local mem1 = gcinfo()
							perf.LastMemKB = mem1
							local delta = mem1 - mem0
							perf.LastMemKBDelta = delta
							perf.TotalMemKBDelta = (perf.TotalMemKBDelta or 0) + delta
							perf.MaxMemKBDelta = math.max(perf.MaxMemKBDelta or 0, math.abs(delta))
						end
					end
					return
				end
			end
		end

		-- Declarative state-level timeout: object states can declare
		-- `Timeout = N` (seconds) and `OnTimeout = "TargetState" | function`.
		-- Fires once when StateDuration crosses Timeout. Auto-resets on
		-- state change because StateDuration is reset by ChangeState.
		--   - String OnTimeout: calls self:ChangeState({ Name = onTimeout })
		--   - Function OnTimeout: invoked as (currentState, self) — user
		--     is responsible for transitioning (or not).
		-- The _timeoutFired flag prevents re-firing every tick if the user's
		-- function OnTimeout chooses not to transition. The flag clears on
		-- ChangeState (because currentState becomes a different table OR
		-- StateDuration resets).
		if currentState.Timeout
			and type(currentState.Timeout) == "number"
			and currentState.Timeout > 0
			and not currentState._timeoutFired
			and self.StateDuration >= currentState.Timeout
		then
			currentState._timeoutFired = true
			local handler = currentState.OnTimeout
			if type(handler) == "string" then
				self:ChangeState({ Name = handler })
				-- Perf bookkeeping for early exit
				local t1 = os.clock()
				local elapsed = t1 - t0
				if perf then
					perf.UpdateCount = (perf.UpdateCount or 0) + 1
					perf.LastUpdateTime = elapsed
					perf.TotalUpdateTime = (perf.TotalUpdateTime or 0) + elapsed
					perf.AvgUpdateTime = perf.TotalUpdateTime / perf.UpdateCount
					perf.MaxUpdateTime = math.max(perf.MaxUpdateTime or 0, elapsed)
				end
				return
			elseif type(handler) == "function" then
				-- Wrap in xpcall so a throwing OnTimeout doesn't kill the
				-- heartbeat (mirrors the rest of the framework's resilience).
				local timeoutTransitionId = self._transitionId
				local ok, err = xpcall(handler, xpcallHandler, currentState, self)
				if not ok then
					self.Logger:Log({
						Level = "ERROR",
						Message = string.format("OnTimeout error in state '%s': %s",
							tostring(self._activeStateName), tostring(err)),
						OperationId = self.Id,
					})
				end
				-- After a function handler we don't auto-return unless the
				-- handler transitioned. Continuing with the stale currentState
				-- would run the old OnHeartbeat after a timeout-triggered state flip.
				if not self.IsActive then return end
				if self._transitionId ~= timeoutTransitionId then return end
			end
		end

		if currentState.OnHeartbeat then
			currentState.OnHeartbeat(currentState, self, dt)
		end
	end

	local t1 = os.clock()
	local elapsed = t1 - t0
	if perf then
		perf.UpdateCount = (perf.UpdateCount or 0) + 1
		perf.LastUpdateTime = elapsed
		perf.TotalUpdateTime = (perf.TotalUpdateTime or 0) + elapsed
		perf.AvgUpdateTime = perf.TotalUpdateTime / perf.UpdateCount
		perf.MaxUpdateTime = math.max(perf.MaxUpdateTime or 0, elapsed)
		if mem0 ~= nil then
			local mem1 = gcinfo()
			perf.LastMemKB = mem1
			local delta = mem1 - mem0
			perf.LastMemKBDelta = delta
			perf.TotalMemKBDelta = (perf.TotalMemKBDelta or 0) + delta
			perf.MaxMemKBDelta = math.max(perf.MaxMemKBDelta or 0, math.abs(delta))
		end
	end
end


--[=[
	Schedules a one-shot delayed transition to `targetState` that fires after
	`seconds` of `StateDuration` (not wallclock time). The timer is stored
	in `_pendingTimedTransition` and polled by `_Update`; it is automatically
	cancelled when `ChangeState` switches to a different state. Idempotent: a
	duplicate schedule with an identical target and nearly identical fire-at
	time is silently skipped to prevent wasteful re-scheduling from `OnHeartbeat`.

	@param seconds number -- Delay in seconds of state-local time (StateDuration units).
	@param targetState string -- Name of the state to transition to when the timer fires.
	@param args {any}? -- Arguments forwarded to the state's `OnEnter` / function.
	@reads self.IsActive, self.StateDuration, self._pendingTimedTransition
	@writes self._pendingTimedTransition
]=]
function BaseStateMachine:ScheduleTransition(seconds: number, targetState: string, args: {any}?)
	if not self.IsActive then return end
	if type(seconds) ~= "number" or seconds < 0 then
		self.Logger:Log({
			Level = "WARN",
			Message = string.format("ScheduleTransition: invalid seconds=%s", tostring(seconds)),
			OperationId = self.Id,
		})
		return
	end
	if type(targetState) ~= "string" or targetState == "" then
		self.Logger:Log({
			Level = "WARN",
			Message = "ScheduleTransition: invalid targetState",
			OperationId = self.Id,
		})
		return
	end
	-- FireAt is in StateDuration units (seconds since current state began),
	-- so the polling check `StateDuration >= FireAt` is independent of
	-- wallclock and survives FPS drops gracefully.
	local fireAt = self.StateDuration + seconds
	-- Skip if an identical timer is already pending (prevents wasteful
	-- re-scheduling when called from OnHeartbeat every tick).
	local pending = self._pendingTimedTransition
	if pending and pending.TargetState == targetState and math.abs(pending.FireAt - fireAt) < 0.001 then
		return
	end
	self._pendingTimedTransition = {
		TargetState = targetState,
		FireAt = fireAt,
		Args = args,
	}
end


--[=[
	Cancels any pending timed transition set by `ScheduleTransition`. Returns
	`true` if a pending transition was cancelled, `false` if there was nothing
	to cancel.

	@return boolean -- Whether a pending transition existed and was cancelled.
	@reads self._pendingTimedTransition
	@writes self._pendingTimedTransition = nil
]=]
function BaseStateMachine:CancelScheduledTransition(): boolean
	if self._pendingTimedTransition then
		self._pendingTimedTransition = nil
		return true
	end
	return false
end

local function releaseTransitionGuard(self: any)
	self._inTransition = false
	local queue = self._pendingTransitions
	if queue and #queue > 0 and self.IsActive and not self._destroyed then
		local nextTransition = table.remove(queue, 1)
		if nextTransition then
			task.defer(function()
				if self.IsActive and not self._destroyed then
					self:ChangeState(nextTransition)
				end
			end)
		end
	end
end


--[=[
	Transitions the FSM to a new state. Enforces the `validStates` allowlist
	and the per-state `_transitions` legality table, executes `OnLeave` for
	the departing state (wrapped in xpcall), resets `StateDuration`,
	appends a `TransitionHistory` entry with a sanitized Context snapshot,
	fires `StateChanged`, invokes the new state's `OnEnter` (deferred for
	non-terminal states), and auto-finishes terminal states via
	`Finish`/`Fail`/`Cancel`. A re-entrance guard queues concurrent
	`ChangeState` calls and drains them in order after the current transition
	completes.

	@param params { Name: string, Args: {any}?, WaitSpan: number? } --
	       `Name` is the target state name. `Args` are forwarded to the state
	       entry handler. `WaitSpan` defers the transition by that many seconds
	       (via `task.delay`).
	@reads self.IsActive, self.validStates, self._transitions, self._states,
	       self.TerminalStates, self._inTransition
	@writes self.CurrentState, self._activeStateName, self.State, self.StateDuration,
	        self.WaitSpan, self.TransitionCount, self.TransitionHistory,
	        self._pendingTimedTransition = nil, self._legacyCleanup
	@fires StateChanged
]=]
function BaseStateMachine:ChangeState(params: { Name: string, Args: {any}?, WaitSpan: number? })
	if not self.IsActive then return end

	local name = params.Name
	local args = params.Args or {}

	-- ─── REENTRANCE GUARD ────────────────────────────────────────────────
	-- If ChangeState is called while another ChangeState is in flight (e.g. a
	-- StateUpdated listener triggers a transition during OnEnter / Update),
	-- queue the request and return. The in-flight call drains the queue at
	-- end-of-execution. This prevents racing OnEnter bodies from stomping
	-- each other and avoids _transitionId / WaitSpan corruption.
	if self._inTransition then
		self._pendingTransitions = self._pendingTransitions or {}
		table.insert(self._pendingTransitions, params)
		return
	end
	self._inTransition = true

	-- Compute delay BEFORE mutating WaitSpan so a rejected transition leaves
	-- the WaitSpan field untouched for the caller's next legitimate call.
	local delay = (((self.WaitSpan and self.WaitSpan ~= 0) and self.WaitSpan) or params.WaitSpan) or 0

	if delay > 0 then
		-- Defer this transition. WaitSpan is consumed (only after we've decided
		-- to actually defer). The deferred task will recurse into ChangeState.
		self.WaitSpan = 0
		self._transitionId += 1
		local transitionId = self._transitionId
		releaseTransitionGuard(self)
		task.delay(delay, function()
			if self.IsActive and self._transitionId == transitionId then
				self:ChangeState({ Name = name, Args = args })
			end
		end)
		return
	end

	-- ─── VALIDATION (no side effects yet) ───────────────────────────────
	if next(self.validStates) and not self.validStates[name] then
		self.Logger:Log
		{
			Level = "ERROR",
			Message = string.format("Cannot transition to state '%s': Not in validStates.", tostring(name)),
			OperationId = self.Id
		}
		releaseTransitionGuard(self)
		return
	end

	local oldState = self._activeStateName
	local newState = self._states[name]

	-- Validate Transition (legality + registration). Side effects only happen
	-- if validation passes.
	if oldState and newState then
		local allowed = self._transitions[oldState]
		if allowed and #allowed > 0 then
			local isLegal = false
			for _, outcome in ipairs(allowed) do
				if outcome == name then isLegal = true; break end
			end
			if not isLegal then
				self.Logger:Log
				{
					Level = "ERROR",
					Message = string.format("Illegal transition from '%s' to '%s'", oldState, name),
					OperationId = self.Id
				}
				releaseTransitionGuard(self)
				return
			end
		end
	end

	-- Allow implicit terminal states (defined below) even if not registered
	if not newState and not self.TerminalStates[name] then
		self.Logger:Log
		{
			Level = "ERROR",
			Message = string.format("State '%s' is not registered in the FSM.", tostring(name)),
			OperationId = self.Id
		}
		releaseTransitionGuard(self)
		return
	end

	-- ─── COMMIT (validation passed; side effects begin) ─────────────────
	self.WaitSpan = 0
	self._transitionId += 1

	if oldState and newState then
		local duration = math.floor(self.StateDuration * 1000) / 1000
		self.Logger:Log
		{
			Level = "DEBUG",
			Message = string.format("Leaving '%s' (Duration: %.3fs)", tostring(oldState), duration),
			OperationId = self.Id
		}
	end

	-- Execute OnLeave for the previous state. Wrap in xpcall so a throwing
	-- OnLeave doesn't wedge the FSM half-transitioned.
	if typeof(self.CurrentState) == "table" and self.CurrentState.OnLeave and (oldState ~= name) then
		local ok, err = xpcall(function()
			self.CurrentState.OnLeave(self.CurrentState, self)
		end, function(e) return debug.traceback(tostring(e)) end)
		if not ok then
			self.Logger:Log({
				Level = "ERROR",
				Message = string.format("OnLeave for '%s' threw: %s", tostring(oldState), tostring(err)),
				OperationId = self.Id,
			})
		end
	end

	-- Execute legacy cleanup function if one was registered for the old state
	if self._legacyCleanup and oldState and self._legacyCleanup[oldState] then
		local cleanupSuccess, cleanupResult = pcall(self._legacyCleanup[oldState])
		if not cleanupSuccess then
			self.Logger:Log
			{
				Level = "ERROR",
				Message = string.format("Error in cleanup function for state '%s': %s", oldState, tostring(cleanupResult)),
				OperationId = self.Id
			}
		end
		self._legacyCleanup[oldState] = nil
	end

	if not self.IsActive then
		releaseTransitionGuard(self)
		return
	end

	-- Update Transition Count
	if name == self._activeStateName then
		self.TransitionCount += 1
	else
		self.Logger:Log
		{
			Level = "DEBUG",
			Message = string.format("Transition: '%s' -> '%s'", tostring(self._activeStateName), name),
			OperationId = self.Id
		}

		self.StateDuration = 0
		self.TransitionCount = 1
		-- Leaving the previous state cancels any pending one-shot timer
		-- scheduled via :ScheduleTransition. This is the whole reason we
		-- track timers via StateDuration polling instead of task.delay —
		-- cancellation is automatic and free.
		self._pendingTimedTransition = nil
	end

	-- Append to TransitionHistory ring buffer for the visualizer.
	-- Entry shape: { From, To, Time, Args, WaitSpan, ContextSnapshot, TransitionId }
	-- ContextSnapshot is a deep-but-bounded copy of self.Context (sanitized)
	-- so that stepping through history can show the user "what did Context
	-- look like when this transition fired?". We preserve nested table
	-- structure (down to MAX_DEPTH) so the dashboard can render those as
	-- click-to-drill rows. Entity/FSM-like objects are condensed to a label
	-- (Id + ClassName + state) to avoid dumping framework internals.
	if self.TransitionHistory then
		local MAX_DEPTH = 8
		local MAX_KEYS = 32

		-- Detect framework objects via duck-typing so we can render a useful
		-- label instead of a sea of internal fields. Uses [...] not <...>
		-- because the dashboard's RichText parser would interpret angle
		-- brackets as font tags.
		local function describeClassy(t: any): string?
			if type(t) ~= "table" then return nil end
			-- BaseEntity instances are tables with methods set directly on the
			-- proxy (GetRawData, GetSchema, UpdateEntity). The inner private
			-- props are in a closure, so we duck-type via the method.
			if rawget(t,"GetRawData") and rawget(t,"GetSchema") then
				-- Try to read a friendly name through the proxy's __index
				-- (which surfaces Data.Name → Context.Name → class.Name).
				local ok, name = pcall(function() return (t :: any).Name end)
				return string.format("Entity[%s]", ok and tostring(name) or "?")
			end
			-- BaseStateMachine instances have Id + State + _states.
			if rawget(t,"Id") and rawget(t,"_states") then
				local stateName = rawget(t,"State") or rawget(t,"_activeStateName") or "?"
				return string.format("FSM[%s @ %s]", tostring(rawget(t,"Id")), tostring(stateName))
			end
			return nil
		end

		local function sanitize(value: any, depth: number): any
			local tv = typeof(value)
			if tv == "string" or tv == "number" or tv == "boolean" then
				return value
			elseif tv == "Vector3" or tv == "CFrame" or tv == "Color3" or tv == "UDim" or tv == "UDim2" or tv == "Vector2" then
				return tostring(value)
			elseif tv == "Instance" then
				return string.format("[Instance:%s]", tostring((value :: any).ClassName))
			elseif tv == "table" then
				-- Fast-path: framework class instances (Entity / FSM) → label.
				local label = describeClassy(value)
				if label then return label end
				-- Depth cap: deeply nested tables get a summary stub.
				if depth <= 0 then
					local n = 0
					for _ in pairs(value) do n += 1 end
					return string.format("{table %d keys}", n)
				end
				-- Recursive sanitize with breadth cap.
				local out = {}
				local kept = 0
				local total = 0
				for k, v in pairs(value) do
					total += 1
					if kept >= MAX_KEYS then continue end
					out[tostring(k)] = sanitize(v, depth - 1)
					kept += 1
				end
				if total > kept then
					out["…"] = string.format("(%d more)", total - kept)
				end
				return out
			elseif tv == "function" then
				return"[function]"
			elseif tv == "nil" then
				return nil
			else
				return string.format("[%s]", tv)
			end
		end

		local sanitizedArgs: { any }? = nil
		if args and type(args) == "table" and #args > 0 then
			sanitizedArgs = {}
			for i = 1, math.min(#args, 8) do
				(sanitizedArgs :: { any })[i] = sanitize(args[i], MAX_DEPTH)
			end
		end

		table.insert(self.TransitionHistory, {
			From = self._activeStateName,
			To = name,
			Time = os.clock(),
			Args = sanitizedArgs,
			WaitSpan = (delay and delay > 0) and delay or nil,
			ContextSnapshot = if self.Context then sanitize(self.Context, MAX_DEPTH) else nil,
			TransitionId = self._transitionId,
		})
		while #self.TransitionHistory > (self._transitionHistoryMax or 100) do
			table.remove(self.TransitionHistory, 1)
		end
	end

	-- Enter New State
	self.CurrentState = newState
	self._activeStateName = name
	self.State = name
	-- Reset the per-state timeout flag so the declarative `Timeout`+`OnTimeout`
	-- fires once per entry (not once over the lifetime of the state object).
	-- Same state object can be re-entered (e.g. via WaitSpan or
	-- ScheduleTransition self-loop) and each entry should get a fresh
	-- timeout.
	if typeof(newState) == "table" then
		(newState :: any)._timeoutFired = nil
	end
	self._stateChanged:Fire(name, oldState) -- fire AFTER commit

	if newState then
		if isTerminalState(self, name) then
			-- Run OnEnter synchronously for terminal states since auto-finish runs immediately after
			if typeof(newState) == "function" then
				local ok, cleanupFunction = xpcall(newState, xpcallHandler, self, table.unpack(args))
				if not ok then
					self.Logger:Log({Level = "ERROR", Message = "Terminal function state error: "..tostring(cleanupFunction)})
				elseif type(cleanupFunction) == "function" then
					self._legacyCleanup[name] = cleanupFunction
				end
			elseif typeof(newState) == "table" and type(newState.OnEnter) == "function" then
				local ok, err = xpcall(newState.OnEnter, xpcallHandler, newState, self, table.unpack(args))
				if not ok then self.Logger:Log({Level = "ERROR", Message = "Terminal OnEnter error: "..tostring(err)}) end
			end
		else
			-- Non-terminal: defer as before
			if typeof(newState) == "function" then
				local capturedFn = newState
				local capturedName = name
				-- Capture the _transitionId at entry time. If the FSM has
				-- changed state by the time our deferred frame runs, the
				-- _transitionId will have advanced and we bail out. This
				-- prevents deferred OnEnter code from running against a
				-- stale state after a rapid A→B→C transition sequence where
				-- A's deferred action hasn't fired yet when B is entered.
				local entryTransitionId = self._transitionId
				task.defer(function()
					if not self.IsActive then return end
					if self._activeStateName ~= capturedName then return end
					if self._transitionId ~= entryTransitionId then return end
					local success, cleanupFunction = xpcall(function()
						return capturedFn(self, table.unpack(args))
					end, xpcallHandler)
					if not success then
						self.Logger:Log
						{
							Level = "ERROR",
							Message = string.format("Error executing state function '%s': %s", capturedName, tostring(cleanupFunction)),
							OperationId = self.Id
						}
					elseif type(cleanupFunction) == "function" then
						if capturedName == self._activeStateName then
							self._legacyCleanup[capturedName] = cleanupFunction
						else
							-- State changed during execution — run cleanup immediately
							local cleanupSuccess, cleanupResult = pcall(cleanupFunction)
							if not cleanupSuccess then
								self.Logger:Log
								{
									Level = "ERROR",
									Message = string.format("Error in cleanup function for state '%s': %s", capturedName, tostring(cleanupResult)),
									OperationId = self.Id
								}
							end
						end
					end
				end)
				self.Logger:Log
				{
					Level = "DEBUG",
					Message = string.format("Entered function state '%s'.", name),
					OperationId = self.Id
				}
			elseif typeof(newState) == "table" then
				if type(newState.OnEnter) == "function" then
					-- Same stale-state guard as the function-state path above.
					local capturedOnEnter = newState.OnEnter
					local capturedState = newState
					local capturedName2 = name
					local entryTid2 = self._transitionId
					task.defer(function()
						if not self.IsActive then return end
						if self._activeStateName ~= capturedName2 then return end
						if self._transitionId ~= entryTid2 then return end
						local ok, err = xpcall(capturedOnEnter, xpcallHandler, capturedState, self, table.unpack(args))
						if not ok then
							self.Logger:Log({
								Level = "ERROR",
								Message = string.format("OnEnter error in state '%s': %s", capturedName2, tostring(err)),
								OperationId = self.Id,
							})
						end
					end)
					self.Logger:Log
					{
						Level = "DEBUG",
						Message = string.format("Entered state object '%s'.", name),
						OperationId = self.Id
					}
				end
			end
		end
	end

	-- Auto-Finish Terminal States
	-- Any state listed in TerminalStates is considered an end-state.
	-- Default behavior is to Complete unless explicitly Failed/Cancelled.
	if isTerminalState(self, name) then
		if name == "Failed" then
			self:Fail()
		elseif name == "Cancelled" then
			self:Cancel()
		else
			self:Finish()
		end
	end

	-- ─── RELEASE REENTRANCE GUARD + DRAIN QUEUE ──────────────────────────
	releaseTransitionGuard(self)
end


--[=[
	Virtual lifecycle hook called by `_Teardown` after the FSM has been
	deactivated and removed from `ActiveMachines`. Subclasses override this
	to perform FSM-specific teardown (e.g. returning resources, notifying
	other systems). The base implementation is intentionally empty.

	@reads None
	@writes Nothing (base implementation is a no-op stub)
]=]
function BaseStateMachine:OnCleanup()
end


--[=[
	Abstract hook called by `Subclass.new` (from `BaseStateMachine.Extend`)
	immediately after the instance metatable is installed. Subclasses override
	this to call `self:AddState(...)` and `self:AddSubMachine(...)` for every
	state in the FSM. The base implementation logs a WARN to remind
	implementers to override it; failing to do so leaves the FSM with no
	registered states.

	@reads None
	@writes self._states, self._transitions (via AddState calls in overrides)
]=]
function BaseStateMachine:RegisterStates()
	-- Virtual method intended to be overridden by subclasses
	self.Logger:Log
	{
		Level = "WARN",
		Message = "Abstract Method 'RegisterStates' called.",
		OperationId = self.Id
	}
	self.Logger:Log
	{
		Level = "WARN",
		Message = "Subclasses must implement 'RegisterStates' to define FSM states.",
		OperationId = self.Id
	}
end


--[=[
	Internal deactivation routine shared by `Finish`, `Fail`, `Cancel`, and
	`Destroy`. Sets `IsActive = false`, nils `_activeStateName`, calls
	`OnLeave` for the current state (xpcall'd), runs any pending legacy
	cleanup function for the leaving state, cancels the pending timed
	transition, removes the machine from `ActiveMachines` (stopping the
	global heartbeat if no machines remain), and finally invokes `OnCleanup`.

	@reads self.IsActive, self.CurrentState, self._legacyCleanup,
	       self._pendingTimedTransition, ActiveMachines, GlobalHeartbeat
	@writes self.IsActive = false, self._activeStateName = nil,
	        self.CurrentState = nil, self._pendingTimedTransition = nil,
	        self.WaitSpan = 0, ActiveMachines, GlobalHeartbeat
]=]
function BaseStateMachine:_Teardown()
	local wasActive = self.IsActive
	self.IsActive = false
	local teardownStateName = self._activeStateName
	self._activeStateName = nil

	-- Execute OnLeave for the current state before tearing down.
	-- Nil CurrentState BEFORE calling OnLeave to prevent double-call
	-- (ChangeState's OnLeave + _Teardown's OnLeave on the same state).
	local leavingState = self.CurrentState
	self.CurrentState = nil
	if wasActive and typeof(leavingState) == "table" and leavingState.OnLeave then
		local ok, err = xpcall(function() leavingState.OnLeave(leavingState, self) end, xpcallHandler)
		if not ok then self.Logger:Log({ Level = "ERROR", Message = "OnLeave during teardown threw: " .. tostring(err) }) end
	end

	-- Execute any pending legacy cleanup for the current state
	if wasActive and self._legacyCleanup and teardownStateName and self._legacyCleanup[teardownStateName] then
		local success, err = pcall(self._legacyCleanup[teardownStateName])
		if not success then
			self.Logger:Log({ Level = "ERROR", Message = string.format("Error in cleanup function during teardown: %s", tostring(err)) })
		end
		self._legacyCleanup[teardownStateName] = nil
	end

	self._pendingTimedTransition = nil
	self.WaitSpan = 0
	ActiveMachines[self] = nil
	if next(ActiveMachines) == nil and GlobalHeartbeat then
		GlobalHeartbeat:Disconnect()
		GlobalHeartbeat = nil
	end

	if wasActive then
		self:OnCleanup()
	end
end


--[=[
	Marks the FSM as successfully completed. Calls `_Teardown` to deactivate
	and then fires the `Completed` signal. No-ops if already inactive.
	Typically called automatically when a terminal state (that is not "Failed"
	or "Cancelled") is entered via `ChangeState`.

	@reads self.IsActive
	@writes self.IsActive = false (via _Teardown)
	@fires Completed
]=]
function BaseStateMachine:Finish()
	if not self.IsActive then return end
	self:_Teardown()
	self._completed:Fire()
	self.Logger:Log
	{
		Level = "INFO",
		Message = "StateMachine Completed Successfully.",
		OperationId = self.Id
	}
end


--[=[
	Marks the FSM as failed. Aggregates all ERROR-level log entries from the
	Logger's history (if available) into `combinedReason`, calls `_Teardown`,
	stores the reason in `self._error` and `self.Error`, and fires the `Failed`
	signal with the combined reason string. No-ops if already inactive.

	@param reason string? -- Optional explicit failure reason; combined with logged errors.
	@reads self.IsActive, self.Logger.History
	@writes self._error, self.Error
	@fires Failed(combinedReason)
]=]
function BaseStateMachine:Fail(reason: string?)
	if not self.IsActive then return end
	-- Concat all error logs for reason
	local combinedReason = reason or ""
	local logs = self.Logger and self.Logger.History
	if logs then
		for _, logEntry in ipairs(logs) do
			if logEntry.Level == "ERROR" then
				combinedReason = combinedReason .. logEntry.Message::string .." | "
			end
		end
	end
	if combinedReason ~= "" then
		combinedReason = combinedReason:gsub(" | $","")
	else
		combinedReason = "StateMachine failed"
	end

	self._error = combinedReason
	self.Error = combinedReason
	self:_Teardown()
	self._failed:Fire(combinedReason)
	self.Logger:Log
	{
		Level = "ERROR",
		Message = "StateMachine Failed: " .. combinedReason .." " .. tostring(self.Context),
		OperationId = self.Id
	}
end


--[=[
	Cancels the FSM cleanly. Idempotent: uses `_cancelledFired` to ensure the
	`Cancelled` signal fires at most once even if `Cancel` is called multiple
	times or after `Destroy`. Calls `_Teardown` if the machine is still active,
	then fires `Cancelled`. Does not fire if the FSM has already been destroyed.

	@reads self._cancelledFired, self.IsActive, self._cancelled, self._destroyed
	@writes self._cancelledFired = true
	@fires Cancelled
]=]
function BaseStateMachine:Cancel()
	-- Idempotent: only fire Cancelled once, even if Cancel is called multiple
	-- times or after Destroy. _Teardown is also no-op if already inactive.
	if self._cancelledFired then return end
	self._cancelledFired = true

	if self.IsActive then
		self:_Teardown()
	end

	if self._cancelled and not self._destroyed then
		self._cancelled:Fire()
	end
	self.Logger:Log
	{
		Level = "WARN",
		Message = "StateMachine Cancelled.",
		OperationId = self.Id
	}
end


--[=[
	Permanently destroys the FSM. Idempotent via the `_destroyed` guard.
	Unregisters from the Orchestrator's Registry if present, calls `_Teardown`,
	runs all cleanup tasks (Instances, Connections, functions, tables), clears
	the transition queue, history ring buffer, and Logger history, nulls out
	the Context orchestrator references, then destroys all four lifecycle signals.

	@reads self._destroyed, self.Context, self._cleanupTasks, self._managedInstances
	@writes self._destroyed = true, self.Context (cleared), signals destroyed
]=]
function BaseStateMachine:Destroy()
	-- Idempotent: a double-Destroy would otherwise re-iterate cleanup tasks
	-- and emit a misleading "Destroying" log a second time.
	if self._destroyed then return end
	self._destroyed = true

	self:Log
	{
		Level = "INFO",
		Message = "Destroying StateMachine.",
		OperationId = self.Id
	}

	local orchestrator = self:GetOrchestrator()
	local registry = orchestrator and orchestrator.Factory and orchestrator.Factory.Registry
	if registry and type(registry.GetStateMachine) == "function" and type(registry.UnregisterStateMachine) == "function" then
		local registered = registry.GetStateMachine(self.Id)
		if registered == self then
			registry.UnregisterStateMachine(self.Id)
		end
	end

	self:_Teardown()
	-- Log managed Instance cleanup count for diagnostics
	if #self._managedInstances > 0 then
		local aliveCount = 0
		for _, entry in ipairs(self._managedInstances) do
			if entry.Instance and entry.Instance.Parent ~= nil then
				aliveCount += 1
			end
		end
		if aliveCount > 0 then
			self:Log { Level = "DEBUG", Message = string.format("Cleaning up %d managed Instances", aliveCount) }
		end
	end
	self._managedInstances = {}
	for _, cleanupTask in ipairs(self._cleanupTasks) do
		pcall(function()
			if typeof(cleanupTask) == "Instance" then cleanupTask:Destroy()
			elseif typeof(cleanupTask) == "RBXScriptConnection" then cleanupTask:Disconnect()
			elseif type(cleanupTask) == "function" then cleanupTask()
			elseif type(cleanupTask) == "table" and cleanupTask.Destroy then cleanupTask:Destroy()
			end
		end)
	end
	self._cleanupTasks = {}
	-- Clear transition queue so any deferred drains become no-ops
	if self._pendingTransitions then table.clear(self._pendingTransitions) end
	-- Free history ring buffer
	if self.TransitionHistory then table.clear(self.TransitionHistory) end
	-- Free logger history + summary
	if self.Logger then
		if self.Logger.History then table.clear(self.Logger.History) end
		if self.Logger.Summary then table.clear(self.Logger.Summary) end
	end

	local context = self.Context
	if type(context) == "table" then
		context._Orchestrator = nil
		context.Orchestrator = nil
		context.FSM = nil
	end
	self.Context = nil

	if self._completed then self._completed:Destroy() end
	if self._failed then self._failed:Destroy() end
	if self._cancelled then self._cancelled:Destroy() end
	if self._stateChanged then self._stateChanged:Destroy() end
end


--[=[
	Forwards a log entry to the instance's Logger with `self.Id` as the
	`OperationId`, ensuring every log line can be correlated back to the
	specific FSM instance that emitted it.

	@param params { Level: string, Message: string, Data: any? } -- Log level,
	       message text, and optional structured data payload.
	@reads self.Logger, self.Id
	@writes Logger output
]=]
function BaseStateMachine:Log(params: { Level: string, Message: string, Data: any? })
	self.Logger:Log
	{
		Level = params.Level,
		Message = params.Message,
		OperationId = self.Id,
		Data = params.Data
	}
end
-- END BUILT-INS

return BaseStateMachine
