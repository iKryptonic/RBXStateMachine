# API: Orchestrator

The **Orchestrator** is the microkernel of the framework. It manages the lifecycle of all entities and state machines, facilitates networking between client and server, and provides a global event bus for decoupling modules.

---

## 🏗️ Creation & Lifecycle

### `RegisterComponents()`
*   **Layer**: Shared (Server & Client)
*   **Summary**: Bootstraps the framework. Scans the file system for `EntityRegistry` and `StateMachineRegistry` modules, compiles them into class proxies, and injects implementation modules into `shared.Entity` and `shared.StateMachine`.
*   **Return**: `void`

### `CreateEntity(params)`
*   **Layer**: Shared
*   **Summary**: Spawns a new `BaseEntity` or retrieves an existing one.
*   **Parameters**:
    *   `EntityClass` (any): The name (string) or the class table of the entity to spawn.
    *   `EntityId` (string): Unique identifier. If nil, a GUID is generated. If its an existing ID, the existing entity is returned.
    *   `Context` (table?): Initial data to store in the entity proxy. Must contain `Instance` (Roblox Object).
    *   `Persistent` (boolean?): If true, the entity will automatically load/save state to a DataStore.
    *   `PersistenceKey` (string?): Custom key for the database. Defaults to `EntityId`.
*   **Return**: `Entity?`

### `CreateStateMachine(params)`
*   **Layer**: Shared
*   **Summary**: Spawns a new `BaseStateMachine`.
*   **Parameters**:
    *   `StateMachineClass` (any): The name (string) or the class table of the FSM to spawn.
    *   `StateMachineId` (string): Unique identifier.
    *   `Context` (table?): Data passed into the FSM. Best practice is to include the target `Entity`.
*   **Return**: `StateMachine?`

---

## 📡 Networking Methods (Client-Server)

### `RegisterCommandHandler(entityId, command, handler)`
*   **Layer**: Server-Only
*   **Summary**: Registers a callback for a specific command sent to an entity.
*   **Parameters**:
    *   `entityId` (string): The ID of the target entity.
    *   `command` (string): The name of the command to listen for.
    *   `handler` (function): Logic to run. Signature: `(Player, ...any) -> ()`.

### `RegisterRequestHandler(requestName, handler)`
*   **Layer**: Server-Only
*   **Summary**: Registers a callback for a request/response (RemoteFunction) call.
*   **Parameters**:
    *   `requestName` (string): Unique identifier for this request type.
    *   `handler` (function): Logic to run. Must return a value. Signature: `(Player, ...any) -> any`.

### `SendCommand(entityId, command, ...)`
*   **Layer**: Client-Only
*   **Summary**: Sends a fire-and-forget command to an entity on the server.
*   **Parameters**:
    *   `entityId` (string): target entity.
    *   `command` (string): command name.
    *   `...` (any): Arguments to pass to the handler.

### `Request(requestName, ...)`
*   **Layer**: Client-Only
*   **Summary**: Sends a yielding request to the server and returns the result.
*   **Parameters**:
    *   `requestName` (string): request id.
    *   `...` (any): Arguments for the handler.
*   **Return**: `any?` (The response from the server).

---

## 🏊 Advanced Management

### `PoolEntity(entityId)`
*   **Layer**: Shared
*   **Summary**: Deactivates an entity and puts it into a class-specific object pool for reuse. This is highly recommended for frequently spawned objects (projectiles, temporary NPCs).
*   **Effect**: Clears `CommandHandlers` for that ID and fires `OnEntityPooled` to clients.

### `GetPooledEntity(params)`
*   **Layer**: Shared
*   **Summary**: Retrieves an inactive entity from the pool or creates a new one if the pool is empty.
*   **Parameters**: (Same as `CreateEntity`)
*   **Return**: `Entity?`

### `SyncEntitiesFromServer()`
*   **Layer**: Client-Only (Internal)
*   **Summary**: Manually triggers a full snapshot request from the server to ensure local data parity.

---

## 📢 Global Event Bus (Decoupling)

### `RegisterEventBus(name)`
*   **Summary**: Creates a global Signal that acts as a message bus.
*   **Return**: `Signal`

### `FireEventBus(name, ...)`
*   **Summary**: Broadcasts data to all listeners on the named bus.

### `AwaitEventBus(name, timeout?)`
*   **Summary**: Yields until the specified bus is registered. Prevents initialization race conditions.
*   **Return**: `Signal?`

---

## 📋 Full Method Inventory

| Method | Role | Params |
| :--- | :--- | :--- |
| `Sync` | Sync Logic | `(player: Player)` |
| `GetEntity` | Discovery | `(id: string)` |
| `GetStateMachine` | Discovery | `(id: string)` |
| `DeleteEntity` | Cleanup | `(id: string)` |
| `CancelStateMachine`| Cleanup | `(id: string)` |
| `DeleteAllEntities` | Cleanup | `()` |
| `CancelAll` | Cleanup | `()` |
| `RetryStateMachine` | Recovery | `(id: string)` |

> [!IMPORTANT]
> **Networking Security**: The Orchestrator uses a single `RemoteEvent` and `RemoteFunction`. It automatically validates that the player sending a command has permissions (Admin check in Scheduler, Handler check in Orchestrator).
