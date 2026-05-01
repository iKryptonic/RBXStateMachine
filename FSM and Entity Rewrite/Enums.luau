--!strict
--[[
    @module Enums
    @author iKrypto
    @version 3.0
    @description Frozen enum tables for the framework.
    
    All enums are table.freeze'd to prevent accidental mutation.
    Usage:
        local Enums = require(path.to.Enums)
        local level = Enums.LogLevel.INFO
]]

local Enums = {}

--- Log severity levels with numeric weights for filtering.
--- Higher Weight = more verbose (DEBUG is most verbose, ERROR is least).
Enums.LogLevel = table.freeze({
    ERROR = "ERROR",
    WARN  = "WARN",
    INFO  = "INFO",
    DEBUG = "DEBUG",
})

--- Numeric weights for log level filtering.
--- A MinimumLoggingLevel of N means: show levels with Weight <= N.
Enums.LogLevelWeight = table.freeze({
    ERROR = 1,
    WARN  = 2,
    INFO  = 3,
    DEBUG = 4,
})

--- Behavior tree node execution status.
Enums.BTStatus = table.freeze({
    Success = "Success",
    Failure = "Failure",
    Running = "Running",
})

--- State machine lifecycle status.
Enums.FSMStatus = table.freeze({
    Idle      = "Idle",
    Active    = "Active",
    Completed = "Completed",
    Failed    = "Failed",
    Cancelled = "Cancelled",
})

--- Update priority levels (frame skip intervals).
--- Lower number = higher priority (runs more often).
Enums.Priority = table.freeze({
    Render     = 1,   -- Every frame
    High       = 2,   -- Every 2 frames
    Medium     = 5,   -- Every 5 frames
    Low        = 10,  -- Every 10 frames
    Background = 30,  -- Every 30 frames (~0.5s at 60fps)
})

--- Entity mutability modes.
Enums.Mutability = table.freeze({
    Immutable = "Immutable",
    Mutable   = "Mutable",
})

--- Cleanup task types recognized by ContextObject._executeCleanupTasks.
Enums.CleanupType = table.freeze({
    Instance   = "Instance",
    Connection = "RBXScriptConnection",
    Function   = "Function",
    Destroyable = "Destroyable",
})

--- RunService event names used by the TaskScheduler.
Enums.SchedulerEvent = table.freeze({
    Heartbeat      = "Heartbeat",
    Stepped        = "Stepped",
    PreSimulation  = "PreSimulation",
    PostSimulation = "PostSimulation",
    PreAnimation   = "PreAnimation",
    RenderStepped  = "RenderStepped",
    PreRender      = "PreRender",
})

--- Persistence operation results.
Enums.PersistenceResult = table.freeze({
    Success       = "Success",
    SerializeFail = "SerializeFail",
    DecodeFail    = "DecodeFail",
    DataStoreFail = "DataStoreFail",
    NotFound      = "NotFound",
    MissingSerialization = "MissingSerialization",
})

return table.freeze(Enums)
