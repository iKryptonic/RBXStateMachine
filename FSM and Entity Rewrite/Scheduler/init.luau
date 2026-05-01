--!strict
--[[
    @module TaskScheduler
    @author iKrypto
    @version 3.0
    @description Lightweight task scheduler with min-heap priority queue,
    frame budgeting, thread pooling, and performance tracking.
    
    Bug fixes from v2:
        - _taskCount is now properly incremented on Schedule()
        - Thread pool variable shadowing resolved
        - Memory tracking added per-task
    
    Usage:
        local Scheduler = require(path.to.TaskScheduler)
        Scheduler.Initialize(Util)
        
        local s = Scheduler.new()
        s:Schedule({
            TaskName = "MyTask",
            TaskAction = function() print("Hello") end,
            TaskExecutionDelay = 1,
            IsRecurringTask = true,
            Priority = 5,
            Event = "Heartbeat",
        })
        s:Start()
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Enums = require(script.Parent.Enums)
local TaskPool = require(script.Parent.TaskPool)
local PerformanceManager = require(script.Parent.PerformanceManager)

-- Localized globals
local os_clock = os.clock
local table_insert = table.insert
local table_remove = table.remove
local math_floor = math.floor

local Initialized = false
local defaultInstance: any? = nil

local Scheduler = {}
Scheduler.__index = Scheduler

--============================================================================--
-- Thread Pool (module-level, shared across all scheduler instances)
--============================================================================--

local freeThreads: { thread } = {}
local totalThreads = 0
local peakThreads = 0
local activeThreads = 0

local function runTask(func: (...any) -> (), thread: thread, ...: any)
    func(...)
    activeThreads = math.max(0, activeThreads - 1)
    table_insert(freeThreads, thread)
end

local function yielder()
    while true do
        runTask(coroutine.yield())
    end
end

local function ERROR_HANDLER(err: any): string
    return debug.traceback(tostring(err), 2)
end

--============================================================================--
-- Helpers
--============================================================================--

local function ValidateRequest()
    assert(Initialized, "Scheduler not initialized. Call Scheduler.Initialize(Util) first.")
end

local function ResolveScheduler(self: any): any
    ValidateRequest()
    if type(self) == "table" and rawget(self, "_heaps") then
        return self
    end
    if not defaultInstance then
        defaultInstance = Scheduler.new()
    end
    return defaultInstance
end

local function GetWeightedTime(self: any, delay: number, priority: number): number
    local weight = self.Settings.PriorityWeight or 0.001
    return os_clock() + delay - (priority * weight)
end

--============================================================================--
-- Module Init
--============================================================================--

function Scheduler.Initialize(Util: any)
    if Initialized then return end
    Initialized = true
    Scheduler.Settings = Util.Settings.Scheduler
    Scheduler.Logger = Util.Logger.new({ Name = "Scheduler" })
end

--============================================================================--
-- Constructor
--============================================================================--

--[[
    @description Creates a new Scheduler instance.
    @param settings SchedulerSettings?
    @return Scheduler
]]
function Scheduler.new(settings: any?)
    local self = setmetatable({
        Tasks = {} :: { [string]: any },
        History = table.create(100),
        _historyIndex = 1,
        _heaps = {} :: { [string]: { any } },
        _running = {} :: { [string]: any },
        _taskCount = 0,
        Settings = settings or {
            FrameBudget = 0.005,
            PriorityWeight = 0.001,
        },
        LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 },
        Logger = nil :: any,
    }, Scheduler)

    self.Logger = Scheduler.Logger
    self.PerformanceManager = PerformanceManager.new(self)
    return self
end

--============================================================================--
-- Scheduling
--============================================================================--

--[[
    @description Schedules a task for execution.
    @param params ScheduleParams
    @return ScheduledTask?
]]
function Scheduler:Schedule(params: {
    TaskName: string,
    TaskAction: () -> (),
    TaskExecutionDelay: number?,
    IsRecurringTask: boolean?,
    Priority: number?,
    Event: string?,
}): any?
    if not params.TaskName or type(params.TaskAction) ~= "function" then
        return nil
    end

    local t = TaskPool.Get()
    t.Name = params.TaskName
    t.Action = params.TaskAction
    t.Delay = params.TaskExecutionDelay or 0
    t.IsRecurringTask = params.IsRecurringTask or false
    t.Priority = params.Priority or 1
    t.Event = params.Event or Enums.SchedulerEvent.Heartbeat
    t.NextRun = os_clock() + t.Delay
    t.CreationTime = os_clock()
    t.TotalMemory = 0
    t.MaxMemory = 0

    -- If overwriting an existing task, decrement count
    if self.Tasks[t.Name] then
        self._taskCount -= 1
    end

    self.Tasks[t.Name] = t
    self._taskCount += 1  -- FIX: properly increment

    if not self._heaps[t.Event] then
        self._heaps[t.Event] = {}
    end
    self:_heapPush(self._heaps[t.Event], t)

    return t
end

--[[
    @description Removes a scheduled task by name.
    @param name string
]]
function Scheduler:Deschedule(name: string)
    self = ResolveScheduler(self)
    local t = self.Tasks[name]
    if t then
        self:AddToHistory(t, "Cancelled", 0, "")
        self.Tasks[name] = nil
        self._taskCount -= 1
    end
end

--[[
    @description Clears all tasks, heaps, and history.
]]
function Scheduler:Clear()
    self.Tasks = {}
    self._heaps = {}
    self.History = table.create(100)
    self._historyIndex = 1
    self._taskCount = 0
    self.LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 }
end

--[[
    @description Adds an entry to the circular history buffer.
]]
function Scheduler:AddToHistory(taskObj: any, status: string, duration: number, err: string?)
    self.History[self._historyIndex] = {
        Name = taskObj.Name,
        Status = status,
        Duration = duration,
        Time = os.time(),
        Error = err,
    }
    self._historyIndex = (self._historyIndex % 100) + 1
end

--[[
    @description Returns scheduled task count.
    @return number
]]
function Scheduler:GetTaskCount(): number
    return self._taskCount
end

--[[
    @description Gets a task by name.
    @param name string
    @return ScheduledTask?
]]
function Scheduler:GetTask(name: string): any?
    self = ResolveScheduler(self)
    return self.Tasks[name]
end

--[[
    @description Executes a task immediately by name or reference.
]]
function Scheduler:ExecuteTask(taskOrName: any)
    self = ResolveScheduler(self)
    local t = type(taskOrName) == "string" and self.Tasks[taskOrName] or taskOrName
    if not t then return end
    self:_internalExecute(t)
end

--[[
    @description Resets a task's performance counters.
]]
function Scheduler:ResetTask(name: string)
    self = ResolveScheduler(self)
    local t = self.Tasks[name]
    if t then
        t.RunCount = 0
        t.TotalRunTime = 0
        t.MaxRunTime = 0
        t.TotalMemory = 0
        t.MaxMemory = 0
    end
end

function Scheduler:GenerateKey(): string
    return HttpService:GenerateGUID(false)
end

function Scheduler:GetThreadPoolStats(): any
    return {
        TotalThreads = totalThreads,
        FreeThreads = #freeThreads,
        ActiveThreads = activeThreads,
        PeakThreads = peakThreads,
    }
end

--[[
    @description Returns a serialization-safe snapshot for sync.
]]
function Scheduler:GetSyncData(): any
    self = ResolveScheduler(self)
    local safeTasks = {}
    for name, t in pairs(self.Tasks) do
        local safe = {}
        for k, v in pairs(t) do
            if type(v) ~= "function" then safe[k] = v end
        end
        safeTasks[name] = safe
    end
    return {
        Tasks = safeTasks,
        Logs = self.Logger and self.Logger:GetHistory() or {},
        Settings = self.Settings,
        History = self.History,
        LastFrameStats = self.LastFrameStats,
    }
end

function Scheduler:CheckAdmin(player: any): boolean
    if RunService:IsStudio() then return true end
    return player.UserId == game.CreatorId
end

function Scheduler:PrunePool()
    if TaskPool.GetCount() > 100 then
        TaskPool.Shrink(20)
    end
end

--============================================================================--
-- Internal Execution
--============================================================================--

function Scheduler:_internalExecute(t: any)
    local thread: thread
    if #freeThreads > 0 then
        thread = table_remove(freeThreads) :: thread
    else
        thread = coroutine.create(yielder)
        coroutine.resume(thread)
        totalThreads += 1
        if totalThreads > peakThreads then peakThreads = totalThreads end
    end
    activeThreads += 1

    local schedulerRef = self
    task.spawn(thread, function()
        local start = os_clock()
        local startMem = collectgarbage("count")
        schedulerRef._running[t.Name] = t

        local ok, err = xpcall(t.Action, ERROR_HANDLER)

        local dur = os_clock() - start
        local endMem = collectgarbage("count")
        local memDelta = math.max(0, endMem - startMem)

        schedulerRef._running[t.Name] = nil

        if schedulerRef.Tasks[t.Name] == t then
            t.RunCount += 1
            t.TotalRunTime += dur
            if dur > t.MaxRunTime then t.MaxRunTime = dur end
            t.TotalMemory = (t.TotalMemory or 0) + memDelta
            if memDelta > (t.MaxMemory or 0) then t.MaxMemory = memDelta end

            if not t.IsRecurringTask then
                schedulerRef:AddToHistory(t, ok and "Completed" or "Failed", dur, not ok and tostring(err) or nil)
                schedulerRef.Tasks[t.Name] = nil
                schedulerRef._taskCount -= 1
                TaskPool.Release(t)
            end
        end
    end, thread)
end

--============================================================================--
-- Step (frame-budgeted execution)
--============================================================================--

function Scheduler:Step(eventName: string?)
    local event = eventName or Enums.SchedulerEvent.Heartbeat
    local heap = self._heaps[event]
    if not heap or #heap == 0 then return end

    local now = os_clock()
    local startTime = now
    local budget = self.Settings.FrameBudget

    -- Collect due tasks
    local dueTasks = {}
    local count = 0

    while #heap > 0 do
        local t = heap[1]

        -- Lazy removal: task was descheduled
        if self.Tasks[t.Name] ~= t then
            self:_heapPop(heap)
            TaskPool.Release(t)
            continue
        end

        if t.NextRun > now then break end

        self:_heapPop(heap)
        count += 1
        dueTasks[count] = t
    end

    -- Execute and reschedule
    for i = 1, count do
        local t = dueTasks[i]
        self:_internalExecute(t)

        if t.IsRecurringTask and self.Tasks[t.Name] == t then
            t.NextRun = GetWeightedTime(self, t.Delay, t.Priority)
            self:_heapPush(heap, t)
        end

        -- Budget check
        if (os_clock() - startTime) >= budget then
            for j = i + 1, count do
                self:_heapPush(heap, dueTasks[j])
            end
            break
        end
    end

    self.LastFrameStats = {
        FrameTime = os_clock() - startTime,
        TaskCount = count,
        Budget = budget,
    }
end

--============================================================================--
-- Min-Heap Operations
--============================================================================--

function Scheduler:_heapPush(heap: { any }, item: any)
    table_insert(heap, item)
    local idx = #heap
    while idx > 1 do
        local parent = math_floor(idx / 2)
        if heap[idx].NextRun < heap[parent].NextRun then
            heap[idx], heap[parent] = heap[parent], heap[idx]
            idx = parent
        else
            break
        end
    end
end

function Scheduler:_heapPop(heap: { any }): any?
    local size = #heap
    if size == 0 then return nil end
    local root = heap[1]

    if size > 1 then
        heap[1] = heap[size]
        heap[size] = nil
        size -= 1
        local idx = 1
        while true do
            local left, right = 2 * idx, 2 * idx + 1
            local smallest = idx
            if left <= size and heap[left].NextRun < heap[smallest].NextRun then smallest = left end
            if right <= size and heap[right].NextRun < heap[smallest].NextRun then smallest = right end
            if smallest == idx then break end
            heap[idx], heap[smallest] = heap[smallest], heap[idx]
            idx = smallest
        end
    else
        heap[1] = nil
    end
    return root
end

--============================================================================--
-- Start (auto-connects to RunService events)
--============================================================================--

function Scheduler:Start()
    if self._running[Enums.SchedulerEvent.Heartbeat] then return end

    local serverEvents = {
        Enums.SchedulerEvent.Heartbeat,
        Enums.SchedulerEvent.Stepped,
        Enums.SchedulerEvent.PreSimulation,
        Enums.SchedulerEvent.PostSimulation,
        Enums.SchedulerEvent.PreAnimation,
    }
    local clientEvents = {
        Enums.SchedulerEvent.RenderStepped,
        Enums.SchedulerEvent.PreRender,
    }

    for _, state in ipairs(serverEvents) do
        self._running[state] = RunService[state]:Connect(function()
            self:Step(state)
        end)
    end

    if RunService:IsClient() then
        for _, state in ipairs(clientEvents) do
            self._running[state] = RunService[state]:Connect(function()
                self:Step(state)
            end)
        end
    end

    if self.Logger then
        self.Logger:Log({ Level = Enums.LogLevel.INFO, Message = "Scheduler started" })
    end
end

return Scheduler
