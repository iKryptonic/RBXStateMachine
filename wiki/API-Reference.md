# API Reference (Cheatsheet)

This page is derived from the in-repo cheatsheet and is intended to stay close to the actual code.

## FSM API Reference (Cheatsheet)

This is a concise technical reference for the **FiniteStateMachine** core components.

It’s designed for both:

- **Beginners** who want a “what do I call, in what order?” walkthrough.
- **Intermediate/advanced** users who want an accurate method/signature reference that matches the code.

This project is built around a **Factory + Registry** workflow:

- Definitions live in `ReplicatedStorage/Entity/EntityRegistry` and `ReplicatedStorage/StateMachine/StateMachineRegistry`.
- `Orchestrator:RegisterComponents()` compiles those definitions into classes and exposes them as `shared.Entity.*` and `shared.StateMachine.*`.
- You then (optionally) require “implementation modules” to attach methods like `ApplyChanges()` and `RegisterStates()`.

> [!TIP]
> Use the implementation modules to add behavior that only runs after the classes have been compiled by the Factory.

---

## ✅ Registration Guide (Quick)

This system has two layers:

- **Definitions** (registry entries / class templates) that describe *what* entities/state machines exist and what data they hold.
- **Runtime instances** created by the Orchestrator that hold *live state* and drive behavior.

If you’re building a typical Roblox game, you generally:

1) Define schema + valid states in registries, 2) call `Orchestrator:RegisterComponents()` on startup, 3) require your implementation modules, 4) create entities/state machines on the **server**, and let replication keep clients up to date.

### A) Registry-based (recommended)

Use this when you want a consistent, data-driven way to define Entities and StateMachines. Registries also make it easy to auto-load “implementation modules” that attach behavior after compilation.

**Entity registry** (`ReplicatedStorage/Entity/EntityRegistry`):

```lua
-- This registry entry defines an Entity "class template".
-- Orchestrator:RegisterComponents() compiles this into shared.Entity.DoorEntity.
return {
    DoorEntity = {
        Name = "DoorEntity",
        Schema = {
            -- Schema keys are the authoritative data fields for the entity.
            -- Replicate=true: server will sync this field to clients.
            -- Persist=true: EntityPersistence will save/load this field.
            IsOpen = { Type = "boolean", Replicate = true, Persist = true },

            -- Replicate only (will not be saved).
            Locked = { Type = "boolean", Replicate = true },

            -- Leading underscore is a common convention for internal/non-public fields.
            -- No Replicate/Persist flags means it stays local and is not saved.
            _hinge = { Type = "BasePart" },
        },
    },
}
```

**StateMachine registry** (`ReplicatedStorage/StateMachine/StateMachineRegistry`):

```lua
-- This registry entry defines a StateMachine "class template".
-- Orchestrator:RegisterComponents() compiles this into shared.StateMachine.DoorJob.
return {
    DoorJob = {
        className = "DoorJob",

        -- Allowed state names; transition validation uses this list.
        validStates = { "Validate", "Opening", "Closing", "Completed", "Failed" },

        -- Terminal states stop the machine and trigger cleanup.
        terminalStates = { "Completed", "Failed" },

        -- Context is arbitrary data passed into the FSM at creation.
        -- Use it to store references (like the DoorEntity) and inputs.
        context = {
            DoorEntity = nil,
            DesiredState = nil,
        },

        -- Priority is "every N frames" (lower = more frequent).
        Priority = 10,
    },
}
```

**Server bootstrap**:

```lua
-- Typical server-side startup flow:
-- 1) Require the Orchestrator, 2) compile registries, 3) require implementation modules,
-- 4) start the scheduler loop, 5) create runtime instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Orchestrator = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("Orchestrator"))

-- Compiles registries into shared.Entity.* and shared.StateMachine.*
Orchestrator:RegisterComponents()

-- Attach behavior (optional, but recommended)
-- These modules typically implement ApplyChanges (Entity) and RegisterStates (FSM).
require(ReplicatedStorage:WaitForChild("Entity"):WaitForChild("DoorEntity"))
require(ReplicatedStorage:WaitForChild("StateMachine"):WaitForChild("DoorJob"))

-- Starts the global frame-budgeted task scheduler.
shared.FSM.Scheduler:Start()

local doorModel = workspace:WaitForChild("Door")
local entity = Orchestrator.CreateEntity({
    -- You can pass the class name string (compiled via registry) or a class table.
    EntityClass = "DoorEntity",
    EntityId = "Door_01",
    -- Context.Instance is required: it is the Roblox object the Entity wraps.
    Context = { Instance = doorModel },
})

local fsm = Orchestrator.CreateStateMachine({
    StateMachineClass = "DoorJob",
    StateMachineId = "DoorJob_01",
    Context = {
        -- Pass runtime dependencies into the state machine.
        DoorEntity = entity,
        DesiredState = "Open",
    },
})

-- Starts the FSM at a specific state; transitions are driven by your registered states.
fsm:Start({ State = "Validate" })
```

### B) Manual class tables (no registry)

Create classes via `BaseEntity.Extend(...)` / `BaseStateMachine.Extend(...)` and pass the class tables directly to `CreateEntity` / `CreateStateMachine`.

Use this when you:

- Are prototyping quickly (no registry plumbing yet).
- Want to generate classes dynamically.
- Prefer explicit `require()` and composition over a registry.

---

## 🕸️ Orchestrator

The central registry and factory for all components.

Think of the Orchestrator as the “runtime kernel” of this package:

- It builds the shared globals (`shared.FSM`, `shared.Entity`, `shared.StateMachine`).
- It creates and tracks unique runtime instances by ID.
- It wires up server → client replication for entity state, plus a request/command layer for client → server calls.

In most games, you will call `Orchestrator:RegisterComponents()` during your startup/bootstrap and then interact with the Orchestrator for all creation/destruction.

> [!IMPORTANT]
> Authoritative changes should only be made on the **Server**. Clients will automatically receive updates for schema fields marked with `Replicate = true`.

Common patterns:

- **Server-authoritative entities**: server creates via `CreateEntity`, mutates via schema (`entity.SomeKey = value`), then commits via `UpdateEntity(...)`. Clients receive replicated updates for schema fields marked `Replicate = true`.
- **Long-lived workflows**: server creates a StateMachine via `CreateStateMachine` and starts it with `fsm:Start({ State = "Initial" })`. The Orchestrator cleans up machines automatically after they complete/fail/cancel.
- **Client → server interaction**: clients use `SendCommand` for fire-and-forget commands and `Request` for request/response.
- **Local decoupling**: use EventBuses (`RegisterEventBus`, `FireEventBus`, etc.) when you want modules to communicate without direct references.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `RegisterComponents` | `(): ()` | Builds `shared.FSM`, compiles registries, and populates `shared.Entity` / `shared.StateMachine`. |
| `CreateEntity` | `(params: { EntityClass: any, EntityId: string?, Context: { any }?, Persistent: boolean?, PersistenceKey: string? }): Entity?` | Creates or retrieves a unique Entity. `Context.Instance` is required. If `EntityId` is missing/empty, a GUID is generated. |
| `CreateStateMachine` | `(params: { StateMachineClass: any, StateMachineId: string?, Context: { any }? }): FSM?` | Creates or retrieves a unique StateMachine. If `StateMachineId` is missing/empty, a GUID is generated. |
| `GetEntity` | `(id: string): Entity?` | Retrieves an active Entity by ID. |
| `GetStateMachine` | `(id: string): FSM?` | Retrieves an active StateMachine by ID. |
| `RetryStateMachine` | `(id: string): ()` | Destroys and recreates an FSM, preserving its Context. |
| `CancelStateMachine` | `(id: string): boolean` | Cancels an FSM by ID. Returns `true` if found. |
| `DeleteEntity` | `(id: string): ()` | Destroys an Entity by ID. If persistent, saves before destruction. |
| `DeleteAllEntities` | `(): ()` | Destroys all active Entities. |
| `CancelAll` | `(): ()` | Cancels all active StateMachines. |
| `GetEntities` | `(): { [string]: any }` | Returns the internal active Entities map. |
| `GetStateMachines` | `(): { [string]: any }` | Returns the internal active StateMachines map. |
| `SendCommand` | `(id: string, cmd: string, ...args): ()` | (Client) Sends a command to the Server for a specific Entity. |
| `RegisterCommandHandler` | `(id: string, cmd: string, handler: (player: Player, ...any) -> ()): ()` | (Server) Registers a listener for `SendCommand`. |
| `RegisterRequestHandler` | `(requestName: string, handler: (player: Player, ...any) -> any): ()` | (Server) Registers a request/response handler. |
| `Request` | `(requestName: string, ...args): any?` | (Client) Performs a request/response call to the server. |
| `PoolEntity` | `(id: string): ()` | Deactivates and adds an Entity to the internal pool. |
| `GetPooledEntity` | `(params: { EntityClass: any, EntityId: string?, Context: { any }? }): Entity?` | Retrieves a pooled Entity instance if available (else creates new). |
| `RegisterEventBus` | `(name: string): Signal` | Registers a new local event bus. |
| `GetEventBus` | `(name: string): Signal?` | Retrieves an existing local event bus. |
| `FireEventBus` | `(name: string, ...args): ()` | Fires a local event bus. |
| `AwaitEventBus` | `(name: string, timeout: number?): Signal?` | Yields until an event bus is registered or timeout is reached. |
| `StartServiceManagerAPI` | `(): ()` | (Server) Public wrapper for starting the remote ServiceManager API (used by tests/manual startup). |

---

## 🏗️ BaseEntity

Managed data authority and physical proxy.

An Entity is a schema-validated wrapper around a Roblox `Instance` (or model) that helps you:

- Keep authoritative state in one place.
- Validate and stage changes through a schema.
- Replicate only the fields you explicitly mark with `Replicate = true`.
- Persist only the fields you explicitly mark with `Persist = true`.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(params: { Name: string, Instance: Instance, OwnerId: string? }, class: any?): Entity` | Low-level constructor used by Factory/Orchestrator. Prefer `Extend(...)` + Orchestrator creation. |
| `Extend` | `(def: { Name: string, Schema: table? }): class` | Creates a new Entity class (Schema may be omitted; defaults to empty). |
| `Log` | `(params: { Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string }): ()` | Records a log entry for this entity. |
| `DefineSchema` | `(schema: { [string]: PropertyDef }): ()` | Replaces the active Schema table (advanced). |
| `SetContext` | `(key: any, value: any): ()` | Stores non-schema data used for internal logic (`entity.Context`-style access). |
| `UpdateEntity` | `(lockingCallerId: string?): boolean` | Commits pending changes, fires `StateUpdated`, and (server) triggers replication/persistence. |
| `ApplyChanges` | `(changes: table): ()` | Virtual method; implement for visual/physical updates. |
| `Cleanup` | `(): ()` | Virtual method; called during `Destroy()` for subclass cleanup. |
| `Serialize` | `(): table` | Returns a table of properties marked `Persist = true`. |
| `Deserialize` | `(data: table): ()` | Loads persistent data into the entity. |
| `GetValidProperties` | `(): { [string]: PropertyDef }` | Returns the Schema table used for type/replication/persistence decisions. |
| `AcquireLock` | `(callerId: string): boolean` | Attempts to acquire an entity lock. |
| `ReleaseLock` | `(callerId: string): boolean` | Releases an acquired lock. |
| `Manage` | `(obj: any): any` | Registers an object (Instance/Connection) for cleanup. |
| `Destroy` | `(): ()` | Cleans up the Entity and its managed resources. |

---

## 🧠 BaseStateMachine

The behavioral controller (FSM/HFSM).

A StateMachine drives behavior over time. It runs inside a shared Heartbeat loop and transitions between named states.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(params: { Id: string, Name: string, ValidStates: { string }?, TerminalStates: { string }?, Context: any?, Priority: number? }): FSM` | Low-level constructor used by `.Extend(...)` subclasses and tests. |
| `Extend` | `(def: { className: string, validStates: { string }?, terminalStates: { string }?, context: table?, Priority: number? }): class` | Creates a new StateMachine class template. |
| `AddState` | `(name: string, state: function|table, validOutcomes: { string }?): ()` | Registers a state and optional legal transition list. |
| `AddSubMachine` | `(name: string, subMachineClass: any, config: { InitialState: string, Transitions: { OnCompleted: string, OnFailed: string, OnCancelled: string? }, StoreReference: string? }): ()` | Registers a hierarchical sub-machine state. |
| `Manage` | `(obj: any): any` | Registers an object for cleanup. |
| `Start` | `(params: { State: string, Args: { any }? }): ()` | Begins execution. |
| `ChangeState` | `(params: { Name: string, Args: { any }? }): ()` | Transitions to a new state (or set `fsm.State = "..."`). |
| `Finish` | `(): ()` | Stops the machine with Completed status. |
| `Fail` | `(reason: string): ()` | Stops the machine with Failed status. |
| `Cancel` | `(): ()` | Stops the machine with Cancelled status. |
| `Destroy` | `(): ()` | Tears down the machine and disconnects managed resources. |
| `Log` | `(params: { Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string, Data: any? }): ()` | Records a log entry into machine history. |
| `RegisterStates` | `(): ()` | Virtual method; override in subclasses. |
| `OnCleanup` | `(): ()` | Virtual method; called during teardown. |

---

## ⚡ Scheduler

Frame-budgeted asynchronous task manager with priority-based fairness.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(settings: any?): Scheduler` | Creates a new scheduler instance. |
| `Initialize` | `(settings: any?): Scheduler` | Applies settings and returns `self`. |
| `Schedule` | `(params: { TaskName: string, TaskAction: () -> (), TaskExecutionDelay: number?, IsRecurringTask: boolean?, Priority: number?, Event: string?, FetchData: (() -> ())? }): Task?` | Adds a task. |
| `Deschedule` | `(name: string): ()` | Cancels a pending task. |
| `GetTask` | `(name: string): Task?` | Retrieves a task by name. |
| `ExecuteTask` | `(taskOrName: string | Task): ()` | Runs a task immediately outside the budget. |
| `GetSyncData` | `(): any` | Returns a serializable snapshot. |
| `ExposeAPI` | `(): ()` | (Server) Installs RemoteFunction API. |
| `Start` | `(): ()` | Connects `Step(...)` to RunService events. |
| `Step` | `(eventName: string?): ()` | Runs due tasks for an event (frame-budgeted). |

---

## 🪵 Logger

Structured logging with in-memory history.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(params: { Name: string? }): Logger` | Creates a new logger instance. |
| `Log` | `(params: { Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string, OperationId: string?, Data: any? }): ()` | Records a log entry. |
| `GetHistory` | `(): table` | Returns the recent log history. |

---

## 🌳 BehaviorTree

A functional, lightweight implementation for complex AI logic.

Constants:

- `BehaviorTree.BehaviorTreeStatus = { Success = "Success", Failure = "Failure", Running = "Running" }`
- `BehaviorTreeStatus = "Success" | "Failure" | "Running"`

| Method | Signature | Description |
| :--- | :--- | :--- |
| `Selector` | `(children: { (context: any) -> BehaviorTreeStatus }): (context: any) -> BehaviorTreeStatus` | Runs children until one succeeds. |
| `Sequence` | `(children: { (context: any) -> BehaviorTreeStatus }): (context: any) -> BehaviorTreeStatus` | Runs children until one fails. |
| `Inverter` | `(child: (context: any) -> BehaviorTreeStatus): (context: any) -> BehaviorTreeStatus` | Inverts Success/Failure (Running unchanged). |
| `Succeeder`| `(child: (context: any) -> BehaviorTreeStatus): (context: any) -> BehaviorTreeStatus` | Always returns Success (unless Running). |
| `Condition`| `(predicate: (context: any) -> boolean): (context: any) -> BehaviorTreeStatus` | Returns Success/Failure based on predicate. |
| `SetState` | `(stateName: string): (fsm: any) -> BehaviorTreeStatus` | Utility to change FSM state. Returns Success. |

---

## 🧩 Factory

The registry compiler used by `Orchestrator:RegisterComponents()`.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `Get` | `(typeName: string, name: string): any` | Returns a compiled class table or throws. |
| `GetAll` | `(typeName: string): any` | Returns compiled class table map (do not mutate). |
| `LoadSubclasses` | `(): ()` | Requires ModuleScripts alongside registries (implementation modules). |

---

## 📡 Signal

Local lightweight event signal.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(): Signal` | Creates a new signal instance. |
| `Connect` | `(handler: (...any) -> ()): Connection` | Adds a handler. |
| `Once` | `(handler: (...any) -> ()): Connection` | Adds a handler that fires once. |
| `Fire` | `(...args: any): ()` | Fires handlers asynchronously (`task.spawn`). |
| `Wait` | `(): ...any` | Yields until fired; returns fired args. |
| `Destroy` | `(): ()` | Disconnects all handlers. |

---

## 💾 DataStoreHandler

Thin wrapper around `DataStoreService` with throttling, optional retries, and optional caching.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `ResetAccessCount` | `(): ()` | Resets internal access counters. |
| `get` | `(databaseName: string, scope: string?, orderedBool: boolean?): DataStore` | Returns a cached wrapper for a DataStore / OrderedDataStore. |

---

## 🗄️ EntityPersistence

Persistence controller used by Orchestrator when `Persistent = true`.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(config: { DataStoreName: string, Scope: string?, KeyPrefix: string?, DataStoreHandler: any, EnableRetry: boolean?, RetryConfig: any? }): EntityPersistence` | Creates a persistence controller. |
| `Save` | `(entity: any, key: string, metadata: { [string]: any }?): (boolean, string?)` | Serializes and saves the entity. |
| `Load` | `(entity: any, key: string): (boolean, { [string]: any }?, string?)` | Loads data and calls `entity:Deserialize(data)` if available. |
| `Update` | `(key: string, mutateFn: (data: { [string]: any }) -> { [string]: any }): (boolean, string?)` | UpdateAsync wrapper that stores JSON payloads. |
| `Delete` | `(key: string): (boolean, string?)` | Removes the key from the DataStore. |

---

## ⚙️ Settings

Static configuration used by Orchestrator for remotes, persistence defaults, and Scheduler tasks.

- `Settings.Scheduler`, `Settings.DataStore`, `Settings.FSMSettings`, `Settings.StaticStrings`

---

## 🧾 Types

`Types.luau` exports type aliases/interfaces only (no runtime functions). It’s the source-of-truth for the shapes referenced above.
