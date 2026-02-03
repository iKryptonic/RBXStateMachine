# Getting Started

This page describes the recommended Roblox project layout and the startup sequence.

## Installation & Project Layout

This repo is written for Roblox and is designed around a **Factory + Registry** workflow.

At runtime, `Orchestrator:RegisterComponents()`:

1. Creates `shared.FSM` (and injects Logger/Signal/Scheduler modules into `shared`).
2. Requires the internal Factory (bundled inside Orchestrator).
3. Compiles your registered Entity/StateMachine definitions into classes.
4. Exposes compiled classes in `shared.Entity` and `shared.StateMachine`.

### Minimal Roblox hierarchy (recommended)

- `ReplicatedStorage/SharedModules`
    - `Orchestrator` (ModuleScript **with children**, taken from this repo’s `FSM/Orchestrator` folder)
- `ReplicatedStorage/Entity`
    - `EntityRegistry` (ModuleScript, returns a table)
    - `DoorEntity` (optional ModuleScript, attaches behavior to the compiled class)
    - `SpinningPartEntity` (optional ModuleScript, attaches behavior)
- `ReplicatedStorage/StateMachine`
    - `StateMachineRegistry` (ModuleScript, returns a table)
    - `DoorJob` (optional ModuleScript, attaches behavior)
    - `SpinJob` (optional ModuleScript, attaches behavior)

Notes:

- Folder names are **singular** (`Entity` / `StateMachine`) because the bundled Factory looks up `ReplicatedStorage:FindFirstChild("Entity")` and `ReplicatedStorage:FindFirstChild("StateMachine")`.
- Your `*Registry` modules are the **source of truth** for class definitions.
- The optional `DoorEntity` / `DoorJob` modules are where you attach methods like `ApplyChanges()` and `RegisterStates()`.

### Shared globals created by `RegisterComponents`

- `shared.Entity`: map of Entity classes by module name
- `shared.StateMachine`: map of StateMachine classes by module name
- `shared.Logger`: logger *module* used by core modules (use `shared.Logger.new({ Name = "..." })` to create instances)
- `shared.FSM.Scheduler`: Scheduler *instance* created by `RegisterComponents()`
- `shared.BehaviorTree`: BehaviorTree *module* reference
- `shared.Signal`: Signal *module* reference
- `shared.FSM`: structured snapshot `{ Entities, StateMachines, Orchestrator, Scheduler, BehaviorTree, Logger, Settings, History }`

`RegisterComponents()` creates a scheduler instance for you. A typical setup is:

```lua
Orchestrator:RegisterComponents()

-- FrameBudget is seconds per Step; 0.005 = 5ms.
shared.FSM.Scheduler.Settings.FrameBudget = 0.005
shared.FSM.Scheduler:Start()

-- Optional: expose the admin-gated ServiceManager API (server-only).
shared.FSM.Scheduler:ExposeAPI() -- optional (server-only; admin-gate)
```

### Remotes created by Orchestrator

Orchestrator creates the following remotes in `ReplicatedStorage` (server creates them; client `WaitForChild`s them):

- `ServiceManagerRemote` (`RemoteFunction`): request/response for sync, console commands, and management actions
- `ServiceManagerEvent` (`RemoteEvent`): server-to-client notifications (entity created, state changes, etc.)
- `EntityUpdateRemote` (`RemoteEvent`): server-to-client entity replication updates
- `EntityCommandRemote` (`RemoteEvent`): client-to-server command bus

Important: this framework's built-in networking is **observability + server→client replication**. It also includes a **Command Pattern** for client→server input; see the Orchestrator section for `SendCommand` and `RegisterCommandHandler`.

### Terminology

This project uses **“StateMachine”** as the runtime core class. Some gameplay code calls these **“Jobs”** (e.g. `DoorJob`).

- **Registration**: the current implementation compiles definitions from `ReplicatedStorage/Entity/EntityRegistry` and `ReplicatedStorage/StateMachine/StateMachineRegistry`.
- **Naming**: treat “Jobs” as a naming convention only; registration is driven by the registry tables.
