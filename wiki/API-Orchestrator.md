# API: Orchestrator

Derived from the in-repo cheatsheet (`FSM/README.md`).

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

### 📡 Event Bus (Decoupling)

The Event Bus allows modules to communicate without needing direct `require` references. This is excellent for global events like `OnMatchStarted` or `OnWeatherChanged`.

```lua
-- Subscriber Module
local bus = Orchestrator:AwaitEventBus("MatchEvents")
bus:Connect(function(status)
    print("Match status changed:", status)
end)

-- Publisher Module
Orchestrator:FireEventBus("MatchEvents", "Started")
```

---

### 🏊 Entity Pooling

Pooling is essential for high-performance games where objects (bullets, effects, temporary NPCs) are created and destroyed frequently.

1.  **Pool**: Call `Orchestrator:PoolEntity(id)`. This deactivates the entity and moves it to an internal stack.
2.  **Reuse**: Call `Orchestrator:GetPooledEntity({ EntityClass = "MyBullet", ... })`. 
    - If a bullet is in the pool, it is **reset and reactivated**.
    - If the pool is empty, a **new** bullet is created.

> [!TIP]
> Use `PoolEntity` instead of `DeleteEntity` for any object that will likely be spawned again soon.

---

## Client vs Server behavior

`RegisterComponents()` is safe to call on both layers; it runs different initialization stages depending on `RunService:IsServer()` vs `RunService:IsClient()`.

- Client-only (no-op on server): `SendCommand`, `Request`.
- Server-only (no-op on client): `RegisterCommandHandler`, `RegisterRequestHandler`, `StartServiceManagerAPI`.
- `CreateEntity` / `CreateStateMachine` can be called on both layers. On the client they’re used internally by the replication/sync path (ServiceManager events + snapshots); in typical gameplay you create authoritative instances on the server.

Practical guidance:

- Call `RegisterComponents()` in both a server bootstrap and a client bootstrap if you want clients to be able to resolve `shared.Entity.*` / `shared.StateMachine.*` locally.
- Create and mutate authoritative data on the **server**. On the client, treat replicated entity data as read-only.

## Shared globals created by `RegisterComponents`

`RegisterComponents()` populates:

- `shared.Entity` / `shared.StateMachine`: compiled class tables from registries (via Factory).
- `shared.FSM`:
    - `shared.FSM.Entities` / `shared.FSM.StateMachines`: internal live maps
    - `shared.FSM.Orchestrator`: this module
    - `shared.FSM.Scheduler`: a `Scheduler.new()` instance
    - `shared.FSM.BehaviorTree`, `shared.FSM.Logger`, `shared.FSM.Settings`, `shared.FSM.History`, `shared.FSM.Factory`
