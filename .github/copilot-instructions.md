# iKrypto instructions for ServiceManager

## Project overview

ServiceManager is a Roblox framework for orchestrating **Entities**, **Finite State Machines (FSMs)**, **Behavior Trees (BTs)**, and a **Scheduler**, with the **ServiceManager** diagnostic dashboard layered on top. The core runtime lives under `src/ReplicatedStorage/Orchestrator/`; user-authored gameplay types live under `src/ReplicatedStorage/StateMachines/` and `src/ReplicatedStorage/Entities/`; the dashboard and its 267-test suite live under `src/ReplicatedStorage/Orchestrator/ServiceManager/`.

Use this repository like a framework codebase, not a loose collection of scripts: favor extending framework primitives over ad-hoc task spawning or one-off state logic.

## Architecture

- **Factory pattern**: `Orchestrator` delegates to `Factory` to compile, create, and register Entities and StateMachines.
- **Registry**: active Entities and FSMs are tracked in `Factory.Registry`.
- **Scheduler heartbeat**: `Orchestrator` disables the internal FSM loop and schedules `GlobalStateMachineHeartbeat`, which calls `BaseStateMachine.Step(dt)` on every Heartbeat tick.
- **NetworkManager**: owns remotes, request/response callbacks, entity replication, command dispatch, and dashboard network stats.
- **ServiceManager**: debug GUI in `src/ReplicatedStorage/Orchestrator/ServiceManager/` with 9 subsystem tabs (`TASKS`, `FSM`, `ENTITY`, `NETWORK`, `DATASTORE`, `INSIGHTS`, `CONSOLE`, `LOGS`, `PROFILER`) and a **Z-axis navigator** for drill-down layers.

For gameplay-side repos that embed this framework, common higher-level pipelines include:
- **Inventory pipeline**: Item operations flow through `InventoryItemFSM` (master job with Add/Remove/Drop/Move branches). Equip/unequip operations use dedicated `EquipJob`/`UnEquipJob` FSMs which handle physical instance operations (weld, mount, stow/drop).
- **Crowd control pipeline**: Stun/Knockdown/future CC types flow through `CrowdControlFSM` (master job parameterized by `Operation`).

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

For gameplay-side integrations that live alongside the framework, also check:
- `FSM/StateMachines/InventoryItemFSM.luau` — master inventory operations
- `FSM/StateMachines/CrowdControlFSM.luau` — master CC operations  
- `FSM/StateMachines/EquipJob.luau` — equipment mounting/unmounting
- `FSM/StateMachines/LoadPlayerJob.luau` — player lifecycle + command registration
- `FSM/Entities/PlayerEntity.luau` — persistent player data
- `FSM/Entities/CharacterEntity.luau` — runtime character state
- `FSM/Helpers/` — shared combat/entity/intent helpers

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

### Master Job pattern (operation-branch FSM)

When multiple FSMs share the same lifecycle but differ only in which fields they touch or what operation they perform, consolidate them into a single **Master Job** with an `Operation` context field that routes to the correct branch:

```luau
local InventoryItemFSM = {
    Name = "InventoryItemFSM",
    className = "InventoryItemFSM",
    validStates = {
        "Validate", "RouteBranch",
        -- Add branch
        "CheckCapacity", "AddToInventory",
        -- Remove branch
        "FindItem", "RemoveFromInventory",
        -- Drop branch
        "CheckIfEquipped", "UnequipIfNeeded", "SpawnWorldItem",
        -- Move branch
        "ResolveSource", "MoveItem",
        -- Shared
        "Commit", "Completed", "Failed",
    },
    terminalStates = { "Completed", "Failed" },
    initialState = "Validate",
}

function InventoryItemFSM:RegisterStates()
    self:AddState("Validate", { ... }, {"RouteBranch", "Failed"})

    self:AddState("RouteBranch", {
        OnEnter = function(_, fsm)
            local op = fsm.Operation
            if op == "Add" then fsm.State = "CheckCapacity"
            elseif op == "Remove" then fsm.State = "FindItem"
            elseif op == "Drop" then fsm.State = "CheckIfEquipped"
            elseif op == "Move" then fsm.State = "ResolveSource"
            else fsm:Fail("Unknown operation: " .. tostring(op)) end
        end,
    }, {"CheckCapacity", "FindItem", "CheckIfEquipped", "ResolveSource", "Failed"})

    -- Each branch defines its own states, all converging on "Commit"
end
```

**When to use this pattern:**
- Multiple FSMs share validation, commit, and cleanup states
- The core difference is a flag, field name, or operation type
- Examples: `InventoryItemFSM` (Add/Remove/Drop/Move), `CrowdControlFSM` (Stun/Knockdown/Silence)

**When NOT to use this pattern:**
- FSMs have fundamentally different state graphs (e.g., EquipJob vs DamageJob)
- The merged FSM would exceed ~500 lines and become hard to navigate
- The operations don't share validation or commit logic

**Spawning a master job:**
```luau
Orchestrator.CreateStateMachine({
    StateMachineClass = "InventoryItemFSM",
    StateMachineId = "Inv_Add_" .. os.clock(),
    Context = {
        Operation = "Add",
        PlayerEntityId = playerEntityId,
        ItemId = itemId,
    },
})
```

### Testing mandate
All new FSMs and entity modifications MUST include corresponding mock tests.
- Test file naming: `{FSMName}.mock.spec.luau` in `FSM/Orchestrator/ServiceManager/Tests/Specs/`
- Minimum coverage per FSM: happy path, validation failures, resource insufficiency, lock contention
- Use `MockFramework` for all FSM tests — never depend on live Roblox services in unit tests

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

## Mock framework usage

Use `FSM/Orchestrator/ServiceManager/Tests/MockFramework.luau` to build deterministic FSM unit tests with mock entities, a mock orchestrator, transition capture, and frame stepping.

```luau
local TR = require(script.Parent.Parent.TestRunner)
local MockFramework = require(script.Parent.Parent.MockFramework)

local TestFSM = {
    Name = "TestFSM",
    className = "TestFSM",
    validStates = { "Validate", "Execute", "Completed", "Failed" },
    terminalStates = { "Completed", "Failed" },
    initialState = "Validate",
}

function TestFSM:RegisterStates()
    self:AddState("Validate", {
        OnEnter = function(_, fsm)
            local entity = fsm:GetEntity(fsm.EntityId)
            if not entity then
                fsm:Fail("Entity not found")
                return
            end
            if not entity:AcquireLock(fsm.Id) then
                fsm:Fail("Lock contention")
                return
            end
            fsm.Context._entity = entity
            fsm.State = "Execute"
        end,
    }, { "Execute", "Failed" })

    self:AddState("Execute", {
        OnEnter = function(_, fsm)
            local entity = fsm.Context._entity
            entity.Value = 10
            entity:UpdateEntity(fsm.Id)
            entity:ReleaseLock(fsm.Id)
            fsm:GetOrchestrator():ServerCommandEntity(entity.EntityId, "SyncValue", entity.Value)
            fsm.State = "Completed"
        end,
    }, { "Completed" })
end

local function spec()
    local describe = TR.describe
    local it = TR.it
    local expect = TR.expect

    describe("TestFSM", function()
        it("records transitions and commands", function()
            local mock = MockFramework.new()
            mock:CreateEntity("ExampleEntity", "Entity_1", { Value = 0 })

            local fsm = mock:CreateFSM(TestFSM, {
                StateMachineId = "FSM_1",
                EntityId = "Entity_1",
            })

            mock:StepFrames(2)

            expect(fsm.State).toEqual("Completed")
            expect(mock.entities.Entity_1.Value).toEqual(10)
            expect(mock:GetTransitions("FSM_1")).toHaveLength(3)
            expect(mock:GetCommands()).toHaveLength(1)
        end)

        it("supports lock-contention tests", function()
            local mock = MockFramework.new()
            local entity = mock:CreateEntity("ExampleEntity", "Entity_2", { Value = 0 })
            entity:SetLockBehavior(false)

            local fsm = mock:CreateFSM(TestFSM, {
                StateMachineId = "FSM_2",
                EntityId = "Entity_2",
            })

            mock:StepFrames(1)

            expect(fsm.State).toEqual("Failed")
        end)
    end)
end

TR.register(spec)
return spec
```

Key API surface:
- `MockFramework.new()` → creates `entities`, `stateMachines`, `transitions`, `commands`
- `mock:CreateEntity(className, entityId, initialData)` → mock BaseEntity-like proxy
- `mock:GetOrchestrator():RegisterModule(name, module)` → inject shared module dependencies
- `mock:CreateFSM(fsmClass, context)` → compiles/starts a real FSM with mock orchestrator injection
- `mock:StepFrames(count)` → advances `BaseStateMachine.Step(1/60)` deterministically
- `mock:GetTransitions(fsmId?)` / `mock:GetCommands()` / `mock:Reset()` → assert and clean up

## Anti-patterns to avoid

- Using `task.delay` for FSM transitions.
- Yielding inside **Priority 1** FSM work. `BaseStateMachine.Step()` runs priority-1 updates inline.
- Replacing `fsm.Context` with a non-table value.
- Calling `AddState` after `:Start()`.
- Instantiating entities with `BaseEntity.new` directly. Use `Factory.CreateEntity(...)` / `Orchestrator.CreateEntity(...)`.
- Bypassing the Factory/Registry when creating FSMs.
- Breaking schema validation or replication contracts with arbitrary writes.
- Creating multiple near-identical FSMs that differ only in a flag or field name. Use the Master Job pattern instead.
- Treating `UpdateEntity()` returning `false` as a hard failure in cleanup/rollback states. `UpdateEntity` returns `false` for "no pending changes", which is normal during rollback. Log a warning instead of calling `fsm:Fail()`.
- Forgetting to update `playerEntity.Inventory` when equipping/unequipping items. Equip must remove from inventory; unequip must restore.

## Dashboard guidance

`ServiceManager` is not a simple tab UI. It is a layered diagnostic tool with root subsystems plus Z-axis drill-down panels. Preserve:

- 9 subsystem tabs: `TASKS`, `FSM`, `ENTITY`, `NETWORK`, `DATASTORE`, `INSIGHTS`, `CONSOLE`, `LOGS`, `PROFILER`
- root-layer registration in `src/ReplicatedStorage/Orchestrator/ServiceManager/init.luau`
- breadcrumb + back-navigation behavior
- live/server snapshot dual-context behavior
- click-through drill-downs built with `ZAxisNavigator:ExpandLayer(...)`

When editing dashboard code, keep row builders, detail layers, store updates, and drill-down context objects in sync.

## Practical contribution hints for iKrypto

- When adding a new FSM, mirror `TrafficLightFSM` or `RequestFSM` patterns.
- When adding a new entity, mirror `Door`/`DoorEntity` patterns and declare schema fields explicitly.
- When touching Network or dashboard code, check both client mode and server snapshot mode.
- When touching FSM internals, verify `ScheduleTransition`, `WaitSpan`, transition history, and cleanup behavior still work.
- When touching dashboard subsystems, consider whether tests should be added under `src/ReplicatedStorage/Orchestrator/ServiceManager/Tests/Specs/`.

## Documentation Standards

### Function Documentation
Every exported function MUST have a `--[=[` block comment with:
- `@description` — What the function does, edge cases, side effects
- `@param paramName type` — For each parameter
- `@return type` — Return value and when it might be nil
- `@reads` — What state/fields it reads (optional but encouraged)
- `@writes` — What state/fields it modifies (optional but encouraged)

Example:
```lua
--[=[
    @description Deducts mana from the player entity, clamping at zero.
    Returns false if insufficient mana without deducting.

    @param playerEntity any -- The PlayerEntity to deduct from
    @param amount number -- Mana to deduct (must be >= 0)
    @return boolean -- true if deduction succeeded, false if insufficient
    @reads playerEntity.Mana
    @writes playerEntity.Mana
]=]
function ResourceHelpers.deductMana(playerEntity: any, amount: number): boolean
```

### Module Documentation
Every module file MUST have a top-level `--[=[` block comment with:
- `@Name` — Module name
- `@Author` — Author (iKrypto)
- `@Description` — What the module does, who uses it, key invariants

### State Machine Documentation
Every FSM state's OnEnter MUST be preceded by:
- `@state StateName` — State name
- `@description` — What happens on entry
- `@transitions` — Valid next states and conditions
- `@failure` — Error/rollback behavior

### Entity Documentation
Every entity schema field MUST have an inline comment documenting:
- Type, purpose, replication mode, persistence mode

### Test Requirements
- Every Helper module must have a corresponding `.spec.luau` in Tests/Specs/
- Every FSM must have transition tests covering happy path + failure paths
- Tests must use the MockFramework pattern (MockEntity, MockOrchestrator, TransitionRecorder)
- New features must include tests before merging

## Code Style

### Indentation
- Use TABS for indentation (Roblox Studio default)
- Consistent nesting depth

### Naming
- Modules: PascalCase (e.g., `CombatHelpers`, `EquipJob`)
- Functions: camelCase for helpers, PascalCase for module methods
- Constants: UPPER_SNAKE_CASE
- Entity fields: PascalCase (e.g., `EquippedRight`, `TalentSelections`)
- FSM states: PascalCase (e.g., `ValidateRequest`, `CommitState`)

### FSM Patterns
- Terminal states: always `"Completed"` and `"Failed"` (never `"Complete"`)
- State transitions via `fsm.State = "NextState"` (polled, not immediate)
- Use `StateTransitionHelpers.queueRollback(fsm, reason)` for error paths
- Track created Instances with `fsm:TrackInstance(inst, label, trackOnly?)`
- Use `fsm:Manage(resource)` for connections and cleanup functions

### Instance Tracking
- Use `TrackInstance(inst, label)` for Instances that should be destroyed with the FSM
- Use `TrackInstance(inst, label, true)` for Instances that outlive the FSM (monitor only)
- Never create Roblox Instances without either TrackInstance, Manage, or Debris:AddItem
