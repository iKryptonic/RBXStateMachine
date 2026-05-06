# Copilot instructions for ServiceManager

## Project overview

ServiceManager is a Roblox framework for orchestrating **Entities**, **Finite State Machines (FSMs)**, **Behavior Trees (BTs)**, and a **Scheduler**, with the **ServiceManager** diagnostic dashboard layered on top. The core runtime lives under `src/ReplicatedStorage/Orchestrator/`; user-authored gameplay types live under `src/ReplicatedStorage/StateMachines/` and `src/ReplicatedStorage/Entities/`; the dashboard and its 267-test suite live under `src/ReplicatedStorage/Orchestrator/ServiceManager/`.

Use this repository like a framework codebase, not a loose collection of scripts: favor extending framework primitives over ad-hoc task spawning or one-off state logic.

## Architecture

- **Factory pattern**: `Orchestrator` delegates to `Factory` to compile, create, and register Entities and StateMachines.
- **Registry**: active Entities and FSMs are tracked in `Factory.Registry`.
- **Scheduler heartbeat**: `Orchestrator` disables the internal FSM loop and schedules `GlobalStateMachineHeartbeat`, which calls `BaseStateMachine.Step(dt)` on every Heartbeat tick.
- **NetworkManager**: owns remotes, request/response callbacks, entity replication, command dispatch, and dashboard network stats.
- **ServiceManager**: debug GUI in `src/ReplicatedStorage/Orchestrator/ServiceManager/` with 9 subsystem tabs (`TASKS`, `FSM`, `ENTITY`, `NETWORK`, `DATASTORE`, `INSIGHTS`, `CONSOLE`, `LOGS`, `PROFILER`) and a **Z-axis navigator** for drill-down layers.

## Key code locations

- `src/ReplicatedStorage/Orchestrator/Core/Factory/BaseStateMachine.luau`
- `src/ReplicatedStorage/Orchestrator/Core/Factory/BaseEntity.luau`
- `src/ReplicatedStorage/Orchestrator/Core/Factory/BehaviorTree.luau`
- `src/ReplicatedStorage/Orchestrator/Core/Scheduler/init.luau`
- `src/ReplicatedStorage/Orchestrator/Core/NetworkManager.luau`
- `src/ReplicatedStorage/StateMachines/TrafficLightFSM.luau`
- `src/ReplicatedStorage/StateMachines/DoorFSM.luau`
- `src/ReplicatedStorage/Entities/Door.luau`
- `src/ReplicatedStorage/Orchestrator/ServiceManager/init.luau`
- `src/ReplicatedStorage/Orchestrator/ServiceManager/ServiceBrain.luau`
- `src/ReplicatedStorage/Orchestrator/ServiceManager/Subsystems/ProfilerModule.luau`
- `src/ReplicatedStorage/Orchestrator/ServiceManager/Tests/`

## ServiceManager boot API

Prefer booting the dashboard through `Orchestrator` instead of requiring the ServiceManager module directly in gameplay boot scripts:

```luau
Orchestrator:StartServiceManager()
```

## Preferred framework patterns

### FSM function states

Use function states for compact state handlers:

```luau
self:AddState("Name", function(fsm)
    -- state logic
end, {"ValidOutcomes"})
```

Example patterns exist in `TrafficLightFSM.luau` and `DoorFSM.luau`.

### FSM object states

Use object states when you need lifecycle hooks, declarative transitions, or timeouts:

```luau
self:AddState("Name", {
    OnEnter = function(fsm) end,
    OnHeartbeat = function(state, fsm, dt) end,
    OnLeave = function(state, fsm) end,
    Transitions = {
        {
            Condition = function(fsm, dt) return false end,
            TargetState = "OtherState",
        },
    },
    Timeout = 5,
    OnTimeout = "Failed",
})
```

See `RequestFSM.luau` and `BaseStateMachine.luau` timeout support.

### Entity schema definitions

Define entities as schema-backed extensions of `BaseEntity`:

```luau
local MyEntity = BaseEntity.Extend({
    className = "Door",
    schema = {
        IsOpen = { Type = "boolean", Replicate = true },
    },
})
```

In this codebase the concrete modules commonly use `Name`/`Schema` fields in the returned definition table, and the Factory compiles them into framework subclasses. Follow the existing entity module style used by `src/ReplicatedStorage/Entities/Door.luau`.

### Behavior trees

Compose decision logic with BT nodes instead of manual nested conditionals:

```luau
BT.Sequence({
    BT.Condition(function(ctx) return ctx.Ready end),
    BT.SetState("Processing"),
})
```

Examples:
- `src/ReplicatedStorage/Orchestrator/Core/DataStore/RetryBehavior.luau`
- `src/ReplicatedStorage/Orchestrator/ServiceManager/ServiceBrain.luau`

### Timed transitions

For FSM timing, use framework-native transitions:

```luau
fsm:ScheduleTransition(seconds, "TargetState")
```

**Do not use `task.delay` for FSM state timing.** `ScheduleTransition` is tied to `StateDuration`, cancels automatically on state change, and is the supported pattern in `BaseStateMachine`.

### Polling and re-entry

For rate-limited self-reentry, use:

```luau
fsm.WaitSpan = 0.5
```

This is the intended pattern for polling loops like `DoorFSM`.

## Coding conventions

- Use `--!strict` in Luau modules.
- Keep the existing doc-header style:
  - `@Name`
  - `@Author`
  - `@Description`
- Prefer function docs with:
  - `@param`
  - `@return`
  - `@reads`
  - `@writes`
- Match existing framework naming and table shapes instead of introducing a second style.
- Preserve serializable/sanitized data in networked or dashboard-facing code.
- Prefer extending framework modules over hand-rolled state, cleanup, or replication logic.

## Testing conventions

- Test framework lives in `src/ReplicatedStorage/Orchestrator/ServiceManager/Tests/TestRunner.luau`.
- Specs live in `src/ReplicatedStorage/Orchestrator/ServiceManager/Tests/Specs/*.spec.luau`.
- Register specs with:

```luau
TR.register(spec)
```

- `RunAllTests.luau` loads all spec modules and calls `TestRunner.loadAndRun()`.
- The current suite contains **267 tests** across dashboard/framework specs.

## Anti-patterns to avoid

- Using `task.delay` for FSM transitions.
- Yielding inside **Priority 1** FSM work. `BaseStateMachine.Step()` runs priority-1 updates inline.
- Replacing `fsm.Context` with a non-table value.
- Calling `AddState` after `:Start()`.
- Instantiating entities with `BaseEntity.new` directly. Use `Factory.CreateEntity(...)` / `Orchestrator.CreateEntity(...)`.
- Bypassing the Factory/Registry when creating FSMs.
- Breaking schema validation or replication contracts with arbitrary writes.

## Dashboard guidance

`ServiceManager` is not a simple tab UI. It is a layered diagnostic tool with root subsystems plus Z-axis drill-down panels. Preserve:

- 9 subsystem tabs: `TASKS`, `FSM`, `ENTITY`, `NETWORK`, `DATASTORE`, `INSIGHTS`, `CONSOLE`, `LOGS`, `PROFILER`
- root-layer registration in `src/ReplicatedStorage/Orchestrator/ServiceManager/init.luau`
- breadcrumb + back-navigation behavior
- live/server snapshot dual-context behavior
- click-through drill-downs built with `ZAxisNavigator:ExpandLayer(...)`

When editing dashboard code, keep row builders, detail layers, store updates, and drill-down context objects in sync.

## Practical contribution hints for Copilot

- When adding a new FSM, mirror `TrafficLightFSM` or `RequestFSM` patterns.
- When adding a new entity, mirror `Door`/`DoorEntity` patterns and declare schema fields explicitly.
- When touching Network or dashboard code, check both client mode and server snapshot mode.
- When touching FSM internals, verify `ScheduleTransition`, `WaitSpan`, transition history, and cleanup behavior still work.
- When touching dashboard subsystems, consider whether tests should be added under `src/ReplicatedStorage/Orchestrator/ServiceManager/Tests/Specs/`.
