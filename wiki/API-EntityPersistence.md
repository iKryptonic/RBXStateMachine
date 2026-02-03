# API: EntityPersistence

The high-level manager connecting Entities to DataStores.

---

## 🔧 Methods

### `Save(entity, key, metadata?)`
*   **Summary**: Serializes persistent schema fields and commits them to the database.
*   **Parameters**:
    *   `entity` (Entity): Target instance.
    *   `key` (string): DB key.
    *   `metadata` (table?): Extra data to save.
*   **Return**: `boolean`

### `Load(entity, key)`
*   **Summary**: Fetches data and injects it into the entity proxy.
*   **Return**: `(ok, data, error)`

---

## 🚀 Orchestrator Integration

Persistence is usually handled automatically if you set `Persistent = true` in `Orchestrator.CreateEntity`.
*   **Auto-Save**: Triggered during `Orchestrator.DeleteEntity(id)`.
*   **Key Prefixing**: Configured in [Settings](API-Settings#datastore-settings).
