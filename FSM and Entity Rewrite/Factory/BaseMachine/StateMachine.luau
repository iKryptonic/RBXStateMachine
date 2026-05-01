--!strict
--[[
    @module BaseStateMachine
    @author iKrypto
    @version 3.0
    @description Abstract finite state machine with lifecycle management,
    transition validation, timeout support, sub-machine composition, and
    centralized update loop.
    
    Uses ContextObject for shared cleanup/logging/perf infrastructure.
    
    Key features:
        - Eager transition validation during AddState
        - Explicit terminal state auto-completion
        - Per-state and global timeouts
        - Priority-based update frequency
        - Sub-machine composition via AddSubMachine
        - Function and object-based state definitions
    
    Usage:
        local BSM = require(path.to.BaseStateMachine)
        BSM.Initialize(Util)
        
        local PatrolFSM = BSM.Extend({
            className = "PatrolFSM",
            validStates = { "Idle", "Patrol", "Chase", "Done" },
            terminalStates = { "Done" },
            InitialState = "Idle",
            Priority = BSM.Priorities.Medium,
        })
        
        function PatrolFSM:RegisterStates()
            self:AddState("Idle", { ... })
            self:AddState("Patrol", { ... }, { "Idle", "Chase", "Done" })
        end
]]

local RunService = game:GetService("RunService")

local Enums = require(script.Parent.Enums)

local BaseStateMachine = {}

local Logger, Signal, Settings
local Initialized = false

--============================================================================--
-- Centralized Update Loop
--============================================================================--

local ActiveMachines: { [any]: boolean } = {}
local GlobalHeartbeat: RBXScriptConnection? = nil
local GlobalFrameCount = 0

--============================================================================--
-- Priority Levels (re-exported from Enums for convenience)
--============================================================================--

BaseStateMachine.Priorities = Enums.Priority

--============================================================================--
-- Module Initialization
--============================================================================--

function BaseStateMachine.Initialize(Util: any)
    if Initialized then return end
    Initialized = true
    Settings = Util.Settings
    Logger = Util.Logger
    Signal = Util.Signal

    local log = Logger.new({ Name = "BaseStateMachine" })
    log:Log({ Level = Enums.LogLevel.INFO, Message = "BaseStateMachine initialized (v3.0)" })
end

--============================================================================--
-- Helpers
--============================================================================--

local function xpcallHandler(err: any): string
    return debug.traceback(tostring(err))
end

local function getTableKeys(tbl: { [any]: any }): { string }
    local keys = {}
    for k in pairs(tbl) do
        table.insert(keys, tostring(k))
    end
    table.sort(keys)
    return keys
end

local function isTerminalState(self: any, stateName: string): boolean
    local terminals = rawget(self, "TerminalStates")
    return type(terminals) == "table" and terminals[stateName] == true
end

--============================================================================--
-- Metamethods
--============================================================================--

local function __index(t: any, k: string)
    if k == "State" then return rawget(t, "_state") end

    local mt = getmetatable(t :: any) :: any
    if mt then
        local member = mt[k]
        if member ~= nil then return member end
    end

    local context = rawget(t, "Context")
    if context and context[k] ~= nil then
        return context[k]
    end

    return nil
end

local function __newindex(t: any, k: string, v: any)
    if k == "State" and type(v) == "string" then
        t:ChangeState({ Name = v, Args = t.Context })
        return
    end
    rawset(t, k, v)
end

local function __tostring(t: any)
    return string.format(
        "StateMachine(%s) %s : [%s]",
        t.Id or "-id-",
        t.Name or "-name-",
        t.State or "-state-"
    )
end

BaseStateMachine.__index = __index
BaseStateMachine.__newindex = __newindex
BaseStateMachine.__tostring = __tostring

--============================================================================--
-- Constructor
--============================================================================--

--[[
    @description Creates a new BaseStateMachine instance.
    @param params FSMConstructorParams
    @return BaseStateMachine
]]
function BaseStateMachine.new(params: {
    Id: string,
    Name: string?,
    ValidStates: { string }?,
    TerminalStates: { string }?,
    InitialState: string?,
    Context: any?,
    Priority: number?,
    AutoCompleteTerminalStates: boolean?,
    StateTimeout: number?,
})
    assert(Initialized, "BaseStateMachine not initialized. Call BaseStateMachine.Initialize(Util) first.")

    local self = setmetatable(BaseStateMachine.ContextObject.new(), BaseStateMachine)

    self.Id = params.Id
    self.Name = params.Name or "BaseStateMachine"
    self.Logger = self._logger
    self.Context = params.Context or {}

    self.Priority = params.Priority or Enums.Priority.Render
    self._offset = math.random(0, math.max(1, self.Priority) - 1)
    self._accumulatedDt = 0

    self._states = {} :: { [string]: any }
    self._transitions = {} :: { [string]: { string } }
    self._stateTimeouts = {} :: { [string]: number }
    self._activeCleanupFunctions = {} :: { (() -> ())? }

    self:InitPerf()

    self.CurrentState = nil :: any?
    rawset(self, "_state", nil :: string?)
    self.StateDuration = 0
    self.TotalDuration = 0
    self.WaitSpan = 0
    self.TransitionCount = 0
    self._transitionId = 0
    self._stateStartTime = 0
    self.GlobalStateTimeout = params.StateTimeout or 0

    -- ValidStates lookup
    self.validStates = {} :: { [string]: boolean }
    local validList = params.ValidStates
    if validList then
        for _, name in ipairs(validList) do
            self.validStates[name] = true
        end
    end

    -- Terminal states
    self.TerminalStates = {} :: { [string]: boolean }
    self.AutoCompleteTerminalStates = if params.AutoCompleteTerminalStates ~= nil
        then params.AutoCompleteTerminalStates
        else true

    local terminalList = params.TerminalStates
    if terminalList then
        for _, name in ipairs(terminalList) do
            if next(self.validStates) and not self.validStates[name] then
                self.Logger:Log({
                    Level = Enums.LogLevel.ERROR,
                    Message = string.format("TerminalState '%s' not in ValidStates", name),
                })
                continue
            end
            self.TerminalStates[name] = true
        end
    end

    self.IsActive = false
    self.initialState = params.InitialState or (validList and validList[1]) or nil

    if self.initialState and next(self.validStates) and not self.validStates[self.initialState] then
        self.Logger:Log({
            Level = Enums.LogLevel.ERROR,
            Message = string.format("InitialState '%s' not in ValidStates", tostring(self.initialState)),
        })
        self.initialState = nil
    end

    -- Events
    self._completed = Signal.new()
    self._failed = Signal.new()
    self._cancelled = Signal.new()
    self._stateChanged = Signal.new()

    self.Completed = self._completed
    self.Failed = self._failed
    self.Cancelled = self._cancelled
    self.StateChanged = self._stateChanged

    return self
end

--============================================================================--
-- Extend (Subclass Factory)
--============================================================================--

--[[
    @description Creates a subclass from extension parameters.
    @param extensionParams FSMExtendParams
    @return any -- Subclass table with .new constructor
]]
function BaseStateMachine.Extend(extensionParams: {
    className: string,
    validStates: { string }?,
    terminalStates: { string }?,
    InitialState: string?,
    context: { [any]: any }?,
    Priority: number?,
    AutoCompleteTerminalStates: boolean?,
    StateTimeout: number?,
    -- Aliases
    ValidStates: { string }?,
    TerminalStates: { string }?,
    initialState: string?,
})
    local Subclass: any = {}
    Subclass.__index = Subclass
    Subclass.Definition = extensionParams

    setmetatable(Subclass, { __index = BaseStateMachine })

    function Subclass.new(...)
        local args = { ... }
        local ctorArgs = args[1] or {} :: any

        local self = BaseStateMachine.new({
            Id = ctorArgs.Id or ctorArgs.StateMachineId,
            Name = extensionParams.className,
            ValidStates = extensionParams.validStates or extensionParams.ValidStates,
            TerminalStates = extensionParams.terminalStates or extensionParams.TerminalStates,
            InitialState = extensionParams.InitialState
                or extensionParams.initialState
                or (extensionParams.validStates and extensionParams.validStates[1])
                or nil,
            Context = ctorArgs,
            Priority = extensionParams.Priority or Enums.Priority.Render,
            AutoCompleteTerminalStates = extensionParams.AutoCompleteTerminalStates,
            StateTimeout = extensionParams.StateTimeout,
        })

        local instanceMT = {
            __index = __index,
            __newindex = __newindex,
            __tostring = __tostring,
            __metatable = Subclass,
        }
        setmetatable(self :: any, instanceMT)

        if self.RegisterStates then
            self:RegisterStates()
        else
            self.Logger:Log({
                Level = Enums.LogLevel.WARN,
                Message = string.format("Subclass '%s' did not implement RegisterStates", extensionParams.className),
                OperationId = self.Id,
            })
        end

        return self
    end

    return Subclass
end

--============================================================================--
-- State Registration
--============================================================================--

--[[
    @description Registers a state definition with optional transition validation.
    
    @param name string
    @param state StateObject | function
    @param validOutcomes { string }? -- Legal transitions from this state
    @param timeout number? -- Per-state timeout override
    @return boolean, string?
]]
function BaseStateMachine:AddState(
    name: string,
    state: any,
    validOutcomes: { string }?,
    timeout: number?
): (boolean, string?)
    -- Validate name is in validStates
    if next(self.validStates) and not self.validStates[name] then
        local msg = string.format(
            "State '%s' not in validStates. Valid: %s",
            name,
            table.concat(getTableKeys(self.validStates), ", ")
        )
        self.Logger:Log({ Level = Enums.LogLevel.ERROR, Message = msg, OperationId = self.Id })
        return false, msg
    end

    -- Eager validation: check outcomes are in validStates
    if validOutcomes and next(self.validStates) then
        for _, outcome in ipairs(validOutcomes) do
            if not self.validStates[outcome] then
                local msg = string.format(
                    "State '%s' has invalid outcome '%s'. Valid: %s",
                    name, outcome, table.concat(getTableKeys(self.validStates), ", ")
                )
                self.Logger:Log({ Level = Enums.LogLevel.ERROR, Message = msg, OperationId = self.Id })
                return false, msg
            end
        end
    end

    self._states[name] = state
    self._transitions[name] = validOutcomes or {}

    if timeout then
        self._stateTimeouts[name] = timeout
    end

    self.Logger:Log({
        Level = Enums.LogLevel.DEBUG,
        Message = string.format(
            "State '%s' registered (%d outcomes%s)",
            name,
            validOutcomes and #validOutcomes or 0,
            timeout and string.format(", timeout: %.1fs", timeout) or ""
        ),
        OperationId = self.Id,
    })

    return true, nil
end

--[[
    @description Registers a state that wraps a child StateMachine.
    @param name string
    @param subMachineClass any
    @param config SubMachineConfig
    @return boolean, string?
]]
function BaseStateMachine:AddSubMachine(
    name: string,
    subMachineClass: any,
    config: {
        Transitions: { OnCompleted: string?, OnFailed: string?, OnCancelled: string? },
        InitialState: string,
        StoreReference: string?,
    }
): (boolean, string?)
    local transitions = config.Transitions
    if not transitions then
        return false, "AddSubMachine requires Transitions config"
    end
    if not config.InitialState then
        return false, "AddSubMachine requires InitialState"
    end

    local subState = {} :: any

    function subState:OnEnter(fsm: any)
        self._connections = {}
        self.Machine = subMachineClass.new({
            StateMachineId = fsm.Id .. "." .. name,
            Context = fsm.Context,
        })

        if config.StoreReference then
            fsm.Context[config.StoreReference] = self.Machine
        end

        table.insert(self._connections, self.Machine.Completed:Connect(function()
            if transitions.OnCompleted then
                fsm.State = transitions.OnCompleted
            else
                fsm:Finish()
            end
        end))

        table.insert(self._connections, self.Machine.Failed:Connect(function(reason: any)
            if transitions.OnFailed then
                fsm.State = transitions.OnFailed
            else
                fsm:Fail(reason)
            end
        end))

        table.insert(self._connections, self.Machine.Cancelled:Connect(function()
            if transitions.OnCancelled then
                fsm.State = transitions.OnCancelled
            else
                fsm:Cancel()
            end
        end))

        self.Machine:Start({ State = config.InitialState })
    end

    function subState:OnLeave(fsm: any)
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

    return self:AddState(name, subState, validOutcomes)
end

--[[
    @description Registers a disposable for cleanup on FSM destroy.
    @param object any
    @return any
]]
function BaseStateMachine:Manage(object: any): any
    table.insert(self._cleanupTasks, object)
    return object
end

--============================================================================--
-- Runtime: Centralized Loop
--============================================================================--

--[[
    @description Disables the internal RunService heartbeat for external Step() control.
]]
function BaseStateMachine.DisableInternalLoop()
    if GlobalHeartbeat then
        GlobalHeartbeat:Disconnect()
        GlobalHeartbeat = nil
    end
    BaseStateMachine._ExternalLoop = true
end

--[[
    @description Drives all active state machines for one frame.
    Call this externally if you've disabled the internal loop.
    @param dt number
]]
function BaseStateMachine.Step(dt: number)
    GlobalFrameCount += 1
    for machine in pairs(ActiveMachines) do
        if machine.IsActive then
            machine._accumulatedDt += dt

            if (GlobalFrameCount + machine._offset) % machine.Priority == 0 then
                local stepDt = machine._accumulatedDt
                machine._accumulatedDt = 0

                if machine.Priority == 1 then
                    -- Render priority: inline
                    local ok, err = xpcall(machine._Update, xpcallHandler, machine, stepDt)
                    if not ok then
                        machine.Logger:Log({
                            Level = Enums.LogLevel.ERROR,
                            Message = string.format("Update error: %s", tostring(err)),
                            OperationId = machine.Id,
                        })
                    end
                else
                    -- Lower priority: spawned to avoid blocking
                    task.spawn(function()
                        local ok, err = xpcall(machine._Update, xpcallHandler, machine, stepDt)
                        if not ok then
                            machine.Logger:Log({
                                Level = Enums.LogLevel.ERROR,
                                Message = string.format("Update error: %s", tostring(err)),
                                OperationId = machine.Id,
                            })
                        end
                    end)
                end
            end
        end
    end
end

--============================================================================--
-- Runtime: Start / Update / ChangeState
--============================================================================--

--[[
    @description Begins execution of the state machine.
    @param params { State: string?, Args: { any }? }?
    @return boolean, string?
]]
function BaseStateMachine:Start(params: { State: string?, Args: { any }? }?): (boolean, string?)
    if self.IsActive then
        return false, "StateMachine is already active"
    end

    self.IsActive = true
    local startParams = params or {}

    local startState = startParams.State or self.initialState
    if not startState then
        self.IsActive = false
        return false, "No start state provided and no InitialState defined"
    end

    -- Register in centralized loop
    ActiveMachines[self] = true
    if not GlobalHeartbeat and not BaseStateMachine._ExternalLoop then
        GlobalHeartbeat = RunService.Heartbeat:Connect(BaseStateMachine.Step)
    end

    self.Logger:Log({
        Level = Enums.LogLevel.DEBUG,
        Message = "Started. Initial: " .. tostring(startState),
        OperationId = self.Id,
    })

    self:ChangeState({ Name = startState, Args = startParams.Args })
    return true, nil
end

--[[
    @description Internal update tick called by the centralized loop.
    Handles timeout checking, condition-based transitions, and OnHeartbeat.
    Memory is sampled periodically (not every frame) for performance.
    
    @param dt number
]]
function BaseStateMachine:_Update(dt: number)
    if not self.IsActive then return end

    self:InitPerf()
    local t0 = os.clock()
    local mem0 = self:ShouldSampleMemory() -- Only samples periodically

    self.TotalDuration += dt
    self.StateDuration += dt

    -- State timeout check
    local stateTimeout = self._stateTimeouts[self.State or ""] or self.GlobalStateTimeout
    if stateTimeout > 0 and self.StateDuration >= stateTimeout then
        self.Logger:Log({
            Level = Enums.LogLevel.WARN,
            Message = string.format("State '%s' timed out after %.2fs", tostring(self.State), self.StateDuration),
            OperationId = self.Id,
        })
        self:Fail(string.format("State '%s' timed out", tostring(self.State)))
        return
    end

    -- Process current state
    local currentState = self.CurrentState
    if typeof(currentState) == "table" then
        -- Condition-based transitions
        if currentState.Transitions then
            for _, transition in ipairs(currentState.Transitions) do
                if transition.Condition(self, dt) then
                    self:ChangeState({ Name = transition.TargetState, Args = transition.Args })
                    self:RecordPerf(t0, mem0)
                    return
                end
            end
        end

        -- OnHeartbeat
        if currentState.OnHeartbeat then
            currentState.OnHeartbeat(self, dt)
        end
    end

    self:RecordPerf(t0, mem0)
end

--[[
    @description Transitions to a new state with validation.
    @param params { Name: string, Args: { any }? }
    @return boolean, string?
]]
function BaseStateMachine:ChangeState(params: { Name: string, Args: { any }? }): (boolean, string?)
    if not self.IsActive then
        return false, "Cannot change state on inactive FSM"
    end

    local name = params.Name
    local args = params.Args or {}

    -- Handle WaitSpan delay
    local delay = self.WaitSpan
    self.WaitSpan = 0
    if delay > 0 then
        self._transitionId += 1
        local tid = self._transitionId
        task.delay(delay, function()
            if self.IsActive and self._transitionId == tid then
                self:ChangeState({ Name = name, Args = args })
            end
        end)
        return true, "Transition delayed"
    end

    -- Validate state is in validStates
    if next(self.validStates) and not self.validStates[name] then
        local msg = string.format(
            "Invalid state '%s'. Valid: %s",
            name, table.concat(getTableKeys(self.validStates), ", ")
        )
        self.Logger:Log({ Level = Enums.LogLevel.ERROR, Message = msg, OperationId = self.Id })
        return false, msg
    end

    -- Invalidate pending transitions
    self._transitionId += 1

    local oldState = self.State
    local newState = self._states[name]

    -- Validate transition legality
    if self.State then
        local allowed = self._transitions[self.State]
        if allowed and #allowed > 0 then
            local isLegal = false
            for _, outcome in ipairs(allowed) do
                if outcome == name then
                    isLegal = true
                    break
                end
            end
            if not isLegal then
                local msg = string.format(
                    "Illegal transition '%s' → '%s'. Allowed: %s",
                    tostring(self.State), name, table.concat(allowed, ", ")
                )
                self.Logger:Log({ Level = Enums.LogLevel.ERROR, Message = msg, OperationId = self.Id })
                return false, msg
            end
        end

        -- Leave current state
        if typeof(self.CurrentState) == "table" and self.CurrentState.OnLeave then
            self.CurrentState.OnLeave(self)
        end

        -- Execute ALL active cleanup functions (LIFO)
        for i = #self._activeCleanupFunctions, 1, -1 do
            local cleanupFn = self._activeCleanupFunctions[i]
            if cleanupFn then
                local ok, err = pcall(cleanupFn)
                if not ok then
                    self.Logger:Log({
                        Level = Enums.LogLevel.ERROR,
                        Message = string.format("State cleanup error: %s", tostring(err)),
                        OperationId = self.Id,
                    })
                end
            end
        end
        table.clear(self._activeCleanupFunctions)
    end

    -- Verify state registration (allow implicit terminal states)
    if not newState and not self.TerminalStates[name] then
        local msg = string.format("State '%s' is not registered", name)
        self.Logger:Log({ Level = Enums.LogLevel.ERROR, Message = msg, OperationId = self.Id })
        return false, msg
    end

    -- Update counters
    if name == self.State then
        self.TransitionCount += 1
    else
        self.Logger:Log({
            Level = Enums.LogLevel.DEBUG,
            Message = string.format("'%s' → '%s'", tostring(self.State), name),
            OperationId = self.Id,
        })
        self.StateDuration = 0
        self.TransitionCount = 1
        self._stateStartTime = os.clock()
    end

    -- Enter new state
    rawset(self, "_state", name)
    self._stateChanged:Fire(name, oldState)
    self.CurrentState = newState

    if newState then
        if typeof(newState) == "table" then
            if type(newState.OnEnter) == "function" then
                newState.OnEnter(self, table.unpack(args))
            end
        elseif typeof(newState) == "function" then
            local cleanupFn = newState(self, table.unpack(args))
            if type(cleanupFn) == "function" then
                table.insert(self._activeCleanupFunctions, cleanupFn)
            end
        end
    end

    -- Auto-complete terminal states
    if self.AutoCompleteTerminalStates and isTerminalState(self, name) then
        if name == "Failed" then
            self:Fail()
        elseif name == "Cancelled" then
            self:Cancel()
        else
            self:Finish()
        end
    end

    return true, nil
end

--============================================================================--
-- Lifecycle: Finish / Fail / Cancel / Destroy
--============================================================================--

--- Virtual method for subclass cleanup. Called during _Teardown.
function BaseStateMachine:OnCleanup()
    -- Override in subclasses
end

--- Virtual method for state registration. Called during construction.
function BaseStateMachine:RegisterStates()
    self.Logger:Log({
        Level = Enums.LogLevel.WARN,
        Message = "RegisterStates not implemented",
        OperationId = self.Id,
    })
end

--- Internal teardown: leaves current state, cleans up, unregisters from loop.
function BaseStateMachine:_Teardown()
    local wasActive = self.IsActive
    self.IsActive = false

    if wasActive and typeof(self.CurrentState) == "table" and self.CurrentState.OnLeave then
        self.CurrentState.OnLeave(self)
    end

    -- Execute active cleanup functions
    for _, cleanupFn in ipairs(self._activeCleanupFunctions) do
        if cleanupFn then
            local ok, err = pcall(cleanupFn)
            if not ok then
                self.Logger:Log({
                    Level = Enums.LogLevel.ERROR,
                    Message = string.format("Teardown cleanup error: %s", tostring(err)),
                    OperationId = self.Id,
                })
            end
        end
    end
    table.clear(self._activeCleanupFunctions)

    -- Unregister from centralized loop
    ActiveMachines[self] = nil
    if next(ActiveMachines) == nil and GlobalHeartbeat then
        GlobalHeartbeat:Disconnect()
        GlobalHeartbeat = nil
    end

    self:OnCleanup()
end

function BaseStateMachine:Finish()
    if not self.IsActive then return end
    self:_Teardown()
    self._completed:Fire()
    self.Logger:Log({ Level = Enums.LogLevel.INFO, Message = "Completed", OperationId = self.Id })
end

function BaseStateMachine:Fail(reason: string?)
    if not self.IsActive then return end

    local msg = reason or ""
    -- Append logged errors
    if self.Logger and self.Logger.History then
        for _, entry in ipairs(self.Logger.History) do
            if entry.Level == Enums.LogLevel.ERROR then
                msg = msg .. (entry.Message :: string) .. " | "
            end
        end
    end

    self:_Teardown()
    self._failed:Fire(msg)
    self.Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "Failed: " .. msg, OperationId = self.Id })
end

function BaseStateMachine:Cancel()
    if self.IsActive then
        self:_Teardown()
    end
    self._cancelled:Fire()
    self.Logger:Log({ Level = Enums.LogLevel.WARN, Message = "Cancelled", OperationId = self.Id })
end

--[[
    @description Fully destroys the FSM and all managed resources.
]]
function BaseStateMachine:Destroy()
    self.Logger:Log({ Level = Enums.LogLevel.INFO, Message = "Destroying", OperationId = self.Id })

    self:_Teardown()

    -- Execute managed cleanup tasks (LIFO, pcall-wrapped)
    for i = #self._cleanupTasks, 1, -1 do
        local cleanupTask = self._cleanupTasks[i]
        local ok, err = pcall(function()
            if typeof(cleanupTask) == "Instance" then
                cleanupTask:Destroy()
            elseif typeof(cleanupTask) == "RBXScriptConnection" then
                cleanupTask:Disconnect()
            elseif type(cleanupTask) == "function" then
                cleanupTask()
            elseif type(cleanupTask) == "table" and type(cleanupTask.Destroy) == "function" then
                cleanupTask:Destroy()
            end
        end)
        if not ok then
            self.Logger:Log({
                Level = Enums.LogLevel.ERROR,
                Message = string.format("Destroy cleanup error: %s", tostring(err)),
            })
        end
    end
    table.clear(self._cleanupTasks)

    -- Destroy signals
    self._completed:Destroy()
    self._failed:Destroy()
    self._cancelled:Destroy()
    self._stateChanged:Destroy()

    self._isDestroyed = true
end

--[[
    @description Logging passthrough (ContextObject compatible).
]]
function BaseStateMachine:Log(params: { Level: string, Message: string, OperationId: string?, Data: any? })
    self.Logger:Log({
        Level = params.Level,
        Message = params.Message,
        OperationId = params.OperationId or self.Id,
        Data = params.Data,
    })
end

return BaseStateMachine
