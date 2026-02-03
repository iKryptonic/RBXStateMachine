# FSM API Reference (Cheatsheet)

This is a concise technical reference for the **FiniteStateMachine** core components.

It’s designed for both:

- **Beginners** who want a “what do I call, in what order?” walkthrough.
- **Intermediate/advanced** users who want an accurate method/signature reference that matches the code.

This project is built around a **Factory + Registry** workflow:

- Definitions live in `ReplicatedStorage/Entity/EntityRegistry` and `ReplicatedStorage/StateMachine/StateMachineRegistry`.
- `Orchestrator:RegisterComponents()` compiles those definitions into classes and exposes them as `shared.Entity.*` and `shared.StateMachine.*`.
- You then (optionally) require “implementation modules” to attach methods like `ApplyChanges()` and `RegisterStates()`.

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

### Client vs Server behavior

`RegisterComponents()` is safe to call on both layers; it runs different initialization stages depending on `RunService:IsServer()` vs `RunService:IsClient()`.

- Client-only (no-op on server): `SendCommand`, `Request`.
- Server-only (no-op on client): `RegisterCommandHandler`, `RegisterRequestHandler`, `StartServiceManagerAPI`.
- `CreateEntity` / `CreateStateMachine` can be called on both layers. On the client they’re used internally by the replication/sync path (ServiceManager events + snapshots); in typical gameplay you create authoritative instances on the server.

Practical guidance:

- Call `RegisterComponents()` in both a server bootstrap and a client bootstrap if you want clients to be able to resolve `shared.Entity.*` / `shared.StateMachine.*` locally.
- Create and mutate authoritative data on the **server**. On the client, treat replicated entity data as read-only.

### Shared globals created by `RegisterComponents`

`RegisterComponents()` populates:

- `shared.Entity` / `shared.StateMachine`: compiled class tables from registries (via Factory).
- `shared.FSM`:
    - `shared.FSM.Entities` / `shared.FSM.StateMachines`: internal live maps
    - `shared.FSM.Orchestrator`: this module
    - `shared.FSM.Scheduler`: a `Scheduler.new()` instance
    - `shared.FSM.BehaviorTree`, `shared.FSM.Logger`, `shared.FSM.Settings`, `shared.FSM.History`, `shared.FSM.Factory`

---

## 🏗️ BaseEntity

Managed data authority and physical proxy.

An Entity is a schema-validated wrapper around a Roblox `Instance` (or model) that helps you:

- Keep **authoritative state** in one place (usually the server).
- Validate and stage changes through a schema.
- Replicate only the fields you explicitly mark with `Replicate = true`.
- Persist only the fields you explicitly mark with `Persist = true`.

You typically extend `BaseEntity` to define a new Entity “class”, then create instances via `Orchestrator.CreateEntity(...)`. Use `ApplyChanges(changes)` to update the physical Roblox instance in response to data changes.

Why use Entities instead of raw Instances?

- You get a clear contract for what data exists (Schema).
- You get controlled mutation (pending changes + commit).
- You get opt-in replication/persistence per property.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(params: { Name: string, Instance: Instance, OwnerId: string? }, class: any?): Entity` | Low-level constructor used by Factory/Orchestrator. Prefer `Extend(...)` + Orchestrator creation. |
| `Extend` | `(def: { Name: string, Schema: table? }): class` | Creates a new Entity class (Schema may be omitted; defaults to empty). |
| `Log` | `(params: { Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string }): ()` | Records a log entry for this entity. |
| `DefineSchema` | `(schema: { [string]: PropertyDef }): ()` | Replaces the active Schema table (advanced). |
| `SetContext` | `(key: any, value: any): ()` | Stores non-schema data used for internal logic (`entity.Context`-style access). |
| `UpdateEntity` | `(lockingCallerId: string?): boolean` | Commits pending changes, fires `StateUpdated`, and (server) triggers replication/persistence. If the Entity is locked, the caller must provide the lock id. |
| `ApplyChanges` | `(changes: table): ()` | Virtual method; implement for visual/physical updates. |
| `Cleanup` | `(): ()` | Virtual method; called during `Destroy()` for subclass cleanup. |
| `Serialize` | `(): table` | Returns a table of properties marked `Persist = true`. |
| `Deserialize` | `(data: table): ()` | Loads persistent data into the entity. |
| `GetValidProperties` | `(): { [string]: PropertyDef }` | Returns the Schema table used for type/replication/persistence decisions. |
| `AcquireLock` | `(callerId: string): boolean` | Attempts to acquire an entity lock. |
| `ReleaseLock` | `(callerId: string): boolean` | Releases an acquired lock. |
| `Manage` | `(obj: any): any` | Registers an object (Instance/Connection) for cleanup. |
| `Destroy` | `(): ()` | Cleans up the Entity and its managed resources. |

Notes:

- `UpdateEntity(...)` will fast-fail (and log) if there are no pending changes, if the entity is destroyed, if the caller doesn’t hold the lock (when locked), or if the entity is “immutable” (i.e. `ApplyChanges` was not overridden / made mutable).
- On the server, Orchestrator listens to `entity.StateUpdated` and replicates only schema keys with `Replicate = true`.
- Signals/events (these are `Signal` instances from this library):
    - `entity.StateUpdated:Fire(changes)` where `changes: { [string]: any }`
    - `entity.Destroyed:Fire()`
- Context shortcut: the entity is callable. `entity({ SomeKey = SomeValue })` stores values into its internal Context table (non-schema data).

Schema tips:

- Define gameplay state (open/closed, health, owner, etc.) in the Schema.
- Put cached Instance references, computed values, and non-replicated helpers into Context via `SetContext` or the callable shortcut.

```lua
-- Manual class creation (no registry): defines an Entity class table in code.
-- This is useful for prototyping/tests; in production you often prefer registries.
local DoorEntity = BaseEntity.Extend({
    Name = "DoorEntity",
    Schema = {
        -- This field will be replicated and persisted once the entity is created by Orchestrator.
        IsOpen = { Type = "boolean", Replicate = true, Persist = true },
    }
})
```

### 💾 Persistence Setup
Entities can automatically Save/Load from DataStores.

Use persistence when you want state to survive server restarts (e.g. world objects, player-owned structures, long-running jobs). Persistence is server-side only.

1. **Mark Schema for Persistence**: Set `Persist = true` in the property definition.
2. **Enable in Orchestrator**:
```lua
-- Creating a Persistent entity tells Orchestrator to wire it to EntityPersistence.
-- On creation, it will attempt a Load; after successful updates, it will Save.
Orchestrator.CreateEntity({
    -- With manual classes, pass the class table; with registries you can pass a class name string.
    EntityClass = DoorEntity,
    Persistent = true,
    -- Optional explicit key (otherwise the system uses a derived/generated key).
    PersistenceKey = "WorldDoor_01"
})
```

---

## 🧠 BaseStateMachine

The behavioral controller (FSM/HFSM).

A StateMachine drives *behavior over time*. It runs inside a shared Heartbeat loop and transitions between named states.

Use a StateMachine when you have multi-step logic that benefits from explicit phases and transitions (quests, jobs, AI, door opening sequences, crafting pipelines). Sub-machines (`AddSubMachine`) let you build hierarchical flows (HFSM) without losing readability.

State representation:

- A state can be a **function** (legacy style) or a **table/object** with methods like `OnEnter`, `OnHeartbeat`, `OnLeave` and optional transition conditions.
- `validOutcomes` provides a safety net so that “illegal” transitions are rejected early and logged.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(params: { Id: string, Name: string, ValidStates: { string }?, TerminalStates: { string }?, Context: any?, Priority: number? }): FSM` | Low-level constructor used by `.Extend(...)` subclasses and tests. |
| `Extend` | `(def: { className: string, validStates: { string }?, terminalStates: { string }?, context: table?, Priority: number? }): class` | Creates a new StateMachine class template. |
| `AddState` | `(name: string, state: function|table, validOutcomes: { string }?): ()` | Registers a state and optional legal transition list. |
| `AddSubMachine` | `(name: string, subMachineClass: any, config: { InitialState: string, Transitions: { OnCompleted: string, OnFailed: string, OnCancelled: string? }, StoreReference: string? }): ()` | Registers a hierarchical sub-machine state. |
| `Manage` | `(obj: any): any` | Registers an object for cleanup. |
| `Start` | `(params: { State: string, Args: { any }? }): ()` | Begins execution (registers into global tick loop). |
| `ChangeState` | `(params: { Name: string, Args: { any }? }): ()` | Transitions to a new state (or set `fsm.State = "..."`). |
| `Finish` | `(): ()` | Stops the machine with Completed status. |
| `Fail` | `(reason: string): ()` | Stops the machine with Failed status. |
| `Cancel` | `(): ()` | Stops the machine with Cancelled status. |
| `Destroy` | `(): ()` | Tears down the machine and disconnects managed resources. |
| `Log` | `(params: { Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string, Data: any? }): ()` | Records a log entry into machine history. |
| `RegisterStates` | `(): ()` | Virtual method; override in subclasses to call `AddState/AddSubMachine`. |
| `OnCleanup` | `(): ()` | Virtual method; called during teardown. |

Signals/events (these are `Signal` instances from this library):

- `fsm.Completed:Fire()`
- `fsm.Failed:Fire(reason: string)`
- `fsm.Cancelled:Fire()`
- `fsm.StateChanged:Fire(newState: string, oldState: string?)`

Internal (advanced; callable but intended for runtime use):

- `_Update(dt: number): ()` — tick invoked by the shared Heartbeat loop.
- `_Teardown(): ()` — stops the machine and runs cleanup.

**Priorities:** `Render (1)`, `High (2)`, `Medium (5)`, `Low (10)`, `Background (30)`.

`BaseStateMachine.Priorities` is the canonical constant table used by the runtime.

Transition rules:

- If `validStates` is provided (registry/class), `AddState` and `ChangeState` will reject unknown state names.
- If a state was registered with a non-empty `validOutcomes` list, transitions out of that state are validated against the list.
- Setting `fsm.State = "SomeState"` triggers `ChangeState({ Name = "SomeState" })` via `__newindex`.

**Priority behavior (how it’s used):** Priority is “run every N frames” inside a single shared Heartbeat loop. Skipped-frame `dt` is accumulated and passed into `_Update(dt)` when the machine ticks.

### Extend vs new

- Use `BaseStateMachine.Extend(def)` to define a reusable **class template** (attach `RegisterStates`, `OnCleanup`, helpers). This is what the Factory/Registry compiles and exposes as `shared.StateMachine.*`.
- Use `BaseStateMachine.new(params)` to construct the base runtime directly (good for one-offs/tests), but you don’t get a registry-friendly class table unless you wrap it yourself.

---

## ⚡ Scheduler

Frame-budgeted asynchronous task manager with priority-based fairness.

The Scheduler is for “run this function later / repeatedly” work, while keeping frame time stable.

Use it for periodic tasks (datastore resets, cleanup loops, telemetry, batch processing) where you don’t want to accidentally spawn too much work in one frame. It also exposes an admin-gated RemoteFunction API for inspection/control in live sessions (ServiceManager compatibility).

When *not* to use it:

- If you need strict real-time guarantees (e.g. physics-critical work), prefer direct RunService connections.
- If a task must run exactly once at an exact time, consider `task.delay` for simple cases. Scheduler is best for recurring/queued work with fairness and budgeting.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(settings: any?): Scheduler` | Creates a new scheduler instance. |
| `Initialize` | `(settings: any?): Scheduler` | Applies settings and returns `self`. |
| `Clear` | `(): ()` | Clears all tasks/heaps/history/stats. |
| `Schedule` | `(params: { TaskName: string, TaskAction: () -> (), TaskExecutionDelay: number?, IsRecurringTask: boolean?, Priority: number?, Event: string?, FetchData: (() -> ())? }): Task?` | Adds a task. (Compatibility: if `FetchData` is provided and `TaskAction` is missing, it will be used as the action.) |
| `AddToHistory` | `(taskObj: any, status: any, duration: any, err: string?): ()` | Adds an entry to History (best-effort; used by ServiceManager). |
| `Deschedule` | `(name: string): ()` | Cancels a pending task. |
| `GetTask` | `(name: string): Task?` | Retrieves a task by name. |
| `GetTaskCount` | `(): number` | Counts scheduled tasks. |
| `ExecuteTask` | `(taskOrName: string | Task): ()` | Runs a task immediately outside the budget. |
| `GetSyncData` | `(): any` | Returns a serializable snapshot (tasks/logs/settings/history/stats). |
| `CheckAdmin` | `(player: Player): boolean` | (Server) Validates access for admin-only APIs. |
| `ExposeAPI` | `(): ()` | (Server) Installs `SchedulerClientFunction` RemoteFunction. |
| `ResetTask` | `(name: string): ()` | Resets a task's performance counters. |
| `GenerateKey` | `(): string` | Returns a GUID. |
| `Start` | `(): ()` | Connects `Step(...)` to RunService events. |
| `Step` | `(eventName: string?): ()` | Runs due tasks for a given event (frame-budgeted). |

Internal (advanced; used by the scheduler runtime):

- `_internalExecute(t: Task): ()`
- `_heapPush(heap: { Task }, item: Task): ()`
- `_heapPop(heap: { Task }): Task`

### ⚖️ Task Fairness (Aging)
To prevent **Priority Starvation**, the Scheduler implements an aging mechanism:
- **Frame Budget**: Limits task launches to a specific duration (default `5ms`) to maintain frame stability.
- **Aging Factor**: Tasks deferred due to budget constraints gain an **Effective Priority** boost (`Priority + (ConsecutiveDelays * AgingFactor)`).
- **FIFO Tie-breaker**: Tasks with the same effective priority are executed in the order they were scheduled (`NextRun`).

---

## 🪵 Logger

Structured logging with in-memory history.

Use `Logger` when you want consistent logs that can be queried later (in tests, dev tooling, or live debugging). Most components in this package (Orchestrator, Entities, StateMachines, Scheduler) use logging to explain why an operation failed (invalid state transition, schema mismatch, lock errors, etc.).

Tip: use `OperationId` to correlate logs across multiple calls (e.g. an entity ID or job ID).

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(params: { Name: string? }): Logger` | Creates a new logger instance. |
| `Log` | `(params: { Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string, OperationId: string?, Data: any? }): ()` | Records a log entry. |
| `GetHistory` | `(): table` | Returns the recent log history. |

---

## 🌳 BehaviorTree

A functional, lightweight implementation for complex AI logic.

Behavior trees are great for AI or decision logic where you want composable “try this, else that” behavior. This implementation is functional: each node returns a function that takes a `context` and returns a `BehaviorTreeStatus`.

Use this when finite states alone feel too rigid, or you want reusable decision fragments that can be shared across many agents.

Constants:

- `BehaviorTree.BehaviorTreeStatus = { Success = "Success", Failure = "Failure", Running = "Running" }`
- `BehaviorTreeStatus = "Success" | "Failure" | "Running"`

| Method | Signature | Description |
| :--- | :--- | :--- |
| `Selector` | `(children: { (context: any) -> BehaviorTreeStatus }): (context: any) -> BehaviorTreeStatus` | Runs children until one succeeds. |
| `Sequence` | `(children: { (context: any) -> BehaviorTreeStatus }): (context: any) -> BehaviorTreeStatus` | Runs children until one fails. |
| `Inverter` | `(child: (context: any) -> BehaviorTreeStatus): (context: any) -> BehaviorTreeStatus` | Inverts Success/Failure (Running is unchanged). |
| `Succeeder`| `(child: (context: any) -> BehaviorTreeStatus): (context: any) -> BehaviorTreeStatus` | Always returns Success (unless Running). |
| `Condition`| `(predicate: (context: any) -> boolean): (context: any) -> BehaviorTreeStatus` | Returns Success/Failure based on a predicate. |
| `SetState` | `(stateName: string): (fsm: any) -> BehaviorTreeStatus` | Utility to change FSM state. Returns Success. |

**Example:**
```lua
local BT = shared.BehaviorTree

-- This behavior tree runs top-down every tick you call it.
-- The "context" here is the FSM (or any table you choose).
local ai = BT.Selector({
    BT.Sequence({
        -- If health is low, choose Retreat.
        BT.Condition(function(fsm) return fsm.Health < 20 end),
        BT.SetState("Retreat")
    }),

    -- Otherwise (sequence failed), fall back to Attack.
    BT.SetState("Attack")
})
```

---

## 🧩 Factory

The registry compiler used by `Orchestrator:RegisterComponents()`.

You typically don’t call Factory methods directly unless you’re building tooling, debugging registry compilation, or doing advanced dynamic class loading.

The Orchestrator uses Factory to compile registry definitions into runtime-friendly class tables and then exposes them on `shared.Entity.*` and `shared.StateMachine.*`.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `Get` | `(typeName: string, name: string): any` | Returns a compiled class table or throws. |
| `GetAll` | `(typeName: string): any` | Returns the compiled class table map (do not mutate). |
| `LoadSubclasses` | `(): ()` | Requires any ModuleScripts found alongside registries (implementation modules). |

---

## 📡 Signal

Local lightweight event signal used for event buses and internal events.

Signals provide an ergonomic alternative to BindableEvents for module-level eventing. They’re used throughout the system for:

- Entity change events (`StateUpdated`, `Destroyed`)
- StateMachine lifecycle (`Completed`, `Failed`, `Cancelled`, `StateChanged`)
- Orchestrator event buses

Use `Signal` when you want a simple connect/fire/wait abstraction without depending on Instances.

Connection shape:

- `Connection = { Disconnect: (self: Connection) -> () }`

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

Use `DataStoreHandler.get(...)` when you want a single place to manage datastore access patterns and error handling. It provides:

- Best-effort throttling for “write-heavy” operations.
- Optional retries for transient datastore failures.
- Optional read caching for hot keys.

This is used by `EntityPersistence` (and therefore by Orchestrator persistence) to store entity state.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `ResetAccessCount` | `(): ()` | Resets internal access counters (used by Scheduler task). |
| `get` | `(databaseName: string, scope: string?, orderedBool: boolean?): DataStore` | Returns a cached wrapper for a DataStore / OrderedDataStore. |

### DataStore wrapper

Returned by `DataStoreHandler.get(...)`.

| Method | Signature |
| :--- | :--- |
| `SetRetryConfig` | `(config: { enabled: boolean?, retries: number?, baseDelay: number?, jitter: number? }?): ()` |
| `EnableRetry` | `(enabled: boolean): ()` |
| `_call` | `(fn: () -> any): (boolean, any?, string?)` *(internal; retry-aware call helper)* |
| `GetAsync` | `(Key: string): (boolean, any?, string?)` |
| `SetAsync` | `(Key: string, value: any): (boolean, nil, string?)` |
| `UpdateAsync` | `(Key: string, transformFunction: (any) -> any): (boolean, any?, string?)` |
| `IncrementAsync` | `(Key: string, delta: number): (boolean, any?, string?)` |
| `RemoveAsync` | `(Key: string): (boolean, any?, string?)` |
| `SetCachingTime` | `(TimeInSeconds: number): ()` |
| `GetDBName` | `(): string` |
| `GetSortedAsync` | `(ascending: boolean, pagesize: number, minValue: number?, maxValue: number?): (boolean, any?, string?)` *(ordered stores only)* |

Also exposes `OnUpdate` from the underlying Roblox DataStore object.

---

## 🗄️ EntityPersistence

Persistence controller used by Orchestrator when `Persistent = true`.

This module saves an entity’s serialized data as a JSON payload and restores it back into the entity via `Deserialize(...)`.

Use it when you want opt-in persistence per entity. The Orchestrator will automatically call `Load` when creating a persistent entity and `Save` after updates.

Notes:

- Persistence stores a JSON payload with a `data` table (the serialized entity state) and optional `meta` (metadata you pass to `Save`).
- `Load` returns `true, nil, nil` when the key does not exist yet.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(config: { DataStoreName: string, Scope: string?, KeyPrefix: string?, DataStoreHandler: any, EnableRetry: boolean?, RetryConfig: any? }): EntityPersistence` | Creates a persistence controller bound to a DataStore. |
| `Save` | `(entity: any, key: string, metadata: { [string]: any }?): (boolean, string?)` | Serializes and saves the entity under the key. |
| `Load` | `(entity: any, key: string): (boolean, { [string]: any }?, string?)` | Loads data and calls `entity:Deserialize(data)` if available. |
| `Update` | `(key: string, mutateFn: (data: { [string]: any }) -> { [string]: any }): (boolean, string?)` | UpdateAsync wrapper that stores JSON payloads. |
| `Delete` | `(key: string): (boolean, string?)` | Removes the key from the DataStore. |

---

## ⚙️ Settings

Static configuration used by Orchestrator for remotes, persistence defaults, and Scheduler tasks.

- `Settings.Scheduler`, `Settings.DataStore`, `Settings.FSMSettings`, `Settings.StaticStrings`

You generally don’t need to edit Settings unless you are integrating this package into an existing framework that needs different remote names, datastore names/prefixes, or scheduling intervals.

---

## 🧾 Types

`Types.luau` exports type aliases/interfaces only (no runtime functions). It’s the source-of-truth for the shapes referenced above (e.g. `PropertyDef`, `Task`, `ScheduleTaskParams`, `PersistenceConfig`, `EntityPersistence`).

If you’re using `--!strict`, prefer importing Types in your own modules when you want autocomplete/type safety for schemas, scheduler tasks, or persistence configs.

---

## ✅ API Completeness Checklist

Use this as a quick parity checklist when updating code or docs. If you add a new exported method in code, add it to the relevant section above.

- Orchestrator (`FSM/Orchestrator/init.luau`): `RegisterComponents`, `CreateEntity`, `CreateStateMachine`, `GetEntity`, `GetStateMachine`, `RetryStateMachine`, `CancelStateMachine`, `DeleteEntity`, `DeleteAllEntities`, `CancelAll`, `GetEntities`, `GetStateMachines`, `SendCommand`, `RegisterCommandHandler`, `RegisterRequestHandler`, `Request`, `PoolEntity`, `GetPooledEntity`, `RegisterEventBus`, `GetEventBus`, `FireEventBus`, `AwaitEventBus`, `StartServiceManagerAPI`
- BaseEntity (`FSM/Orchestrator/Factory/BaseEntity.luau`): `new`, `Extend`, `Log`, `DefineSchema`, `SetContext`, `Manage`, `Serialize`, `Deserialize`, `UpdateEntity`, `ApplyChanges`, `Cleanup`, `GetValidProperties`, `AcquireLock`, `ReleaseLock`, `Destroy` (+ callable context shortcut)
- BaseStateMachine (`FSM/Orchestrator/Factory/BaseStateMachine.luau`): `new`, `Extend`, `AddState`, `AddSubMachine`, `Manage`, `Start`, `ChangeState`, `Finish`, `Fail`, `Cancel`, `Destroy`, `Log`, `RegisterStates`, `OnCleanup` (+ internal `_Update`, `_Teardown`)
- Scheduler (`FSM/Orchestrator/Scheduler.luau`): `new`, `Initialize`, `Clear`, `Schedule`, `AddToHistory`, `Deschedule`, `GetTask`, `GetTaskCount`, `ExecuteTask`, `GetSyncData`, `CheckAdmin`, `ExposeAPI`, `ResetTask`, `GenerateKey`, `Start`, `Step` (+ internal `_internalExecute`, `_heapPush`, `_heapPop`)
- Logger (`FSM/Orchestrator/Logger.luau`): `new`, `Log`, `GetHistory`
- BehaviorTree (`FSM/Orchestrator/BehaviorTree.luau`): `Selector`, `Sequence`, `Inverter`, `Succeeder`, `Condition`, `SetState` (+ `BehaviorTreeStatus` constants)
- Factory (`FSM/Orchestrator/Factory/init.luau`): `Get`, `GetAll`, `LoadSubclasses`
- Signal (`FSM/Orchestrator/Signal.luau`): `new`, `Connect`, `Once`, `Fire`, `Wait`, `Destroy`
- DataStoreHandler (`FSM/Orchestrator/DataStoreHandler.luau`): `ResetAccessCount`, `get` (+ DataStore wrapper methods documented above)
- EntityPersistence (`FSM/Orchestrator/EntityPersistence/init.luau`): `new`, `Save`, `Load`, `Update`, `Delete`

