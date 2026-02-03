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

Internal (advanced; callable but intended for runtime use):

- `_Update(dt: number): ()` — tick invoked by the shared Heartbeat loop.
- `_Teardown(): ()` — stops the machine and runs cleanup.

**Priorities:** `Render (1)`, `High (2)`, `Medium (5)`, `Low (10)`, `Background (30)`.

Transition rules:

- If `validStates` is provided (registry/class), `AddState` and `ChangeState` will reject unknown state names.
- If a state was registered with a non-empty `validOutcomes` list, transitions out of that state are validated against the list.
- Setting `fsm.State = "SomeState"` triggers `ChangeState({ Name = "SomeState" })` via `__newindex`.

### Extend vs new

- Use `BaseStateMachine.Extend(def)` to define a reusable **class template** (attach `RegisterStates`, `OnCleanup`, helpers). This is what the Factory/Registry compiles and exposes as `shared.StateMachine.*`.
- Use `BaseStateMachine.new(params)` to construct the base runtime directly (good for one-offs/tests), but you don’t get a registry-friendly class table unless you wrap it yourself.
