# API: BaseEntity

Derived from the in-repo cheatsheet (`FSM/README.md`).

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

### ⚡ The `UpdateEntity` Lifecycle

`UpdateEntity()` is transactional. Changes are not applied to the "official" data or replicated until you call it.

1.  **Stage**: You set `entity.Health = 100`. The value is stored in a `Pending` table.
2.  **Commit**: You call `entity:UpdateEntity()`.
3.  **Validate**: The framework checks if the entity is valid and not locked by someone else.
4.  **Authoritative Save**: `Data` is updated with `Pending` values.
5.  **Visual Sync**: `ApplyChanges(changes)` is called.
6.  **Broadcast**: (Server) Replicated fields are sent to clients.

> [!NOTE]
> `UpdateEntity` returns `false` if:
> - The entity is destroyed (`IsValid == false`).
> - The entity is locked by another `callerId`.
> - There are no pending changes.
> - The entity is "immutable" (subclass didn't override `ApplyChanges`).

---

### 🔒 Locking (Concurrency)

Use `AcquireLock(id)` if you want to ensure no other system mutates your entity while you're performing a multi-step operation (like a long animation or a sequenced trade).

```lua
if entity:AcquireLock("AnimationSystem") then
   entity.IsAnimating = true
   entity:UpdateEntity("AnimationSystem")
   
   task.wait(2)
   
   entity.IsAnimating = false
   entity:UpdateEntity("AnimationSystem")
   entity:ReleaseLock("AnimationSystem")
end
```

---

Notes:

- `UpdateEntity(...)` will fast-fail (and log) if there are no pending changes, if the entity is destroyed, if the caller doesn’t hold the lock (when locked), or if the entity is “immutable” (i.e. `ApplyChanges` was not overridden / made mutable).
- On the server, Orchestrator listens to `entity.StateUpdated` and replicates only schema keys with `Replicate = true`.
- Signals/events (these are `Signal` instances from this library):
    - `entity.StateUpdated:Fire(changes)` where `changes: { [string]: any }`
    - `entity.Destroyed:Fire()`
- Context shortcut: the entity is callable. `entity({ SomeKey = SomeValue })` stores values into its internal Context table (non-schema data).

## 💾 Persistence Setup

Entities can automatically Save/Load from DataStores.

Use persistence when you want state to survive server restarts (e.g. world objects, player-owned structures, long-running jobs). Persistence is server-side only.

1. **Mark Schema for Persistence**: Set `Persist = true` in the property definition.
2. **Enable in Orchestrator**:

```lua
Orchestrator.CreateEntity({
    EntityClass = DoorEntity,
    Persistent = true,
    PersistenceKey = "WorldDoor_01",
})
```
