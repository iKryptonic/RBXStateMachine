# API: DataStoreHandler

Derived from the in-repo cheatsheet (`FSM/README.md`).

## 💾 DataStoreHandler

Thin wrapper around `DataStoreService` with throttling, optional retries, and optional caching.

Use `DataStoreHandler.get(...)` when you want a single place to manage datastore access patterns and error handling. It provides:

- **Built-in Throttling**: Automatically enforces a **7-second cooldown** per key for write operations (`Set`, `Update`, `Increment`, `Remove`) to prevent `6-second` limit errors.
- **Automatic Retries**: Optional exponential backoff for transient Roblox DataStore failures.
- **Read Caching**: Optional TTL-based caching for frequent `GetAsync` calls.

This is used by `EntityPersistence` (and therefore by Orchestrator persistence) to store entity state.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `ResetAccessCount` | `(): ()` | Resets internal access counters (used by Scheduler task). |
| `get` | `(databaseName: string, scope: string?, orderedBool: boolean?): DataStore` | Returns a cached wrapper for a DataStore / OrderedDataStore. |

## DataStore wrapper

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
