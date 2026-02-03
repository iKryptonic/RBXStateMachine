# API: Types (Technical Reference)

This page provides the full technical specification for the Luau types exported by the framework.

---

## 🧾 Foundation Types

### `LogLevel`
```lua
type LogLevel = "INFO" | "WARN" | "ERROR" | "DEBUG"
```

### `Disposable`
```lua
type Disposable = 
    Instance | 
    RBXScriptConnection | 
    { Destroy: (any) -> () } | 
    () -> () 
```

---

## 🏛️ Entity Schema Types

### `PropertyDef`
Defines a single field in an Entity Registry.
```lua
type PropertyDef = {
    Type: string,       -- Luau/Roblox type (e.g. "number", "Vector3", "Part")
    Description: string?, 
    Replicate: boolean?, -- Sync S -> C
    Persist: boolean?    -- Save to DataStore
}
```

---

## 🧠 StateMachine Types

### `StateObject`
```lua
type StateObject = {
    OnEnter: (fsm: any, ...any) -> (),
    OnHeartbeat: ((fsm: any, dt: number) -> ())?,
    OnLeave: ((fsm: any) -> ())?,
    Transitions: { Transition }?, 
}
```

### `Transition`
```lua
type Transition = {
    TargetState: string,
    Condition: (fsm: any, dt: number) -> boolean
}
```

### `SubStateConfig`
```lua
type SubStateConfig = {
    InitialState: string,
    Transitions: {
        OnCompleted: string,
        OnFailed: string,
        OnCancelled: string?
    },
    StoreReference: string?
}
```

---

## ⚡ Scheduler Types

### `Task`
```lua
type Task = {
    Name: string,
    Action: () -> (),
    NextRun: number,
    Delay: number,
    IsRecurringTask: boolean,
    Priority: number,
    Event: string,
    RunCount: number,
    TotalRunTime: number,
    MaxRunTime: number,
    CreationTime: number,
    Reset: () -> ()
}
```

---

## 💾 Persistence Config

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
