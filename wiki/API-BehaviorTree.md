# API: BehaviorTree

A functional, lightweight AI decision tree module.

---

## 🔧 Node Types

### Composites
*   **`Selector(children)`**: Succeeds if any child succeeds (OR gate).
*   **`Sequence(children)`**: Succeeds only if all children succeed (AND gate).

### Decorators
*   **`Inverter(child)`**: Flips Failure/Success.
*   **`Succeeder(child)`**: Always returns Success.

### Leaf Actions
*   **`Condition(predicate)`**: Returns Success if `predicate(fsm)` is true.
*   **`SetState(name)`**: Helper to change FSM state.

---

## 🚀 Usage Example

```lua
local soldierBT = BT.Selector({
    BT.Sequence({
        BT.Condition(function(fsm) return fsm.Health < 10 end),
        BT.SetState("Retreat")
    }),
    BT.SetState("Idle")
})

function MyFSM:OnHeartbeat(fsm)
    soldierBT(fsm)
end
```
