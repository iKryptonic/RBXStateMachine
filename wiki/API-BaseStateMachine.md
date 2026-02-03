# API: BaseStateMachine

Derived from the in-repo cheatsheet (`FSM/README.md`).

## 🧠 BaseStateMachine

The behavioral controller (FSM/HFSM).

A StateMachine drives *behavior over time*. It runs inside a shared Heartbeat loop and transitions between named states.

Use a StateMachine when you have multi-step logic that benefits from explicit phases and transitions (quests, jobs, AI, door opening sequences, crafting pipelines). Sub-machines (`AddSubMachine`) let you build hierarchical flows (HFSM) without losing readability.

State representation:

- A state can be a **function** (legacy style) or a **table/object** with methods like `OnEnter`, `OnHeartbeat`, `OnLeave` and optional transition conditions.
- `validOutcomes` provides a safety net so that “illegal” transitions are rejected early and logged.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `new` | `(params: { Id: string, Name: string, ValidStates: { string }?, TerminalStates: { string }?, Context: any?, Priority: number? }): FSM` | Low-level constructor used by `.Extend(...)` subclasses and tests. |
| `Extend` | `(def: { className: string, validStates: { string }?, terminalStates: { string }?, context: table?, Priority: number? }): class` | Creates a new StateMachine class template. |
| `AddState` | `(name: string, state: function|table, validOutcomes: { string }?): ()` | Registers a state and optional legal transition list. |
| `AddSubMachine` | `(name: string, subMachineClass: any, config: { InitialState: string, Transitions: { OnCompleted: string, OnFailed: string, OnCancelled: string? }, StoreReference: string? }): ()` | Registers a hierarchical sub-machine state. |
| `Manage` | `(obj: any): any` | Registers an object for cleanup. |
| `Start` | `(params: { State: string, Args: { any }? }): ()` | Begins execution (registers into global tick loop). |
| `ChangeState` | `(params: { Name: string, Args: { any }? }): ()` | Transitions to a new state (or set `fsm.State = "..."`). |
| `Finish` | `(): ()` | Stops the machine with Completed status. |
| `Fail` | `(reason: string): ()` | Stops the machine with Failed status. |
| `Cancel` | `(): ()` | Stops the machine with Cancelled status. |
| `Destroy` | `(): ()` | Tears down the machine and disconnects managed resources. |
| `Log` | `(params: { Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string, Data: any? }): ()` | Records a log entry into machine history. |
| `RegisterStates` | `(): ()` | Virtual method; override in subclasses to call `AddState/AddSubMachine`. |
| `OnCleanup` | `(): ()` | Virtual method; called during teardown. |

Signals/events (these are `Signal` instances from this library):

- `fsm.Completed:Fire()`
- `fsm.Failed:Fire(reason: string)`
- `fsm.Cancelled:Fire()`
- `fsm.StateChanged:Fire(newState: string, oldState: string?)`

### 🧠 State Types

#### 1. Function State (Simple)
Best for fire-and-forget or instant logic.
```lua
fsm:AddState("Idle", function(fsm, arg1)
    print("Entered Idle with", arg1)
    fsm.State = "Patrol" -- Immediate transition
end)
```

#### 2. StateObject (Advanced)
Best for logic that needs to run every frame or handle complex entry/exit.
```lua
fsm:AddState("Patrol", {
    OnEnter = function(self, fsm) 
        fsm.WaitSpan = 5 -- Stay here for 5s
    end,
    OnHeartbeat = function(self, fsm, dt)
        -- Move towards next waypoint
    end,
    OnLeave = function(self, fsm)
        -- Cleanup navigation paths
    end,
    Transitions = {
        { TargetState = "Chase", Condition = function(fsm) return fsm.CanSeePlayer end }
    }
})
```

---

### ⏳ The `WaitSpan` System

`fsm.WaitSpan` is a built-in timer for state transitions. 

- When you set `fsm.WaitSpan = 5`, the machine will **block** all state transitions for 5 seconds.
- Once the timer expires, the machine evaluates its next move (e.g., an automatic transition).
- `WaitSpan` is automatically reset to `0` whenever `ChangeState` is successfully called.

---

### 🔗 Sub-Machines (HFSM)

Use `AddSubMachine` to delegate logic to another class. The parent FSM will "pause" its own logic and wait for the child to finish.

```lua
fsm:AddSubMachine("Cleaning", RobotCleaningJob, {
    InitialState = "Mop",
    Transitions = {
        OnCompleted = "Recharge", -- If sub-fsm calls :Finish()
        OnFailed = "ErrorState",    -- If sub-fsm calls :Fail()
    },
    StoreReference = "ActiveJob" -- Access child via fsm.ActiveJob
})
```

---

### ⚖️ Priorities

Defines how often `_Update(dt)` runs. Lower values = higher frequency.

| Level | Value | Usage |
| :--- | :--- | :--- |
| **Render** | 1 | UI, Smooth Camera, Visual Effects |
| **High** | 2 | Fast-paced combat AI |
| **Medium** | 5 | Standard NPC behavior (Default) |
| **Low** | 10 | Background environment logic |
| **Background**| 30 | Telemetry, infrequent polling |

---

### Extend vs new

- Use `BaseStateMachine.Extend(def)` to define a reusable **class template** (attach `RegisterStates`, `OnCleanup`, helpers). This is what the Factory/Registry compiles and exposes as `shared.StateMachine.*`.
- Use `BaseStateMachine.new(params)` to construct the base runtime directly (good for one-offs/tests), but you don’t get a registry-friendly class table unless you wrap it yourself.
