# API: EntityPersistence

Derived from the in-repo cheatsheet (`FSM/README.md`).

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
