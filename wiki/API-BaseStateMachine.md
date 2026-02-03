# API: BaseStateMachine

The **BaseStateMachine** is the abstract foundation for all logic controllers. It manages time, priority-based updates, and transition safety.

---

## 🏗️ Creation & Registration

### `Extend(extensionParams)`
*   **Summary**: Factory method to create a new FSM class.
*   **Parameters**:
    *   `className` (string): Unique identifier for the class.
    *   `validStates` (table?): List of allowed state names.
    *   `terminalStates` (table?): States that trigger `:Finish()` automatically.
    *   `Priority` (number?): How often the machine ticks.

### `RegisterStates()`
*   **Summary**: **Mandatory override**. Subclasses use this to call `AddState` for every behavior in their machine.

---

## 🔧 Logic & Transitions

### `AddState(name, state, validOutcomes?)`
*   **Parameters**:
    *   `name` (string): Unique ID for the state.
    *   `state` (function | StateObject): The behavior.
    *   `validOutcomes` (table?): Optional list of allowed "Next" states.

### `AddSubMachine(name, subMachineClass, config)`
*   **Summary**: Adds a hierarchical child machine.
*   **Parameters**:
    *   `name` (string)
    *   `subMachineClass` (class)
    *   `config`: `{ InitialState, Transitions: { OnCompleted, OnFailed, OnCancelled }, StoreReference? }`

### `Start(startParams)`
*   **Parameters**: `startParams: { State: string, Args: array? }`

### `ChangeState(params)`
*   **Shortcut**: `fsm.State = "NewName"`.
*   **Parameters**: `params: { Name: string, Args: array? }`.

---

## 🏁 Completion & Teardown

### `Finish() / Fail(reason) / Cancel()`
*   **Summary**: Terminates the machine and fires the corresponding [Signal](API-Signal).

### `Manage(object) / Destroy()`
*   **Summary**: Standard [Cleanup API](API-BaseEntity#cleanup--management).

---

## ⏳ Internal Mechanics: `WaitSpan`

### `fsm.WaitSpan = seconds`
*   When set, the next `ChangeState` call will be **deferred** for the specified time.
*   **Parameter**: `seconds` (number).
*   **Edge Case**: Any new `ChangeState` call within the same thread clears the WaitSpan to ensure deterministic flow control.

---

## 📋 Full Method Inventory

| Method | Role |
| :--- | :--- |
| `Log(params)` | Logging. |
| `_Update(dt)` | Internal Heartbeat (Budgeted). |
| `__index` | Context shadowing logic. |

> [!TIP]
> **Context Shadowing**: You can access variables in `fsm.Context` directly via `fsm.Variable`. The framework checks Context automatically if the key isn't a method or built-in field.
