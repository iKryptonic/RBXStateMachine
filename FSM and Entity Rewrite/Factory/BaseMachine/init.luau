--!strict
--[[
    @module BaseMachine
    @author iKrypto
    @version 3.0
    @description Common base object providing shared lifecycle methods for all
    framework objects (entities, state machines, behavior trees, etc.).
    
    Provides:
        - Managed cleanup task tracking (Manage/ExecuteCleanupTasks)
        - Structured logging (Log)
        - Performance metrics initialization and sampling
        - Destruction lifecycle with guard against double-destroy
    
    Subclasses should call BaseMachine.init(self, params) in their constructor
    to wire up the shared fields, then override OnCleanup() for custom teardown.
    
    Usage:
        local BaseMachine = require(path.to.BaseMachine)
        
        local MyClass = {}
        MyClass.__index = MyClass
        
        function MyClass.new(name)
            local self = setmetatable({}, MyClass)
            BaseMachine.init(self, { Id = "abc", Name = name })
            return self
        end
        
        -- Inherit shared methods
        setmetatable(MyClass, { __index = BaseMachine })
]]

local Enums = require(script.Parent.Enums)

local Logger, Signal
local Initialized = false

local BaseMachine = {}
BaseMachine.__index = BaseMachine

--============================================================================--
-- Module Initialization
--============================================================================--

--[[
    @description Initializes the BaseMachine module with Logger and Signal references.
    Must be called once before any BaseMachine instances are created.
    
    @param Util FrameworkUtil
]]
function BaseMachine.Initialize(Util: any)
    if Initialized then return end
    Initialized = true
    Logger = Util.Logger
    Signal = Util.Signal
end

--============================================================================--
-- Instance Initialization
--============================================================================--

--[[
    @description Initializes shared fields on an instance table.
    Call this from your constructor instead of using setmetatable inheritance.
    
    @param self any -- The instance table to initialize
    @param params { Id: string, Name: string? }
]]
function BaseMachine.init(self: any, params: { Id: string, Name: string? })
    assert(Initialized, "BaseMachine not initialized. Call BaseMachine.Initialize(Util) first.")
    assert(params.Id, "BaseMachine.init requires an Id")

    self._contextId = params.Id
    self._contextName = params.Name or "BaseMachine"
    self._logger = Logger.new({ Name = self._contextName })
    self._cleanupTasks = {} :: { any }
    self._isDestroyed = false
    self.Perf = nil :: any  -- Lazily initialized by InitPerf
end

--============================================================================--
-- Cleanup Management
--============================================================================--

--[[
    @description Registers a disposable object for automatic cleanup on destroy.
    Accepted types:
        - Instance (calls :Destroy())
        - RBXScriptConnection (calls :Disconnect())
        - function (calls fn(self))
        - table with .Destroy method (calls :Destroy())
    
    @param object any -- The disposable resource
    @return any -- Returns the same object for inline chaining
]]
function BaseMachine:Manage(object: any): any
    if self._isDestroyed then
        self:Log({
            Level = Enums.LogLevel.WARN,
            Message = "Manage() called on destroyed object; resource will not be tracked.",
        })
        return object
    end
    table.insert(self._cleanupTasks, object)
    return object
end

--[[
    @description Executes all registered cleanup tasks in reverse order (LIFO).
    Each task is pcall-wrapped to prevent one failure from blocking others.
    The cleanup list is cleared after execution.
    
    @param caller any? -- Optional reference to self for function-type tasks
]]
function BaseMachine:ExecuteCleanupTasks(caller: any?)
    local tasks = self._cleanupTasks
    if not tasks then return end

    for i = #tasks, 1, -1 do
        local cleanupTask = tasks[i]
        local success, err = pcall(function()
            if typeof(cleanupTask) == "Instance" then
                cleanupTask:Destroy()
            elseif typeof(cleanupTask) == "RBXScriptConnection" then
                cleanupTask:Disconnect()
            elseif type(cleanupTask) == "function" then
                cleanupTask(caller or self)
            elseif type(cleanupTask) == "table" and type(cleanupTask.Destroy) == "function" then
                cleanupTask:Destroy()
            end
        end)
        if not success then
            self:Log({
                Level = Enums.LogLevel.ERROR,
                Message = string.format("Error in cleanup task [%d]: %s", i, tostring(err)),
            })
        end
    end
    table.clear(tasks)
end

--============================================================================--
-- Logging
--============================================================================--

--[[
    @description Logs a message through this object's Logger instance.
    Falls back to print() if the logger is not available.
    
    @param params { Level: string, Message: string, OperationId: string?, Data: any? }
]]
function BaseMachine:Log(params: { Level: string, Message: string, OperationId: string?, Data: any? })
    if self._logger then
        self._logger:Log({
            Level = params.Level,
            Message = params.Message,
            OperationId = params.OperationId or self._contextId,
            Data = params.Data,
        })
    else
        print(string.format("[%s] %s", params.Level, params.Message))
    end
end

--============================================================================--
-- Performance Metrics
--============================================================================--

--[[
    @description Lazily initializes performance tracking metrics on this instance.
    Safe to call multiple times; only initializes once.
]]
function BaseMachine:InitPerf()
    if self.Perf ~= nil then return end
    self.Perf = {
        UpdateCount = 0,
        TotalUpdateTime = 0,
        MaxUpdateTime = 0,
        LastUpdateTime = 0,
        AvgUpdateTime = 0,
        LastMemKB = nil :: number?,
        LastMemKBDelta = nil :: number?,
        MaxMemKBDelta = 0,
        MemSampleCount = 0,
        _nextMemSampleAt = 0,
        _memSampleInterval = 1.0, -- Sample memory every 1 second
    }
end

--[[
    @description Records a performance sample for one update cycle.
    Tracks timing every call but only samples memory at the configured interval.
    
    @param startTime number -- os.clock() at the start of the update
    @param startMem number? -- collectgarbage("count") at start (nil to skip memory)
]]
function BaseMachine:RecordPerf(startTime: number, startMem: number?)
    local perf = self.Perf
    if not perf then return end

    local elapsed = os.clock() - startTime
    perf.UpdateCount += 1
    perf.LastUpdateTime = elapsed
    perf.TotalUpdateTime += elapsed
    perf.AvgUpdateTime = perf.TotalUpdateTime / perf.UpdateCount
    if elapsed > perf.MaxUpdateTime then
        perf.MaxUpdateTime = elapsed
    end

    -- Memory sampling (only if startMem was provided)
    if startMem then
        local endMem = gcinfo()
        perf.LastMemKB = endMem
        local delta = endMem - startMem
        perf.LastMemKBDelta = delta
        perf.MemSampleCount += 1
        if math.abs(delta) > perf.MaxMemKBDelta then
            perf.MaxMemKBDelta = math.abs(delta)
        end
    end
end

--[[
    @description Checks whether a memory sample should be taken this frame.
    Returns the current memory if yes, nil if no.
    
    @return number? -- collectgarbage("count") or nil
]]
function BaseMachine:ShouldSampleMemory(): number?
    local perf = self.Perf
    if not perf then return nil end

    local now = os.clock()
    if now >= perf._nextMemSampleAt then
        perf._nextMemSampleAt = now + perf._memSampleInterval
        return gcinfo()
    end
    return nil
end

--============================================================================--
-- Destruction
--============================================================================--

--[[
    @description Returns true if this object has been destroyed.
    @return boolean
]]
function BaseMachine:IsDestroyed(): boolean
    return self._isDestroyed
end

--[[
    @description Virtual cleanup hook. Override in subclasses for custom teardown.
    Called automatically during Destroy() before cleanup tasks execute.
]]
function BaseMachine:OnCleanup()
    -- Override in subclasses
end

--[[
    @description Destroys this object: calls OnCleanup, executes all managed
    cleanup tasks, and marks the object as destroyed.
    Safe to call multiple times (no-op after first call).
]]
function BaseMachine:Destroy()
    if self._isDestroyed then return end

    self:Log({
        Level = Enums.LogLevel.DEBUG,
        Message = string.format("Destroying %s", self._contextName or "BaseMachine"),
    })

    -- Subclass cleanup hook
    local success, err = pcall(self.OnCleanup, self)
    if not success then
        self:Log({
            Level = Enums.LogLevel.ERROR,
            Message = string.format("Error in OnCleanup: %s", tostring(err)),
        })
    end

    -- Execute managed cleanup tasks
    self:ExecuteCleanupTasks(self)

    self._isDestroyed = true
end

return BaseMachine
