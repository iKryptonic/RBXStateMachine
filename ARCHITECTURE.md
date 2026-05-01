# Architecture

## Project summary

ServiceManager is a Roblox orchestration framework built around:

- schema-backed **Entities**
- lifecycle-managed **StateMachines**
- composable **Behavior Trees**
- a Heartbeat-driven **Scheduler**
- the **ServiceManager** diagnostic dashboard

## Component diagram

```text
                             ┌──────────────────────────────┐
                             │      ServerScriptService     │
                             │       / StarterPlayer        │
                             │   boot scripts initialize    │
                             │ Orchestrator + ServiceManager  │
                             └──────────────┬───────────────┘
                                            │
                                            v
┌────────────────────────────────────────────────────────────────────────────┐
│                         ReplicatedStorage.Orchestrator                    │
│                                                                            │
│  ┌────────────┐     ┌────────────┐     ┌──────────────┐     ┌───────────┐ │
│  │   Factory  │ --> │  Registry  │ --> │ Base FSM set │ <-- │ Scheduler │ │
│  │ compiles & │     │ tracks live│     │ ActiveMachines│    │ Heartbeat │ │
│  │ instantiates│    │ entities/FSMs│   │ + Step(dt)   │     │ task loop │ │
│  └─────┬──────┘     └─────┬──────┘     └──────┬───────┘     └─────┬─────┘ │
│        │                  │                   │                     │       │
│        v                  v                   v                     v       │
│  ┌────────────┐    ┌──────────────┐    ┌──────────────┐    ┌────────────┐ │
│  │ BaseEntity │    │ StateMachines │    │ BehaviorTree │    │NetworkManager│ │
│  │ schema/data│    │ user FSM defs │    │ reusable BT  │    │ remotes/RPC │ │
│  └────────────┘    └──────────────┘    └──────────────┘    └────────────┘ │
│        ^                                                                     │
│        │                                                                     │
│  ┌────────────┐                                                              │
│  │  Entities  │                                                              │
│  │ user defs  │                                                              │
│  └────────────┘                                                              │
└────────────────────────────────────────────────────────────────────────────┘
                                            │
                                            v
                     ┌─────────────────────────────────────────┐
                     │             ServiceManager              │
                     │ GlassGUI + ReactiveStore + ZAxis       │
                     │ Navigator + Analytics + ServiceBrain   │
                     │ + TASKS/FSM/ENTITY/NETWORK/... tabs    │
                     └─────────────────────────────────────────┘
```

## Core runtime flow

### Factory → Registry → Scheduler → Heartbeat → FSM._Update

```text
1. Boot script calls Orchestrator:RegisterComponents()
2. Orchestrator initializes Factory, NetworkManager, Scheduler, Logger, Signal, Settings
3. Factory compiles Entity and StateMachine modules from ReplicatedStorage folders
4. Orchestrator disables BaseStateMachine's internal loop
5. Scheduler registers GlobalStateMachineHeartbeat on Heartbeat
6. Heartbeat task calls BaseStateMachine.Step(dt)
7. Step(dt) iterates ActiveMachines
8. Each active machine runs _Update(dt)
9. _Update handles:
   - deferred transitions
   - WaitSpan self-reentry
   - ScheduleTransition timers
   - object-state Transitions
   - object-state Timeout / OnTimeout
   - OnHeartbeat callbacks
```

This is why FSM timing should use `ScheduleTransition` or `WaitSpan` instead of unmanaged `task.delay` closures.

## Entity lifecycle

```text
Factory.CreateEntity(...)
  -> resolve compiled class
  -> create schema-backed entity instance
  -> register in Registry
  -> wire persistence and replication
  -> emit StateUpdated / Destroyed events as data changes
```

Key implications:
- entities should be created through `Factory`/`Orchestrator`
- schema fields define validation, persistence, and replication boundaries
- dashboard entity views depend on schema/data staying structured

## State machine lifecycle

```text
Factory.CreateStateMachine(...)
  -> resolve compiled class
  -> instantiate FSM with Context
  -> inject Context.FSM self-reference
  -> register in Registry
  -> connect Completed / Failed / Cancelled cleanup
  -> auto-start unless AutoStart = false
```

State definitions can be:
- function states (`AddState("Name", function(fsm) ... end, outcomes)`)
- object states (`OnEnter`, `OnHeartbeat`, `OnLeave`, `Transitions`, `Timeout`, `OnTimeout`)

## Network and server snapshot pipeline

### Server snapshot pipeline

```text
Server boot
  -> Orchestrator:RegisterComponents()
  -> require ReplicatedStorage.Orchestrator.ServiceManager
  -> ServiceManager.RegisterServerHandlers(Orchestrator)
  -> register RemoteFunction-style request handler:
       "ServiceManager_ServerSnapshot"
  -> capture scheduler/task/FSM/entity/network/datastore state
  -> return serialized snapshot to clients

Client boot
  -> Orchestrator:StartServiceManager()
  -> ServiceManager.Initialize(Orchestrator)
  -> ServiceManager.Show()
  -> _StartServerPolling()
  -> _orchestrator.Request("ServiceManager_ServerSnapshot")
  -> store snapshot in _serverData
  -> subsystem FetchData() reads _serverData in server mode
  -> ZAxisNavigator rebuilds root/detail layers from snapshot-backed store data
```

### Remote/data flow

```text
src/ReplicatedStorage/Orchestrator/ServiceManager/init.luau
  -> Orchestrator.Request("ServiceManager_ServerSnapshot")
  -> NetworkManager RemoteFunction request/response
  -> RegisterServerHandlers snapshot builder
  -> snapshot returned to client
  -> subsystem modules consume serverData
```

`NetworkManager` also owns:
- orchestrator request callbacks
- entity update replication
- entity command dispatch
- event bus statistics
- remote call history shown in the dashboard

## ServiceManager architecture

```text
src/ReplicatedStorage/Orchestrator/ServiceManager/init.luau
  -> initialize ServiceBrain
  -> create ReactiveStore
  -> create AnimationController
  -> create AnalyticsEngine
  -> create subsystem module instances
  -> build GlassGUI
  -> create ZAxisNavigator
  -> register 9 root layers
  -> schedule ServiceManagerBrainTick
  -> start server polling on clients
```

### Dashboard subsystems

Root layers registered in `_RegisterRootLayers()`:

- `TASKS`
- `FSM`
- `ENTITY`
- `NETWORK`
- `DATASTORE`
- `INSIGHTS`
- `CONSOLE`
- `LOGS`
- `PROFILER`

The dashboard uses **Z-axis drill-down navigation** instead of flat page routing. Subsystems build root layers and expandable detail layers through `ZAxisNavigator:ExpandLayer(...)`.

## ServiceBrain behavior tree

`ServiceBrain` is the top-level control flow for the dashboard.

```text
Sequence
├─ Condition: ServiceManager initialized?
├─ Action: SyncContextData
├─ Selector
│  ├─ Sequence (full refresh path)
│  │  ├─ Condition: NeedsDataRefresh?
│  │  ├─ Action: FetchSubsystemData
│  │  ├─ Succeeder: RunInsightAnalysis
│  │  └─ Action: RenderActiveSubsystem
│  ├─ Sequence (dirty UI path)
│  │  ├─ Condition: HasDirtyUI?
│  │  └─ Action: RenderActiveSubsystem
│  └─ Succeeder: UpdateAnimations
└─ Succeeder: UpdateAnimations
```

This keeps dashboard work declarative and composable:
- fetch only when refresh cadence says it is needed
- render immediately when store data is dirty
- always tick animations
- run insight analysis opportunistically

## Why these boundaries matter

- **Factory/Registry** preserve lifetime management and lookup consistency.
- **Scheduler + BaseStateMachine.Step** centralize FSM ticking and perf tracking.
- **NetworkManager** keeps client/server sync observable and dashboard-friendly.
- **ServiceManager** depends on structured snapshots and predictable subsystem contracts.
- **BehaviorTree** lets both gameplay retry logic and dashboard orchestration stay composable instead of deeply nested.
