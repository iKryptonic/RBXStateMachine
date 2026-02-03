# Best Practices & Patterns

This page documents the recommended architectural patterns for building complex systems with RBXStateMachine. These strategies are born from the internal mechanics of the framework.

---

## 🔗 The "Context Pattern" (Linking Brain to Body)

A common question is: *How do I give my FSM access to its Entity?*

### The Strategy
Always use the `Context` parameter during creation. The Orchestrator injects the context into both objects, and the FSM's [Property Shadowing](API-BaseStateMachine#the-property-hierarchy-shadowing) makes access seamless.

```lua
-- In your Spawner Script
local entity = Orchestrator.CreateEntity({ EntityClass = "GuardEntity", ... })

local fsm = Orchestrator.CreateStateMachine({
    StateMachineClass = "GuardAI",
    Context = { 
        Entity = entity,  -- Link here
        TargetPart = workspace.Goal 
    }
})

-- In your FSM Implementation (GuardAI.luau)
function GuardAI:RegisterStates()
    self:AddState("Identify", function(fsm)
        -- 'fsm.Entity' shadow-loads from Context automatically!
        fsm.Entity.IsAlert = true 
        fsm.Entity:UpdateEntity()
        
        print("Moving to:", fsm.TargetPart.Name)
    end)
end
```

---

## 🛡️ Handling Failure & Retries

FSMs can fail for many reasons (Logic errors, targets becoming nil, timeouts).

### 1. The `Failed` Signal
Always listen to the `Failed` signal when spawning critical AI.
```lua
local brain = Orchestrator.CreateStateMachine({ ... })
brain.Failed:Connect(function(reason)
    warn("AI Crashed:", reason)
    -- Logic to respawn or alert a fallback system
end)
```

### 2. Automatic Retries
The Orchestrator provides a helper to "reboot" a crashed machine while preserving its context.
```lua
Orchestrator.RetryStateMachine(fsmId)
```
> [!TIP]
> Use this for "Transient Failures" like a pathfinding task failing because of a temporary obstacle.

---

## 🧊 Avoiding "Mega-States"

If a state function is more than 50 lines long, you are likely working against the framework.

### Recommended Pattern: Sub-Machines
Instead of one giant `Combat` state with 10 `if` statements, use `AddSubMachine`.
*   **Parent**: Combat
*   **Children**: Approaching, Attacking, Retreating.
*   The Parent only cares that the Combat cycle "Completed" or "Failed". It doesn't care *how* the child reached victory.

---

## 📡 Networking Efficiency

### The "Batch Commit" Pattern
Do not call `UpdateEntity()` after every property change. Change all properties first, then commit once.

```lua
-- ❌ BAD (Multiple network packets)
entity.Health = 50
entity:UpdateEntity()
entity.IsDead = true
entity:UpdateEntity()

-- ✅ GOOD (One network packet)
entity.Health = 0
entity.IsDead = true
entity:UpdateEntity()
```

---

## 🧹 Cleanup Zen

Memory leaks in Roblox are often caused by "Zombie Connections".
*   If you create a `RunService.Heartbeat` connection inside a State, **always** use `self:Manage(conn)`.
*   The machine will automatically clean it up if it transitions out (for StateObjects) or if the whole FSM is destroyed.
