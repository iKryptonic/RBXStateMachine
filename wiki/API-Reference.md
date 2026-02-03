# API Reference (Cheatsheet)

---

## 🛠️ Orchestrator
*   `CreateEntity(params)` -> `Entity`
*   `CreateStateMachine(params)` -> `FSM`
*   `RegisterCommandHandler(id, cmd, h)` (Server)
*   `RegisterRequestHandler(name, h)` (Server)
*   `SendCommand(id, cmd, ...)` (Client)
*   `Request(name, ...)` (Client)
*   `PoolEntity(id)` / `GetPooledEntity(params)`

## 🧠 StateMachine
*   `Start(params)`
*   `ChangeState(params)` (or `fsm.State = x`)
*   `AddState(name, behavior, outcomes?)`
*   `AddSubMachine(name, class, config)`

## 🛡️ BaseEntity
*   `UpdateEntity(callerId?)` -> `bool`
*   `AcquireLock(callerId)` / `ReleaseLock(id)`
*   `SetContext(key, value)` (or `entity({ k = v })`)

## ⚡ Scheduler
*   `Schedule(params)` -> `Task`
*   `Deschedule(name)`
*   `ExecuteTask(task)`

---

> [!TIP]
> Use the sidebar for detailed parameter definitions for each module.
