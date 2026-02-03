# API: BaseEntity

The **BaseEntity** is the authoritative data layer. It acts as a "Schema-Validated Proxy" for a physical Roblox Instance.

---

## 🔧 Core Methods

### `new(params, class?)`
*   **Layer**: Internal/Shared
*   **Summary**: Creates the proxy object.
*   **Parameters**:
    *   `params.Name` (string): Entity class name.
    *   `params.Instance` (Instance): The underlying Roblox object.
    *   `params.OwnerId` (string?): Optional owner metadata.
    *   `class` (table?): The subclass defining methods.

### `UpdateEntity(lockingCallerId?)`
*   **Layer**: Shared (Server-Auth)
*   **Summary**: Commits all staged property changes.
*   **Parameters**:
    *   `lockingCallerId` (string?): If the entity is locked, you **must** provide the matching ID to commit changes.
*   **Return**: `boolean` (Success)

### `AcquireLock(callerId)`
*   **Layer**: Shared
*   **Summary**: Prevents other systems from calling `UpdateEntity` on this instance.
*   **Parameters**:
    *   `callerId` (string): Unique ID for the lock owner.
*   **Return**: `boolean` (True if acquired).

### `ReleaseLock(callerId)`
*   **Layer**: Shared
*   **Summary**: Releases a held lock.
*   **Parameters**:
    *   `callerId` (string): Must match the ID used to acquire the lock.

---

## ⚙️ Data & Schema

### `DefineSchema(schema)`
*   **Summary**: Sets the valid properties for the entity. Use this in your Implementations if forgoing the Registry.
*   **Parameters**: `schema: { [string]: PropertyDef }`

### `SetContext(key, value)`
*   **Summary**: Stores non-schema, non-replicated data on the proxy.
*   **Shortcut**: You can also use `entity({ Key = Value })`.

### `Serialize() / Deserialize(data)`
*   **Summary**: Handles the conversion of persistent schema fields into a Lua table for saving/loading.

---

## 🧹 Cleanup & Management

### `Manage(object)`
*   **Summary**: Registers a disposable object (Connection, Instance, Function) to be cleaned up when the entity is destroyed.
*   **Return**: `object`

### `Cleanup()`
*   **Summary**: Abstract method. Subclasses should override this for custom teardown logic.

### `Destroy()`
*   **Summary**: Fully cleans up the entity, disconnects internal ancestry listeners, and clears all `:Manage()` objects.

---

## 🧬 Subclass Hooks

### `ApplyChanges(changes)`
*   **Summary**: **Mandatory override**. This method runs after `UpdateEntity` commits. 
*   **Parameters**: `changes: { [string]: any }` (Contains only the keys that were modified in the current transaction).
*   **Usage**: Place visual tweens and sound triggers here (Client-side) or physics updates (Server-side).

---

## 📋 Full Method Inventory

| Method | Role |
| :--- | :--- |
| `Log(params)` | [Logging API](API-Orchestrator#logging) |
| `GetValidProperties` | Returns the Schema table. |
| `__tostring` | Debug representation. |

> [!CAUTION]
> **Immutability**: By default, Entities are immutable unless you override `ApplyChanges`. Attempting to call `UpdateEntity` on a base instance without an implementation module will fail with an error.
