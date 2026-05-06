# Contributing

## Development workflow

1. Open the Rojo project in Roblox Studio.
2. Start **Play** mode.
3. Run the dashboard/framework suite through `ReplicatedStorage.Orchestrator.ServiceManager.Tests.RunAllTests` (source: `src/ReplicatedStorage/Orchestrator/ServiceManager/Tests/RunAllTests.luau`).
4. Make focused changes.
5. Re-run the same tests before submitting.

## Running tests

Preferred in Studio Play mode, require `ReplicatedStorage.Orchestrator.ServiceManager.Tests.RunAllTests`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunAllTests = require(ReplicatedStorage.Orchestrator.ServiceManager.Tests.RunAllTests)
local summary = RunAllTests.run()
print(summary.passed, summary.failed, summary.total)
```

Notes:
- Specs live in `src/ReplicatedStorage/Orchestrator/ServiceManager/Tests/Specs/*.spec.luau`.
- Specs register themselves with `TR.register(spec)`.
- The suite currently covers 267 tests.

## Adding a new FSM

Use `src/ReplicatedStorage/StateMachines/TrafficLightFSM.luau` as the simplest pattern and `src/ReplicatedStorage/Orchestrator/Core/DataStore/FSM/RequestFSM.luau` as the object-state pattern.

Checklist:

1. Create a new module under `src/ReplicatedStorage/StateMachines/`.
2. Return a definition table with `Name`, `ValidStates`, `TerminalStates`, and `InitialState` (or the equivalent compiled shape expected by `Factory`).
3. Implement `RegisterStates()`.
4. Prefer one of these styles:
   - function states via `self:AddState("State", function(fsm) ... end, {"Next"})`
   - object states via `OnEnter` / `OnHeartbeat` / `OnLeave` / `Transitions` / `Timeout`
5. Use `fsm:ScheduleTransition(...)` for timed state changes.
6. Use `fsm.WaitSpan = ...` for polling/re-entry behavior.
7. Create instances via `Orchestrator.CreateStateMachine(...)`, not by manually wiring base classes.
8. If the FSM should appear cleanly in ServiceManager, make sure state names, transitions, and context are dashboard-friendly.

Example runtime creation:

```luau
local fsm = Orchestrator.CreateStateMachine({
    StateMachineClass = "TrafficLightFSM",
    StateMachineId = "TrafficLight_Demo",
    Context = { Cycles = 0 },
})
```

## Adding a new Entity

Use `src/ReplicatedStorage/Entities/Door.luau` as the reference implementation.

Checklist:

1. Create a module under `src/ReplicatedStorage/Entities/`.
2. Define schema fields explicitly (`Type`, `Replicate`, `Persist`, `Description` as needed).
3. Implement `GetContext()` for cached instance references and derived state.
4. Implement `ApplyChanges(changes)` for visual/application logic.
5. Add domain methods like `Open()`, `Close()`, `Reset()`, etc. when appropriate.
6. Create entities through `Orchestrator.CreateEntity(...)` / `Factory.CreateEntity(...)` so Registry, persistence, and replication are wired automatically.
7. Never bypass schema validation with arbitrary fields.

Example runtime creation:

```luau
local entity = Orchestrator.CreateEntity({
    EntityClass = "DoorEntity",
    EntityId = "Door1",
    Context = {
        Instance = workspace.Door1,
        OwnerId = script.Name,
    },
})
```

## Adding a new dashboard subsystem

Use `src/ReplicatedStorage/Orchestrator/ServiceManager/Subsystems/ProfilerModule.luau` as the reference pattern.

Checklist:

1. Add a module under `src/ReplicatedStorage/Orchestrator/ServiceManager/Subsystems/`.
2. Implement the standard subsystem shape:
   - `new()`
   - `FetchData(nexus)`
   - `Render(nexus)` if needed
   - `BuildRootLayer(frame, context)`
   - detail-layer builders for drill-downs
3. Register the subsystem in `src/ReplicatedStorage/Orchestrator/ServiceManager/init.luau`.
4. Add it to the root subsystem list used by `_RegisterRootLayers()`.
5. Write to `ReactiveStore` through stable keys.
6. Use `ZAxisNavigator:ExpandLayer(...)` for drill-downs instead of ad-hoc UI state.
7. If the subsystem needs server data, include it in `ServiceManager.RegisterServerHandlers()` snapshot output.
8. Add/update specs in `src/ReplicatedStorage/Orchestrator/ServiceManager/Tests/Specs/`.

## Code review checklist

Before opening a PR, verify:

- [ ] Luau files use `--!strict` where expected.
- [ ] Headers and function docs follow the `@Name` / `@Author` / `@Description` / `@param` / `@return` / `@reads` / `@writes` style.
- [ ] New FSM timing uses `fsm:ScheduleTransition(...)`, not `task.delay`.
- [ ] Priority-1 FSM work does not yield.
- [ ] `fsm.Context` remains a table.
- [ ] States are registered before `:Start()`.
- [ ] Entities/FSMs are created through `Factory` / `Orchestrator`, not direct base constructors.
- [ ] Replicated or snapshot-facing data is sanitized and stable.
- [ ] ServiceManager dashboard changes preserve Z-axis drill-down behavior and root subsystem registration.
- [ ] Tests were run in Studio Play mode and pass after the change.
