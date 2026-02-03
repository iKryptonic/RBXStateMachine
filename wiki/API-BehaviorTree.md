# API: BehaviorTree

Derived from the in-repo cheatsheet (`FSM/README.md`).

## 🌳 BehaviorTree

A functional, lightweight implementation for complex AI logic.

Behavior trees are great for AI or decision logic where you want composable “try this, else that” behavior. This implementation is functional: each node returns a function that takes a `context` and returns a `BehaviorTreeStatus`.

Constants:

- `BehaviorTree.BehaviorTreeStatus = { Success = "Success", Failure = "Failure", Running = "Running" }`
- `BehaviorTreeStatus = "Success" | "Failure" | "Running"`

| Method | Signature | Description |
| :--- | :--- | :--- |
| `Selector` | `(children: { (context: any) -> BehaviorTreeStatus }): (context: any) -> BehaviorTreeStatus` | Runs children until one succeeds. |
| `Sequence` | `(children: { (context: any) -> BehaviorTreeStatus }): (context: any) -> BehaviorTreeStatus` | Runs children until one fails. |
| `Inverter` | `(child: (context: any) -> BehaviorTreeStatus): (context: any) -> BehaviorTreeStatus` | Inverts Success/Failure (Running is unchanged). |
| `Succeeder`| `(child: (context: any) -> BehaviorTreeStatus): (context: any) -> BehaviorTreeStatus` | Always returns Success (unless Running). |
| `Condition`| `(predicate: (context: any) -> boolean): (context: any) -> BehaviorTreeStatus` | Returns Success/Failure based on a predicate. |
| `SetState` | `(stateName: string): (fsm: any) -> BehaviorTreeStatus` | Utility to change FSM state. Returns Success. |

**Example:**

```lua
local BT = shared.BehaviorTree

local ai = BT.Selector({
    BT.Sequence({
        BT.Condition(function(fsm) return fsm.Health < 20 end),
        BT.SetState("Retreat"),
    }),

    BT.SetState("Attack"),
})
```
