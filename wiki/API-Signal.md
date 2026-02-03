# API: Signal

Derived from the in-repo cheatsheet (`FSM/README.md`).

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
