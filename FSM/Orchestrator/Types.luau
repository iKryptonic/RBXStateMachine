export type LogLevel = "INFO" | "WARN" | "ERROR" | "DEBUG"

-- Definition of a property in the schema
export type PropertyDef = {
	Type: string, -- The expected Luau type (e.g., "number", "string", "Instance") or ClassName
	Description: string?, -- Documentation for what this property represents
	Replicate: boolean?, -- Whether to replicate to clients
	Persist: boolean? -- Whether to save to DataStore
}

-- Definition of a behavior tree status
export type BehaviorTreeStatus = "Success" | "Failure" | "Running"

-- Definition of a connection
type Connection = {
	Disconnect: (self: Connection) -> (),
	_handler: (...any) -> (),
	_signal: any,
}

-- Definition of a signal
export type Signal = {
	Connect: (self: any, handler: (...any) -> ()) -> Connection,
	Once: (self: any, handler: (...any) -> ()) -> Connection,
	Fire: (self: any, ...any) -> (),
	Wait: (self: any) -> ...any,
	Destroy: (self: any) -> (),
}

-- The BaseEntity Class Interface
export type BaseEntity = {
	-- Properties
	Name: string, -- The name of the entity
	Instance: Instance, -- The underlying Roblox Instance being managed
	IsValid: boolean, -- Whether the entity is currently valid (not destroyed)
	OwnerId: string?, -- The ID of the system that owns/created this entity
	
	-- Signals
	StateUpdated: RBXScriptSignal, -- Fired when properties are successfully committed (returns changes table)
	Destroyed: RBXScriptSignal, -- Fired when the entity is destroyed

	-- Methods

	--[[
		Logs a message associated with this entity.
		@param params Table containing Level and Message.
	]]
	Log: (self: BaseEntity, params: { Level: LogLevel, Message: string }) -> (),

	--[[
		Defines the schema for valid properties.
		@param schema A dictionary mapping property names to PropertyDef definitions.
	]]
	DefineSchema: (self: BaseEntity, schema: { [string]: PropertyDef }) -> (),

	--[[
		Sets a value in the internal Context (non-physical data).
		@param key The key to store.
		@param value The value to store.
	]]
	SetContext: (self: BaseEntity, key: any, value: any) -> (),

	--[[
		Registers an object to be cleaned up when the entity is destroyed.
		@param object An Instance, Connection, function, or object with a Destroy method.
		@return The object passed in.
	]]
	Manage: (self: BaseEntity, object: any) -> any,

	--[[
		Commits pending property changes to the entity.
		Triggers ApplyChanges and fires StateUpdated.
		@param lockingCallerId Optional ID if the entity is locked.
		@return True if the update was successful.
	]]
	UpdateEntity: (self: BaseEntity, lockingCallerId: string?) -> boolean,

	--[[
		Abstract method to apply changes to the physical instance.
		Override this in subclasses.
		@param changes A table of key-value pairs that have changed.
	]]
	ApplyChanges: (self: BaseEntity, changes: { [string]: any }) -> (),

	--[[
		Returns the current schema definition.
		@return The schema table.
	]]
	GetValidProperties: (self: BaseEntity) -> { [string]: PropertyDef },

	--[[
		Attempts to lock the entity to a specific owner.
		@param callerId The ID of the system requesting the lock.
		@return True if the lock was acquired.
	]]
	AcquireLock: (self: BaseEntity, callerId: string) -> boolean,

	--[[
		Releases a lock if the callerId matches the current owner.
		@param callerId The ID of the system releasing the lock.
		@return True if the lock was released.
	]]
	ReleaseLock: (self: BaseEntity, callerId: string) -> boolean,

	--[[
		Destroys the entity proxy and cleans up resources.
		Called automatically if the Instance is removed.
	]]
	Destroy: (self: BaseEntity) -> ()
}


-- Definition of a state transition
export type Transition = {
	TargetState: string, -- The name of the state to transition to
	Condition: (any, number) -> boolean -- A function that returns true if the transition should occur
}

-- Definition of an object-based state
export type StateObject = {
	Machine: BaseStateMachine?, -- Reference to a sub-machine if one exists
	OnEnter: (any, ...any) -> (), -- Called when the state is entered
	OnHeartbeat: ((any, number) -> ())?, -- Called every frame while in this state
	OnLeave: ((any) -> ())?, -- Called when the state is exited
	Transitions: {Transition}?, -- List of automatic transitions
}

-- Configuration for a hierarchical sub-machine
export type SubStateConfig = {
	InitialState: string, -- The starting state of the sub-machine
	Transitions: {
		OnCompleted: string, -- State to go to if sub-machine completes
		OnFailed: string, -- State to go to if sub-machine fails
		OnCancelled: string? -- State to go to if sub-machine is cancelled
	},
	StoreReference: string? -- Optional Context key to store the sub-machine instance
}

-- A state can be a function (closure) or a StateObject
export type State = ((any, ...any) -> (() -> ())?) | StateObject

-- Objects that can be cleaned up
export type Disposable = Instance | RBXScriptConnection | { Destroy: (any) -> () } | () -> ()

-- The BaseStateMachine Class Interface
export type BaseStateMachine = {
	-- Properties
	Id: string, -- Unique identifier for this machine instance
	Name: string, -- Display name of the machine class
	Context: { [any]: any }, -- Shared data table accessible by all states
	IsActive: boolean, -- True if the machine is currently running
	State: string?, -- The name of the current state
	StateDuration: number, -- Time in seconds spent in the current state
	TotalDuration: number, -- Total time the machine has been running
	WaitSpan: number, -- Delay in seconds before the next transition is processed
	TransitionCount: number, -- Number of transitions that have occurred
	Priority: number, -- Update frequency (1 = every frame, 2 = every other frame, etc.)
	
	-- Signals
	Completed: RBXScriptSignal, -- Fired when Finish() is called
	Failed: RBXScriptSignal, -- Fired when Fail() is called
	Cancelled: RBXScriptSignal, -- Fired when Cancel() is called
	StateChanged: RBXScriptSignal, -- Fired when the state changes (newState, oldState)

	-- Methods

	--[[
		Starts the StateMachine.
		@param params Table containing:
			- State: The name of the initial state to enter.
			- Args: Optional array of arguments to pass to the initial state's OnEnter.
	]]
	Start: (self: BaseStateMachine, params: { State: string, Args: {any}? }) -> (),

	--[[
		Transitions the machine to a new state.
		@param params Table containing:
			- Name: The name of the target state.
			- Args: Optional array of arguments to pass to the new state's OnEnter.
	]]
	ChangeState: (self: BaseStateMachine, params: { Name: string, Args: {any}? }) -> (),

	--[[
		Stops the machine successfully. Fires the Completed signal.
	]]
	Finish: (self: BaseStateMachine) -> (),

	--[[
		Stops the machine with a failure. Fires the Failed signal.
		@param reason A string describing why the machine failed.
	]]
	Fail: (self: BaseStateMachine, reason: string) -> (),

	--[[
		Stops the machine immediately. Fires the Cancelled signal.
	]]
	Cancel: (self: BaseStateMachine) -> (),

	--[[
		Permanently destroys the machine and cleans up all managed resources.
	]]
	Destroy: (self: BaseStateMachine) -> (),

	--[[
		Registers an object to be cleaned up when the machine is destroyed.
		@param object An Instance, Connection, function, or object with a Destroy method.
		@return The object passed in.
	]]
	Manage: (self: BaseStateMachine, object: Disposable) -> Disposable,

	--[[
		Registers a nested StateMachine inside a state.
		@param name The name of the state that will run this sub-machine.
		@param subMachineClass The class definition of the sub-machine.
		@param config Configuration for transitions based on the sub-machine's result.
	]]
	AddSubMachine: (self: BaseStateMachine, name: string, subMachineClass: any, config: SubStateConfig) -> (),

	--[[
		Registers a logic state.
		@param name The unique name of the state.
		@param state The function or StateObject defining the behavior.
		@param validOutcomes Optional list of allowed states to transition to from here.
	]]
	AddState: (self: BaseStateMachine, name: string, state: State, validOutcomes: {string}?) -> (),

	--[[
		Logs a message to the internal history.
		@param params Table containing Level (INFO/WARN/ERROR) and Message.
	]]
	Log: (self: BaseStateMachine, params: { Level: LogLevel, Message: string, Data: any? }) -> (),

	--[[
		Virtual method called during cleanup. Override this in subclasses to clean up custom resources.
	]]
	OnCleanup: (self: BaseStateMachine) -> (),
	
	--[[
		Virtual method called during initialization. Override this to call AddState/AddSubMachine.
	]]
	RegisterStates: (self: BaseStateMachine) -> (),
}

export type RetryConfig = {
	enabled: boolean?,
	retries: number?,
	baseDelay: number?,
	jitter: number?,
}

export type DataStore = {
	-- Properties
	CachingTime: number,
	RetryConfig: RetryConfig,

	-- Configuration Methods
	SetRetryConfig: (self: DataStore, config: RetryConfig?) -> (),
	EnableRetry: (self: DataStore, enabled: boolean) -> (),
	SetCachingTime: (self: DataStore, TimeInSeconds: number) -> (),
	
	-- Metadata
	GetDBName: (self: DataStore) -> string,

	-- Data Methods
	GetAsync: (self: DataStore, Key: string) -> (boolean, any, string?),
	SetAsync: (self: DataStore, Key: string, value: any) -> (boolean, nil, string?),
	UpdateAsync: (self: DataStore, Key: string, transformFunction: (any) -> any) -> (boolean, any, string?),
	IncrementAsync: (self: DataStore, Key: string, delta: number) -> (boolean, number?, string?),
	RemoveAsync: (self: DataStore, Key: string) -> (boolean, any, string?),
	
	-- OrderedDataStore Methods (Only available if orderedBool was true)
	GetSortedAsync: ((self: DataStore, ascending: boolean, pagesize: number, minValue: number?, maxValue: number?) -> (boolean, any, string?))?,
	
	OnUpdate: any,
}

export type DataStoreHandler = {
	ResetAccessCount: () -> (),
	get: (databaseName: string, scope: string?, orderedBool: boolean?) -> DataStore
}

--[[
	@Interface EntityFactory
	@Description The static singleton used to manage Entity classes.
]]
export type EntityFactory = {
	--[[
		@Method Register
		@Description Registers a new Entity class definition under a specific name.
		This method looks for a ModuleScript in ReplicatedStorage.Entities with the matching name,
		and extends the provided class definition using BaseEntity.Extend.
		
		@Param entityName string -- The unique name of the Entity (must match a ModuleScript in ReplicatedStorage.Entities).
		@Param entityClassDefinition any -- The table definition containing the Entity's schema and logic.
		@Return void
	]]
	Register: (entityName: string, entityClassDefinition: any) -> (),

	--[[
		@Method get
		@Description Retrieves a registered Entity class by its name.
		Throws an error if the Entity has not been registered.
		
		@Param entityName string -- The name of the Entity to retrieve.
		@Param params { [any]: any }? -- (Optional) Reserved parameter for future factory overrides or configuration.
		@Return any -- The Entity class (subclass of BaseEntity).
	]]
	get: (entityName: string, params: { [any]: any }?) -> any
}


--[[
	@Type LogEntry
	@Description Represents a single record in the logger's history.
	@Field Timestamp number -- The os.time() when the log occurred.
	@Field OperationId string? -- Optional unique identifier for the operation context (e.g., a RequestId).
	@Field Level LogLevel -- The severity level of the log.
	@Field Message string -- The main log content.
	@Field Data any? -- Optional metadata or data structure attached to the log.
]]
export type LogEntry = {
	Timestamp: number,
	OperationId: string?,
	Level: LogLevel,
	Message: string,
	Data: any?
}

--[[
	@Interface LoggerInstance
	@Description Represents an instantiated Logger object.
]]
export type LoggerInstance = {
	--[[
		@Property Source
		@Description The name of the source (script or module) this logger is attached to.
	]]
	Source: string,

	--[[
		@Property Enabled
		@Description Controls whether the logger outputs to the console. Defaults to true.
	]]
	Enabled: boolean,

	--[[
		@Property History
		@Description Internal storage of recent log entries.
	]]
	History: {LogEntry},

	--[[
		@Method Log
		@Description Logs a message with a specific severity level, optional operation ID, and attached data.
		@Param params {
			Level: LogLevel -- The severity ("INFO", "WARN", "ERROR", "DEBUG").
			Message: string -- The text to log.
			OperationId: string? -- (Optional) A correlation ID to trace logs across systems.
			Data: any? -- (Optional) A table or value to store with the log entry for debugging.
		}
		@Return void
	]]
	Log: (self: LoggerInstance, params: { Level: LogLevel, Message: string, OperationId: string?, Data: any? }) -> (),

	--[[
		@Method GetHistory
		@Description Retrieves the list of recent log entries stored in memory.
		@Return {LogEntry} -- Array of LogEntry objects.
	]]
	GetHistory: (self: LoggerInstance) -> {LogEntry}
}

--[[
	@Interface LoggerStatic
	@Description Static interface for the Logger module constructor.
]]
export type LoggerStatic = {
	--[[
		@Method new
		@Description Creates a new Logger instance.
		@Param params {
			Name: string? -- (Optional) The name of the logger source. If omitted, attempts to detect the calling script's name.
		}
		@Return LoggerInstance -- The initialized Logger.
	]]
	new: (params: { Name: string? }) -> LoggerInstance
}

export type Orchestrator = {
	-- Properties
	Logger: any, -- The internal logger instance
	History: {any}, -- History of StateMachine lifecycle events

	-- Methods

	--[[
		Loads Entity and StateMachine classes into shared globals and initializes shared.FSM.
	]]
	RegisterComponents: (self: Orchestrator) -> (),

	--[[
		Creates (or retrieves) a unique Entity instance by ID.
		@param params Table containing EntityClass, EntityId, and optional Context.
		@return The created or existing Entity instance (nil on failure).
	]]
	CreateEntity: (params: { EntityClass: any, EntityId: string, Context: {any}?, Persistent: boolean?, PersistenceKey: string? }) -> any?,

	--[[
		Creates (or retrieves) a unique StateMachine instance by ID.
		@param params Table containing StateMachineClass, StateMachineId, and optional Context.
		@return The created or existing StateMachine instance (nil on failure).
	]]
	CreateStateMachine: (params: { StateMachineClass: any, StateMachineId: string, Context: {any}? }) -> any?,

	--[[
		Retries a stateMachine by ID, preserving its Context.
		@param stateMachineId The ID of the StateMachine to retry.
	]]
	RetryStateMachine: (stateMachineId: string) -> (),

	--[[
		Retrieves a StateMachine by its ID.
		@param stateMachineId The ID of the StateMachine.
		@return The StateMachine instance or nil.
	]]
	GetStateMachine: (stateMachineId: string) -> any?,

	--[[
		Retrieves an Entity by its ID.
		@param entityId The ID of the Entity.
		@return The Entity instance or nil.
	]]
	GetEntity: (entityId: string) -> any?,

	--[[
		Cancels a specific StateMachine by ID.
		@param stateMachineId The ID of the StateMachine.
		@return True if found and cancelled.
	]]
	CancelStateMachine: (stateMachineId: string) -> boolean,

	--[[
		Deletes (destroys) a specific Entity by ID.
		@param entityId The ID of the Entity.
	]]
	DeleteEntity: (entityId: string) -> (),

	--[[
		Deletes (destroys) all active Entities.
	]]
	DeleteAllEntities: () -> (),

	--[[
		Cancels all active StateMachines.
	]]
	CancelAll: () -> (),

	--[[
		Returns the current active Entities map.
		@return Dictionary of EntityId -> EntityInstance.
	]]
	GetEntities: () -> { [string]: any },

	--[[
		Returns the current active StateMachines map.
		@return Dictionary of StateMachineId -> StateMachineInstance.
	]]
	GetStateMachines: () -> { [string]: any },

	--[[
		Initializes client-side listeners for Entity state updates.
		(Client Only)
	]]
	InitClientListeners: () -> (),

	--[[
		Starts the ServiceManager remote API.
		(Server Only)
	]]
	StartServiceManagerAPI: () -> (),

	--[[
		Handles replication of Entity property changes to clients.
		(Server Only)
		@param entityId The ID of the entity.
		@param changes The table of changed properties.
		@param schema The entity's schema definition.
	]]
	HandleReplication: (entityId: string, changes: {[string]: any}, schema: {[string]: any}) -> (),

	--[[
		Registers a new local event bus by name.
		@param name The name of the event bus.
		@return The Signal object for the event bus.
	]]
	RegisterEventBus: (name: string) -> any,

	--[[
		Retrieves an existing local event bus by name.
		@param name The name of the event bus.
		@return The Signal object or nil if not registered.
	]]
	GetEventBus: (name: string) -> any?,

	--[[
		Fires a local event bus.
		@param name The name of the event bus.
		@param ... Arguments to pass to the event.
	]]
	FireEventBus: (name: string, ...any) -> (),

	--[[
		Yields until an event bus with the given name is registered.
		@param name The name of the event bus.
		@param timeout Optional timeout in seconds.
		@return The Signal object or nil if timed out.
	]]
	AwaitEventBus: (name: string, timeout: number?) -> any?,
}

--[[
	@Interface StateMachineInstance
	@Description Represents an instantiated StateMachine object (runtime).
]]
export type StateMachineInstance = {
	Id: string,
	Name: string,
	State: string,
	Context: {[any]: any},
	WaitSpan: number,
	TransitionCount: number,

	Start: (self: StateMachineInstance, params: { State: string, Args: {any}? }) -> (),
	ChangeState: (self: StateMachineInstance, params: { Name: string, Args: {any}? }) -> (),
	AddState: (self: StateMachineInstance, name: string, state: any, validOutcomes: {string}?) -> (),
	AddSubMachine: (self: StateMachineInstance, name: string, subMachineClass: any, config: any) -> (),
	Manage: (self: StateMachineInstance, object: Instance | RBXScriptConnection | () -> () | {Destroy: (self: any) -> ()}) -> (),
	
	Finish: (self: StateMachineInstance) -> (),
	Fail: (self: StateMachineInstance, reason: string) -> (),
	Cancel: (self: StateMachineInstance) -> (),
	Destroy: (self: StateMachineInstance) -> (),
}

--[[
	@Interface StateMachineClass
	@Description Represents the static class definition of a StateMachine.
]]
export type StateMachineClass = {
	Extend: (definition: {[string]: any}) -> StateMachineClass,
	new: (params: {[string]: any}) -> StateMachineInstance,
	[any]: any
}

--[[
	@Interface StateMachineFactory
	@Description The static singleton used to manage StateMachine classes.
]]
export type StateMachineFactory = {
	--[[
		@Method Register
		@Description Registers a new StateMachine class definition under a specific name.
		This method looks for a ModuleScript in ReplicatedStorage.StateMachines with the matching name,
		and extends the provided class definition using BaseStateMachine.Extend.
		
		@Param stateMachineName string -- The unique name of the StateMachine (must match a ModuleScript in ReplicatedStorage.StateMachines).
		@Param class StateMachineClass -- The table definition containing the StateMachine's logic, states, and properties.
		@Return void
	]]
	Register: (stateMachineName: string, class: StateMachineClass) -> (),

	--[[
		@Method get
		@Description Retrieves a registered StateMachine class by its name.
		Throws an error if the StateMachine has not been registered.
		
		@Param stateMachineName string -- The name of the StateMachine to retrieve.
		@Return StateMachineClass -- The StateMachine class (subclass of BaseStateMachine).
	]]
	get: (stateMachineName: string) -> StateMachineClass
}

-- Definition of a scheduled task
export type Task = {
	Name: string, -- Unique name of the task
	Action: () -> (), -- The function to execute
	NextRun: number, -- Timestamp for the next execution
	Delay: number, -- Delay between executions (for recurring tasks)
	IsRecurringTask: boolean, -- True if it repeats
	Priority: number, -- Higher numbers run earlier in the frame
	Event: string, -- The RunService event name (e.g., "Heartbeat")
	
	-- Performance Stats
	RunCount: number,
	TotalRunTime: number,
	MaxRunTime: number,
	CreationTime: number,
	Reset: () -> (), -- Resets stats
}

-- Parameters for scheduling a task
export type ScheduleTaskParams = {
	TaskName: string, -- Unique name
	TaskAction: () -> (), -- Function to run
	TaskExecutionDelay: number?, -- Initial delay in seconds
	IsRecurringTask: boolean?, -- Should it repeat?
	Priority: number?, -- Execution priority (default 1)
	Event: string? -- RunService event (default "Heartbeat")
}

-- The Scheduler Class Interface
export type Scheduler = {
	-- Properties
	Settings: any, -- Configuration table
	History: {any}, -- List of recent execution history
	LastFrameStats: { FrameTime: number, TaskCount: number, Budget: number }, -- Stats from the last Step

	-- Methods

	--[[
		Initializes the scheduler with optional settings.
		@param settings Optional configuration table.
		@return The scheduler instance.
	]]
	Initialize: (self: Scheduler, settings: any?) -> Scheduler,

	--[[
		Clears all tasks, history, and statistics.
	]]
	Clear: (self: Scheduler) -> (),

	--[[
		Schedules a new task.
		@param params Configuration for the task.
		@return The created Task object or nil if invalid.
	]]
	Schedule: (self: Scheduler, params: ScheduleTaskParams) -> Task?,

	--[[
		Cancels a task by name.
		@param name The name of the task to remove.
	]]
	Deschedule: (self: Scheduler, name: string) -> (),

	--[[
		Retrieves a task object by name.
		@param name The task name.
		@return The Task object or nil.
	]]
	GetTask: (self: Scheduler, name: string) -> Task?,

	--[[
		Returns the total number of scheduled tasks.
		@return Count of tasks.
	]]
	GetTaskCount: (self: Scheduler) -> number,

	--[[
		Manually executes a task immediately, bypassing the schedule.
		@param taskOrName The Task object or its name.
	]]
	ExecuteTask: (self: Scheduler, taskOrName: string | Task) -> (),

	--[[
		Returns a serializable snapshot of the scheduler state for debugging/sync.
		@return Table containing Tasks, Logs, Settings, History, etc.
	]]
	GetSyncData: (self: Scheduler) -> any,

	--[[
		(Server Only) Sets up the RemoteFunction for client-side admin access.
	]]
	ExposeAPI: (self: Scheduler) -> (),

	--[[
		Resets the performance statistics for a specific task.
		@param name The task name.
	]]
	ResetTask: (self: Scheduler, name: string) -> (),

	--[[
		Generates a unique GUID string.
		@return A unique string ID.
	]]
	GenerateKey: (self: Scheduler) -> string,

	--[[
		Connects the scheduler to RunService events (Heartbeat, etc.).
		Must be called to start processing tasks.
	]]
	Start: (self: Scheduler) -> ()
}

export type PersistenceConfig = {
	DataStoreName: string,
	Scope: string?,
	KeyPrefix: string?,
	DataStoreHandler: any,
	EnableRetry: boolean?,
	RetryConfig: any?,
}

export type EntityPersistence = {
	Save: (self: EntityPersistence, entity: any, key: string, metadata: { [string]: any }?) -> (boolean, string?),
	Load: (self: EntityPersistence, entity: any, key: string) -> (boolean, { [string]: any }?, string?),
	Delete: (self: EntityPersistence, key: string) -> (boolean, string?),
	Update: (self: EntityPersistence, key: string, mutateFn: (data: { [string]: any }) -> { [string]: any }) -> (boolean, string?),
}

return {}