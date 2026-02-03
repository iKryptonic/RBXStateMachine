# API: Signal

The **Signal** class is a custom, lightweight event system.

---

## 🔧 Core Methods

### `Connect(handler)`
*   **Parameters**: `handler` (function).
*   **Return**: `Connection` object with a `:Disconnect()` method.

### `Once(handler)`
*   **Summary**: Auto-disconnects after the first fire.

### `Fire(...args)`
*   **Summary**: Invokes all listeners using `task.spawn()`.
*   **Parameters**: `...` (any arguments).

### `Wait()`
*   **Summary**: Yields the current thread until the signal is fired.
*   **Return**: The arguments from the fire call.

### `Destroy()`
*   **Summary**: Disconnects all listeners and invalidates the signal.

---

## 🧼 Cleanup Pattern
To avoid memory leaks, either discard connections manually or use the framework's managed system:
```lua
self:Manage(signal:Connect(function() ... end))
```
