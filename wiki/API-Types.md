# API: Types

This page lists the core Luau types and interfaces used throughout the framework. These types are exported by `FSM/Orchestrator/Types.luau`.

---

## 🧾 Core Types

### `PropertyDef`
Defines a field in an Entity's Schema.
```lua
type PropertyDef = {
    Type: string,       -- Luau type (e.g., "number", "Instance")
    Description: string?,
    Replicate: boolean?,-- Sync to clients?
    Persist: boolean?   -- Save to DataStore?
}
```

### `LogLevel`
```lua
type LogLevel = "INFO" | "WARN" | "ERROR" | "DEBUG"
```

### `BehaviorTreeStatus`
```lua
type BehaviorTreeStatus = "Success" | "Failure" | "Running"
```

---

## 🧠 StateMachine Types

### `StateObject`
A more advanced way to define a state with lifecycle methods.
```lua
type StateObject = {
    OnEnter: (fsm: any, ...any) -> (),
    OnHeartbeat: ((fsm: any, dt: number) -> ())?,
    OnLeave: ((fsm: any) -> ())?,
    Transitions: { Transition }?,
}
```

### `Transition`
Automatic evaluation rules for `StateObject`.
```lua
type Transition = {
    TargetState: string,
    Condition: (fsm: any, dt: number) -> boolean
}
```

### `SubStateConfig`
Config for hierarchical machines (`AddSubMachine`).
```lua
type SubStateConfig = {
    InitialState: string,
    Transitions: {
        OnCompleted: string,
        OnFailed: string,
        OnCancelled: string?
    },
    StoreReference: string? -- Optional Context key
}
```

---

## ⚡ Scheduler Types

### `Task`
A runtime task managed by the Scheduler.
```lua
type Task = {
    Name: string,
    Action: () -> (),
    NextRun: number,
    Delay: number,
    IsRecurringTask: boolean,
    Priority: number,
    Event: string, -- e.g. "Heartbeat"
    -- Performance Stats
    RunCount: number,
    TotalRunTime: number,
    MaxRunTime: number,
    CreationTime: number,
}
```

### `ScheduleTaskParams`
```lua
type ScheduleTaskParams = {
    TaskName: string,
    TaskAction: () -> (),
    TaskExecutionDelay: number?,
    IsRecurringTask: boolean?,
    Priority: number?,
    Event: string?
}
```

---

## 💾 Persistence Types

### `PersistenceConfig`
```lua
type PersistenceConfig = {
    DataStoreName: string,
    Scope: string?,
    KeyPrefix: string?,
    EnableRetry: boolean?,
    RetryConfig: RetryConfig?,
}
```

### `RetryConfig`
```lua
type RetryConfig = {
    enabled: boolean?,
    retries: number?,
    baseDelay: number?,
    jitter: number?,
}
```
