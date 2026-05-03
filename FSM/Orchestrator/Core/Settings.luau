--!strict
--[=[
    @Name Settings
    @Description Central RBXStateMachine orchestrator configuration table. This module contains
    static runtime knobs for scheduling, logging, persistence, remoting, and service bootstrap.

    Structure:
    - Scheduler: frame-budget and scheduler tuning.
    - Logger: global debug/logging thresholds.
    - DataStore: persistence service configuration shared by persistence layers.
    - FSMSettings: global finite-state-machine debugging defaults.
    - Orchestrator: sanitization and orchestration safeguards.
    - StaticStrings: canonical remote names, task names, and shared error messages.
    - ServiceManager: enablement flag for the ServiceManager bootstrap path.

    Used by:
    - Orchestrator.init during startup and remote/datastore initialization.
    - Logger, NetworkManager, Scheduler, BaseEntity, BaseStateMachine, and PersistenceManager.
    - Tests that validate persistence behavior and settings plumbing.
]=]
return {
--[=[ Scheduler configuration for cooperative task execution. ]=]
Scheduler = {
FrameBudget = 0.015 -- Maximum scheduler time slice per frame in seconds.
},

--[=[ Global logger behavior used by Orchestrator/Core/Logger. ]=]
Logger = {
DebuggingEnabled = true, -- Enables or suppresses all debug/info/warn/error logger output.
MinimumLoggingLevel = 3, -- Numeric logging threshold consumed by Logger (DEBUG=4, INFO=3, WARN=2, ERROR=1).
},

--[=[ Persistence settings consumed by the datastore/persistence pipeline. ]=]
DataStore = {
ResetAccessCountIntervalInSeconds = 60, -- Interval for resetting datastore access counters used by persistence throttling.
DataStoreName = "EntityPersistence", -- Roblox DataStore name that holds serialized persisted entity data.
KeyPrefix = "Entity", -- Prefix applied to datastore keys to avoid collisions across save domains.
PersistenceEnabled = true, -- Master switch for server-side entity persistence.
},

--[=[ Default FSM-level diagnostics. ]=]
FSMSettings = {
Debug = true, -- Enables extra FSM debug behavior/logging where supported.
LogLevel = 1 -- Minimum FSM log level.
},

--[=[ Orchestrator safety and serialization settings. ]=]
Orchestrator = {
MaxSanitizationDepth = 8, -- Maximum recursive depth when sanitizing tables before replication to clients.
},

--[=[ Shared canonical strings used by networking, task scheduling, and error reporting. ]=]
StaticStrings = {
Instance = {
OrchestratorEventName = "OrchestratorEvent", -- RemoteEvent name used for orchestrator fire-and-forget traffic.
OrchestratorFunctionName = "OrchestratorFunction", -- RemoteFunction name used for orchestrator request/response calls.
EntityUpdateEventName = "EntityUpdateEvent", -- RemoteEvent name used for entity replication updates.
EntityCommandEventName = "EntityCommandEvent", -- RemoteEvent name used for entity command dispatch.
ResetDataStoreAccessCountTaskName = "ResetDataStoreAccessCount" -- Scheduler task name for datastore access-count resets.
},
Error = {
RemoteNotFoundErrorMessage = "CreateRemote called without a %s",
FSMAlreadyFoundErrorMessage = "FSM already registered",
UnresolvableConstructorErrorMessage = "%s called with nil/unresolvable %s",
EntityRequiresInstanceErrorMessage = "Entity '%s' requires an 'Instance' in its context.",
AlreadyExistsErrorMessage = "%s '%s' already exists. Returning existing instance.",
InstantializationFailureErrorMessage = "Failed to instantiate %s '%s': %s",
AttachServiceSingletonErrorMessage = "AttachServiceManager can only be called on the client",
ServiceManagerDisabledErrorMessage = "ServiceManager is disabled in settings",
ServiceManagerInitializationFailureErrorMessage = "Failed to initialize ServiceManager: %s",
MissingServiceManagerChildErrorMessage = "Missing child 'ServiceManager' under Orchestrator module",
FailedToCreateErrorMessage = "Failed to create %s '%s'.",
AsyncRequestFailureErrorMessage = "Failed to handle async request '%s': %s",
ServerRequestErrorMessage = "This API is inaccessible on the client.",
ClientRequestErrorMessage = "This API is inaccessible on the server."
},
},

--[=[ ServiceManager bootstrap toggle. ]=]
ServiceManager = {
Enabled = true -- Enables ServiceManager initialization during orchestrator startup.
}
}