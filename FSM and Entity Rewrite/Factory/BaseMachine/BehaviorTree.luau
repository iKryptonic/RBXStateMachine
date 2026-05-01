--!strict
--[[
    @module BehaviorTree
    @author iKrypto
    @version 3.0
    @description Behavior Tree implementation with lifecycle management,
    stateful execution, blackboard, and centralized update loop.
    
    Uses ContextObject for shared cleanup/logging/perf infrastructure.
    Memory is sampled periodically (not every tick) for performance.
    
    Node builders:
        Action, Selector, Sequence, Inverter, Succeeder,
        Repeater, UntilFail, Timeout, Cooldown, Conditional,
        Condition, ContextAction, SetState
]]

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Enums = require(script.Parent.Enums)

local BehaviorTree = {}

local Logger, Signal, Settings
local Initialized = false

-- Centralized loop
local ActiveTrees: { [any]: boolean } = {}
local GlobalHeartbeat: RBXScriptConnection? = nil
local GlobalFrameCount = 0

-- Re-export for convenience
BehaviorTree.Status = Enums.BTStatus
BehaviorTree.Priorities = Enums.Priority

--============================================================================--
-- Module Init
--============================================================================--

function BehaviorTree.Initialize(Util: any)
    if Initialized then return end
    Initialized = true
    Settings = Util.Settings
    Logger = Util.Logger
    Signal = Util.Signal

    local log = Logger.new({ Name = "BehaviorTree" })
    log:Log({ Level = Enums.LogLevel.INFO, Message = "BehaviorTree initialized (v3.0)" })
end

--============================================================================--
-- Helpers
--============================================================================--

local function xpcallHandler(err: any): string
    return debug.traceback(tostring(err))
end

--============================================================================--
-- Metamethods
--============================================================================--

local function __tostring(t: any)
    return string.format(
        "BehaviorTree(%s) %s : [%s]",
        t.Id or "-id-",
        t.Name or "-name-",
        t.IsRunning and "Running" or "Stopped"
    )
end

BehaviorTree.__index = BehaviorTree
BehaviorTree.__tostring = __tostring

--============================================================================--
-- Constructor
--============================================================================--

function BehaviorTree.new(params: {
    Id: string?,
    Name: string?,
    Root: any,
    Context: { [any]: any }?,
    Priority: number?,
    Blackboard: any?,
})
    assert(Initialized, "BehaviorTree not initialized.")
    assert(params.Root, "BehaviorTree.new requires a Root node")

    local self = setmetatable(BehaviorTree.ContextObject.new(), BehaviorTree)

    self.Id = params.Id or HttpService:GenerateGUID(false)
    self.Name = params.Name or "BehaviorTree"

    self.Root = params.Root
    self.Context = params.Context or {}
    self.Blackboard = params.Blackboard or BehaviorTree.CreateBlackboard()
    self.Priority = params.Priority or Enums.Priority.Medium
    self._offset = math.random(0, math.max(1, self.Priority) - 1)
    self._accumulatedDt = 0
    self.Logger = self._logger

    self.IsRunning = false
    self.LastStatus = nil :: string?
    self.TotalDuration = 0
    self._runningNodes = {} :: { any }

    self:InitPerf()

    self._completed = Signal.new()
    self._failed = Signal.new()
    self._cancelled = Signal.new()
    self._statusChanged = Signal.new()

    self.Completed = self._completed
    self.Failed = self._failed
    self.Cancelled = self._cancelled
    self.StatusChanged = self._statusChanged

    return self
end

--============================================================================--
-- Centralized Loop
--============================================================================--

function BehaviorTree.DisableInternalLoop()
    if GlobalHeartbeat then
        GlobalHeartbeat:Disconnect()
        GlobalHeartbeat = nil
    end
    BehaviorTree._ExternalLoop = true
end

function BehaviorTree.Step(dt: number)
    GlobalFrameCount += 1
    for tree in pairs(ActiveTrees) do
        if tree.IsRunning then
            tree._accumulatedDt += dt

            if (GlobalFrameCount + tree._offset) % tree.Priority == 0 then
                local stepDt = tree._accumulatedDt
                tree._accumulatedDt = 0

                if tree.Priority == 1 then
                    local ok, err = xpcall(tree._Tick, xpcallHandler, tree, stepDt)
                    if not ok then
                        tree.Logger:Log({
                            Level = Enums.LogLevel.ERROR,
                            Message = "Tick error: " .. tostring(err),
                            OperationId = tree.Id,
                        })
                        tree:Fail("Runtime error")
                    end
                else
                    task.spawn(function()
                        local ok, err = xpcall(tree._Tick, xpcallHandler, tree, stepDt)
                        if not ok then
                            tree.Logger:Log({
                                Level = Enums.LogLevel.ERROR,
                                Message = "Tick error: " .. tostring(err),
                                OperationId = tree.Id,
                            })
                            tree:Fail("Runtime error")
                        end
                    end)
                end
            end
        end
    end
end

--============================================================================--
-- Lifecycle
--============================================================================--

function BehaviorTree:Start()
    if self.IsRunning then return end
    self.IsRunning = true
    self.TotalDuration = 0
    self.LastStatus = nil

    ActiveTrees[self] = true
    if not GlobalHeartbeat and not BehaviorTree._ExternalLoop then
        GlobalHeartbeat = RunService.Heartbeat:Connect(BehaviorTree.Step)
    end

    self.Logger:Log({ Level = Enums.LogLevel.DEBUG, Message = "Started", OperationId = self.Id })
end

function BehaviorTree:_Tick(dt: number)
    if not self.IsRunning then return end

    self:InitPerf()
    local t0 = os.clock()
    local mem0 = self:ShouldSampleMemory()

    self.TotalDuration += dt

    local status = self.Root:Execute(self.Context, dt)

    if status ~= self.LastStatus then
        local old = self.LastStatus
        self.LastStatus = status
        self._statusChanged:Fire(status, old)
    end

    if status == Enums.BTStatus.Success then
        self:_Complete()
    elseif status == Enums.BTStatus.Failure then
        self:Fail("Root returned Failure")
    end

    self:RecordPerf(t0, mem0)
end

function BehaviorTree:_Complete()
    if not self.IsRunning then return end
    self:_Teardown()
    self._completed:Fire()
    self.Logger:Log({ Level = Enums.LogLevel.INFO, Message = "Completed", OperationId = self.Id })
end

function BehaviorTree:Fail(reason: string?)
    if not self.IsRunning then return end
    self:_Teardown()
    self._failed:Fire(reason or "BehaviorTree failed")
    self.Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "Failed: " .. (reason or ""), OperationId = self.Id })
end

function BehaviorTree:Cancel()
    if not self.IsRunning then return end
    self:_Teardown()
    self._cancelled:Fire()
    self.Logger:Log({ Level = Enums.LogLevel.WARN, Message = "Cancelled", OperationId = self.Id })
end

function BehaviorTree:_Teardown()
    self.IsRunning = false

    for _, node in ipairs(self._runningNodes) do
        if node.OnCancel then
            pcall(node.OnCancel, node)
        end
    end
    table.clear(self._runningNodes)

    if self.Root and self.Root.Reset then
        self.Root:Reset()
    end

    ActiveTrees[self] = nil
    if next(ActiveTrees) == nil and GlobalHeartbeat then
        GlobalHeartbeat:Disconnect()
        GlobalHeartbeat = nil
    end
end

function BehaviorTree:Reset()
    if self.IsRunning then self:Cancel() end
    if self.Root and self.Root.Reset then self.Root:Reset() end
    self.LastStatus = nil
    self.TotalDuration = 0
    self.Blackboard:Clear()
end

function BehaviorTree:Manage(object: any): any
    table.insert(self._cleanupTasks, object)
    return object
end

function BehaviorTree:Destroy()
    self.Logger:Log({ Level = Enums.LogLevel.INFO, Message = "Destroying", OperationId = self.Id })
    self:_Teardown()
    self:ExecuteCleanupTasks(self)
    self._completed:Destroy()
    self._failed:Destroy()
    self._cancelled:Destroy()
    self._statusChanged:Destroy()
    self._isDestroyed = true
end

function BehaviorTree:Log(params: { Level: string, Message: string, Data: any? })
    self.Logger:Log({
        Level = params.Level,
        Message = params.Message,
        OperationId = self.Id,
        Data = params.Data,
    })
end

--============================================================================--
-- Blackboard
--============================================================================--

function BehaviorTree.CreateBlackboard(): any
    local data = {} :: { [string]: { Value: any, Timestamp: number } }
    local bb = {} :: any

    function bb:Get(key: string): any?
        local entry = data[key]
        return entry and entry.Value or nil
    end

    function bb:Set(key: string, value: any)
        data[key] = { Value = value, Timestamp = os.clock() }
    end

    function bb:Has(key: string): boolean
        return data[key] ~= nil
    end

    function bb:Remove(key: string)
        data[key] = nil
    end

    function bb:Clear()
        table.clear(data)
    end

    function bb:GetAll(): { [string]: any }
        local result = {}
        for k, v in pairs(data) do
            result[k] = v.Value
        end
        return result
    end

    return bb
end

--============================================================================--
-- Node Builders
--============================================================================--

function BehaviorTree.Action(fn: (context: any, dt: number) -> string, name: string?): any
    local node = { Name = name or "Action" } :: any
    function node:Execute(context: any, dt: number): string return fn(context, dt) end
    function node:Reset() end
    return node
end

function BehaviorTree.Selector(children: { any }, name: string?): any
    assert(#children > 0, "Selector requires at least one child")
    local node = { Name = name or "Selector" } :: any
    local idx = 1

    function node:Execute(context: any, dt: number): string
        while idx <= #children do
            local status = children[idx]:Execute(context, dt)
            if status == Enums.BTStatus.Running then return Enums.BTStatus.Running end
            if status == Enums.BTStatus.Success then idx = 1; return Enums.BTStatus.Success end
            idx += 1
        end
        idx = 1
        return Enums.BTStatus.Failure
    end

    function node:Reset()
        idx = 1
        for _, c in ipairs(children) do if c.Reset then c:Reset() end end
    end

    function node:OnCancel()
        for _, c in ipairs(children) do if c.OnCancel then c:OnCancel() end end
    end

    return node
end

function BehaviorTree.Sequence(children: { any }, name: string?): any
    assert(#children > 0, "Sequence requires at least one child")
    local node = { Name = name or "Sequence" } :: any
    local idx = 1

    function node:Execute(context: any, dt: number): string
        while idx <= #children do
            local status = children[idx]:Execute(context, dt)
            if status == Enums.BTStatus.Running then return Enums.BTStatus.Running end
            if status == Enums.BTStatus.Failure then idx = 1; return Enums.BTStatus.Failure end
            idx += 1
        end
        idx = 1
        return Enums.BTStatus.Success
    end

    function node:Reset()
        idx = 1
        for _, c in ipairs(children) do if c.Reset then c:Reset() end end
    end

    function node:OnCancel()
        for _, c in ipairs(children) do if c.OnCancel then c:OnCancel() end end
    end

    return node
end

function BehaviorTree.Inverter(child: any, name: string?): any
    local node = { Name = name or "Inverter" } :: any
    function node:Execute(context: any, dt: number): string
        local s = child:Execute(context, dt)
        if s == Enums.BTStatus.Success then return Enums.BTStatus.Failure end
        if s == Enums.BTStatus.Failure then return Enums.BTStatus.Success end
        return s
    end
    function node:Reset() if child.Reset then child:Reset() end end
    function node:OnCancel() if child.OnCancel then child:OnCancel() end end
    return node
end

function BehaviorTree.Succeeder(child: any, name: string?): any
    local node = { Name = name or "Succeeder" } :: any
    function node:Execute(context: any, dt: number): string
        local s = child:Execute(context, dt)
        if s == Enums.BTStatus.Running then return Enums.BTStatus.Running end
        return Enums.BTStatus.Success
    end
    function node:Reset() if child.Reset then child:Reset() end end
    function node:OnCancel() if child.OnCancel then child:OnCancel() end end
    return node
end

function BehaviorTree.Repeater(child: any, count: number, name: string?): any
    local node = { Name = name or "Repeater" } :: any
    local iters = 0

    function node:Execute(context: any, dt: number): string
        if iters >= count then iters = 0; return Enums.BTStatus.Success end
        local s = child:Execute(context, dt)
        if s == Enums.BTStatus.Running then return Enums.BTStatus.Running end
        if s == Enums.BTStatus.Failure then iters = 0; return Enums.BTStatus.Failure end
        iters += 1
        if iters >= count then iters = 0; return Enums.BTStatus.Success end
        return Enums.BTStatus.Running
    end

    function node:Reset() iters = 0; if child.Reset then child:Reset() end end
    function node:OnCancel() iters = 0; if child.OnCancel then child:OnCancel() end end
    return node
end

function BehaviorTree.UntilFail(child: any, name: string?): any
    local node = { Name = name or "UntilFail" } :: any
    function node:Execute(context: any, dt: number): string
        local s = child:Execute(context, dt)
        if s == Enums.BTStatus.Failure then return Enums.BTStatus.Success end
        return Enums.BTStatus.Running
    end
    function node:Reset() if child.Reset then child:Reset() end end
    function node:OnCancel() if child.OnCancel then child:OnCancel() end end
    return node
end

function BehaviorTree.Timeout(child: any, timeout: number, name: string?): any
    local node = { Name = name or "Timeout" } :: any
    local elapsed = 0

    function node:Execute(context: any, dt: number): string
        elapsed += dt
        if elapsed >= timeout then
            elapsed = 0
            if child.Reset then child:Reset() end
            return Enums.BTStatus.Failure
        end
        local s = child:Execute(context, dt)
        if s ~= Enums.BTStatus.Running then elapsed = 0 end
        return s
    end

    function node:Reset() elapsed = 0; if child.Reset then child:Reset() end end
    function node:OnCancel() elapsed = 0; if child.OnCancel then child:OnCancel() end end
    return node
end

function BehaviorTree.Cooldown(child: any, cooldown: number, name: string?): any
    local node = { Name = name or "Cooldown" } :: any
    local lastRun = -math.huge
    local running = false

    function node:Execute(context: any, dt: number): string
        local now = os.clock()
        if running then
            local s = child:Execute(context, dt)
            if s ~= Enums.BTStatus.Running then running = false; lastRun = now end
            return s
        end
        if now - lastRun < cooldown then return Enums.BTStatus.Failure end
        running = true
        local s = child:Execute(context, dt)
        if s ~= Enums.BTStatus.Running then running = false; lastRun = now end
        return s
    end

    function node:Reset() lastRun = -math.huge; running = false; if child.Reset then child:Reset() end end
    function node:OnCancel() running = false; if child.OnCancel then child:OnCancel() end end
    return node
end

function BehaviorTree.Conditional(condition: (any) -> boolean, child: any, name: string?): any
    local node = { Name = name or "Conditional" } :: any
    function node:Execute(context: any, dt: number): string
        if not condition(context) then return Enums.BTStatus.Failure end
        return child:Execute(context, dt)
    end
    function node:Reset() if child.Reset then child:Reset() end end
    function node:OnCancel() if child.OnCancel then child:OnCancel() end end
    return node
end

function BehaviorTree.Condition(predicate: (any) -> boolean, name: string?): any
    local node = { Name = name or "Condition" } :: any
    function node:Execute(context: any, _dt: number): string
        return predicate(context) and Enums.BTStatus.Success or Enums.BTStatus.Failure
    end
    function node:Reset() end
    return node
end

function BehaviorTree.ContextAction(actionFn: (any) -> (), name: string?): any
    local node = { Name = name or "ContextAction" } :: any
    function node:Execute(context: any, _dt: number): string
        actionFn(context)
        return Enums.BTStatus.Success
    end
    function node:Reset() end
    return node
end

function BehaviorTree.SetState(stateName: string): any
    return BehaviorTree.ContextAction(function(context)
        if context.ChangeState then
            context.ChangeState(stateName)
        elseif context.State ~= nil then
            context.State = stateName
        end
    end, "SetState:" .. stateName)
end

return BehaviorTree
