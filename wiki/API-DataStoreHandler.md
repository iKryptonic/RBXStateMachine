# API: DataStoreHandler

A safe wrapper for Roblox `DataStoreService` with built-in protection against common API errors.

---

## 🛡️ Safeguards

### 1. The 7-Second Throttle
*   Prevents `SetAsync` or `UpdateAsync` on the same key within 7 seconds of the last write.
*   **Result**: Returns `false, nil, "Throttled"` instead of erroring the script.

### 2. Exponential Backoff
*   Retries failed network calls up to 5 times with increasing delays and random jitter.

---

## 🔧 Methods

### `get(name, scope?, ordered?)`
*   **Return**: `DataStoreWrapper`

### `DataStoreWrapper:GetAsync(key)`
*   **Summary**: Fetches a value. Returns cached data if within TTL.

### `DataStoreWrapper:SetAsync(key, value)` / `UpdateAsync(key, fn)`
*   **Summary**: Authoritative write. Enforces 7s throttle.

---

## ⚙️ Configuration

*   **`EnableRetry(bool)`**: Toggle auto-retries.
*   **`SetCachingTime(seconds)`**: Set TTL for read cache.
