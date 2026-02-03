# Debugging & Logging

Debugging asynchronous state machines and network snapshots can be difficult. This guide explains how to use the framework's built-in tools to identify and fix issues.

---

## 📝 The Framework Logger

The `Logger` class is used by all 4 Pillars to record history and provide developer feedback.

### 1. Log Levels
*   **DEBUG**: Internal framework noise (WaitSpan starts, individual packet arrivals).
*   **INFO**: Expected lifecycle events (Entity Created, State Transition).
*   **WARN**: Suboptimal code detections (No 'RegisterStates' implemented, Throttled DataStore call).
*   **ERROR**: Critical failures (Type mismatch in schema, Illegal transition).

### 2. Filtering Logs
You can control the verbosity of the framework during the bootstrap phase:
```lua
local FSM = require(ReplicatedStorage.Packages.RBXStateMachine)
-- Setting LogLevel to ERROR (3) will hide INFO and WARN messages.
FSM.Settings.FSMSettings.LogLevel = 3 
```

### 3. Using the Logger in your Code
Your StateMachines and Entities have a `.Logger` property. Use it to keep your logs organized by source.
```lua
function MyAI:OnEnter(fsm)
    fsm.Logger:Log({ 
        Level = "INFO", 
        Message = "AI has detected a target",
        Data = fsm.Target -- Optional metadata
    })
end
```

---

## 🛠️ Debugging Strategies

### 1. The "Ghost Entity" Bug
**Symptom**: You see a part in the workspace, but `Orchestrator.GetEntity(id)` returns nil.
**Cause**: The entity was destroyed, but the `Instance` wasn't cleaned up (or vice-versa).
**Fix**: Check your `ApplyChanges` for memory leaks and ensure you are using `self:Manage(instance)` if the entity spawns temporary parts.

### 2. The "Stuck FSM" Bug
**Symptom**: The StateMachine is active but `OnHeartbeat` isn't running.
**Cause**: Usually a budget overrun in the **Scheduler**.
**Fix**: 
1.  Increase `FSM.Settings.Scheduler.FrameBudget`.
2.  Enable `WarnOnLongThreadExecutions`.
3.  Look for `while true do` loops in your states that don't yield.

### 3. Transition Loops
**Symptom**: The console is flooded with "Transition: A -> B" logs.
**Cause**: State A immediately transitions to B, and B immediately back to A.
**Fix**: Use `WaitSpan` to force a breather between transitions:
```lua
fsm.WaitSpan = 1
fsm.State = "OtherState"
```

---

## 🖥️ The ServiceManager Console
If you have `StartServiceManagerAPI()` running on the server, you can use a RemoteFunction to query the framework state from the FSM console tool (found in the `tools/` folder).

It provides:
*   **Live Graphs**: See which state is currently active.
*   **Memory Usage**: Monitor the number of active vs pooled entities.
*   **Scheduler Throughput**: See how much of your frame budget is being consumed in real-time.
