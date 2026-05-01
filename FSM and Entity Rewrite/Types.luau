--!strict
--[[
    @module Types
    @author iKrypto
    @version 3.0
    @description Shared type definitions for the entire framework.
    
    Import these types in any module:
        local Types = require(path.to.Types)
        local entity: Types.Entity = ...
]]

local Types = {}

--============================================================================--
-- Logger Types
--============================================================================--

export type LogEntry = {
    Timestamp: number,
    OperationId: string?,
    Level: string,
    Message: string,
    Data: any?,
}

export type LoggerConfig = {
    Name: string?,
}

export type LoggerSettings = {
    DebuggingEnabled: boolean,
    MinimumLoggingLevel: number,
}

export type LogParams = {
    Level: string,
    Message: string,
    OperationId: string?,
    Data: any?,
}

export type Logger = {
    Source: string,
    History: { LogEntry },
    Log: (self: Logger, params: LogParams) -> (),
    SetMinimumLoggingLevel: (self: Logger, level: number) -> (),
    GetHistory: (self: Logger) -> { LogEntry },
}

--============================================================================--
-- Signal Types
--============================================================================--

export type Connection = {
    _handler: (...any) -> (),
    _signal: Signal?,
    Disconnect: (self: Connection) -> (),
}

export type Signal = {
    _handlers: { Connection },
    Connect: (self: Signal, handler: (...any) -> ()) -> Connection,
    Once: (self: Signal, handler: (...any) -> ()) -> Connection,
    Fire: (self: Signal, ...any) -> (),
    Wait: (self: Signal) -> ...any,
    Destroy: (self: Signal) -> (),
}

--============================================================================--
-- ContextObject Types (Common Base)
--============================================================================--

export type PerformanceMetrics = {
    UpdateCount: number,
    TotalUpdateTime: number,
    MaxUpdateTime: number,
    LastUpdateTime: number,
    AvgUpdateTime: number,
    LastMemKB: number?,
    LastMemKBDelta: number?,
    MaxMemKBDelta: number,
    MemSampleCount: number,
    _nextMemSampleAt: number,
    _memSampleInterval: number,
}

export type ContextObjectFields = {
    _id: string,
    _name: string,
    _logger: Logger,
    _cleanupTasks: { any },
    _isDestroyed: boolean,
    Perf: PerformanceMetrics?,
}

--============================================================================--
-- Schema / Entity Types
--============================================================================--

export type PropertyDefinition = {
    Type: string,
    Default: any?,
    Persist: boolean?,
    Replicate: boolean?,
    ReadOnly: boolean?,
    Validator: ((value: any, entity: any) -> (boolean, string?))?,
    Serialize: ((value: any) -> any)?,
    Deserialize: ((value: any) -> any)?,
}

export type EntitySchema = {
    [string]: PropertyDefinition,
}

export type EntityDefinition = {
    Name: string,
    Schema: EntitySchema?,
    DefaultMutable: boolean?,
    Replication: {
        Enabled: boolean?,
        RateLimit: number?,
    }?,
}

export type EntityConstructorParams = {
    Name: string,
    Instance: Instance?,
    OwnerId: string?,
    Context: { [any]: any }?,
    Mutable: boolean?,
}

export type EntityPrivateState = {
    Name: string,
    Instance: Instance?,
    Schema: EntitySchema,
    Pending: { [string]: any },
    Data: { [string]: any },
    Context: { [any]: any },
    OwnerId: string?,
    Mutable: boolean,
    EntityLocked: (string | false),
    IsValid: boolean,
    _cache: { [string]: any },
    _stateUpdatedEvent: Signal,
    _entityDestroyedEvent: Signal,
    _cleanupTasks: { any },
    _logger: Logger,
    Version: number,
    InstanceDestroyedConn: any?,
}

--============================================================================--
-- StateMachine Types
--============================================================================--

export type StateObject = {
    OnEnter: ((fsm: any, ...any) -> ())?,
    OnLeave: ((fsm: any) -> ())?,
    OnHeartbeat: ((fsm: any, dt: number) -> ())?,
    Transitions: {
        {
            Condition: (fsm: any, dt: number) -> boolean,
            TargetState: string,
            Args: { any }?,
        }
    }?,
}

export type FSMConstructorParams = {
    Id: string,
    Name: string?,
    ValidStates: { string }?,
    TerminalStates: { string }?,
    InitialState: string?,
    Context: { [any]: any }?,
    Priority: number?,
    AutoCompleteTerminalStates: boolean?,
    StateTimeout: number?,
}

export type FSMExtendParams = {
    className: string,
    validStates: { string }?,
    terminalStates: { string }?,
    InitialState: string?,
    context: { [any]: any }?,
    Priority: number?,
    AutoCompleteTerminalStates: boolean?,
    StateTimeout: number?,
    -- Aliases for backward compatibility
    ValidStates: { string }?,
    TerminalStates: { string }?,
    initialState: string?,
}

export type SubMachineConfig = {
    Transitions: {
        OnCompleted: string?,
        OnFailed: string?,
        OnCancelled: string?,
    },
    InitialState: string,
    StoreReference: string?,
}

--============================================================================--
-- BehaviorTree Types
--============================================================================--

export type BTStatus = "Success" | "Failure" | "Running"

export type BTContext = { [any]: any }

export type BTNode = {
    Name: string?,
    Execute: (self: BTNode, context: BTContext, dt: number) -> BTStatus,
    Reset: ((self: BTNode) -> ())?,
    OnCancel: ((self: BTNode) -> ())?,
}

export type BTNodeFunction = (context: BTContext, dt: number) -> BTStatus

export type BlackboardValue = {
    Value: any,
    Timestamp: number,
}

export type Blackboard = {
    Get: (self: Blackboard, key: string) -> any?,
    Set: (self: Blackboard, key: string, value: any) -> (),
    Has: (self: Blackboard, key: string) -> boolean,
    Clear: (self: Blackboard) -> (),
    Remove: (self: Blackboard, key: string) -> (),
    GetAll: (self: Blackboard) -> { [string]: any },
}

export type BTConstructorParams = {
    Id: string?,
    Name: string?,
    Root: BTNode,
    Context: BTContext?,
    Priority: number?,
    Blackboard: Blackboard?,
}

--============================================================================--
-- TaskScheduler Types
--============================================================================--

export type ScheduledTask = {
    Name: string,
    Action: (() -> ())?,
    Delay: number,
    IsRecurringTask: boolean,
    Priority: number,
    Event: string,
    NextRun: number,
    RunCount: number,
    TotalRunTime: number,
    MaxRunTime: number,
    TotalMemory: number,
    MaxMemory: number,
    CreationTime: number,
}

export type ScheduleParams = {
    TaskName: string,
    TaskAction: () -> (),
    TaskExecutionDelay: number?,
    IsRecurringTask: boolean?,
    Priority: number?,
    Event: string?,
}

export type FrameStats = {
    FrameTime: number,
    TaskCount: number,
    Budget: number,
}

export type SchedulerSettings = {
    FrameBudget: number,
    PriorityWeight: number,
}

export type ThreadPoolStats = {
    TotalThreads: number,
    FreeThreads: number,
    ActiveThreads: number,
    PeakThreads: number,
}

--============================================================================--
-- Persistence Types
--============================================================================--

export type PersistenceConfig = {
    DataStoreName: string,
    KeyPrefix: string?,
    DataStoreReference: any,
}

export type PersistencePayload = {
    version: number,
    updatedAt: number,
    data: { [string]: any },
    meta: { [string]: any },
}

--============================================================================--
-- Network Types
--============================================================================--

export type InvokeStats = {
    Count: number,
    LastInvoked: number,
}

export type BusStats = {
    Count: number,
    LastFired: number,
}

--============================================================================--
-- Factory Types
--============================================================================--

export type CreateEntityParams = {
    EntityClass: any,
    EntityId: string?,
    Context: { [any]: any }?,
    Persistent: boolean?,
    PersistenceKey: string?,
}

export type CreateStateMachineParams = {
    StateMachineClass: any,
    StateMachineId: string?,
    Context: { [any]: any }?,
}

--============================================================================--
-- Framework Utility Bag (passed to Initialize)
--============================================================================--

export type FrameworkUtil = {
    Settings: { [string]: any },
    Logger: any,
    Signal: any,
    NetworkManager: any?,
    Factory: any?,
}

return Types
