# FiniteStateMachine

**FiniteStateMachine** is a modular, object-oriented framework for building and orchestrating gameplay logic in Roblox.

`BaseStateMachine` is one component of this project (the FSM/HFSM engine). The repo also includes `BaseEntity` (schema + replication-friendly entity pattern), `Scheduler` (frame-budgeted task dispatch), `Logger`, and `Orchestrator` (registry/factory + replication + service remotes).

## Table of Contents
- [Core Features](#core-features)
- [Architecture: The 4 Pillars](#architecture-the-4-pillars)
- [Installation & Project Layout](#installation--project-layout)
- [Registration Guide (Entities & StateMachines)](#registration-guide-entities--statemachines)
- [Quick Start](#quick-start)
- [Architecture Concepts](#architecture-concepts)
- [API Reference](#api-reference)
- [State Definitions](#state-definitions)
- [Hierarchical FSM (HFSM)](#hierarchical-fsm-hfsm)
- [BehaviorTree](#behaviortree)
- [Advanced Patterns](#advanced-patterns)
- [Architectural Patterns](#architectural-patterns)
- [BaseStateMachine](#basestatemachine)
- [BaseEntity](#baseentity)
- [Scheduler](#scheduler)
- [Logger](#logger)
- [Orchestrator](#orchestrator)
- [Tests](#tests)
- [Framework Core](#framework-core)

## Core Features

- **Centralized Loop**: Efficiently manages multiple FSMs using a single `Heartbeat` connection with customizable priority levels (Time-Slicing).
- **Hierarchical FSM (HFSM)**: Natively supports nesting FSMs within states to handle complex logic layers.
- **Resource Tracking**: Automatic cleanup of Instances, Connections, and functions via the `Manage` method.
- **Flexible States**: Supports both simple function-based states (closures) and complex object-oriented states.
- **Context Sharing**: Seamlessly share data between states and sub-machines via a unified `Context` table.

---

## Architecture: The 4 Pillars

The framework integrates the Brain, Body, Pulse, and Nervous System of your project into a single, high-performance lifecycle.

### The Four Pillars of the Framework

The framework is divided into four distinct layers, each handling a specific responsibility.

| Component | Layer | Role | Analog |
| :--- | :--- | :--- | :--- |
| **Orchestrator** | Service | Global Registry & Lifecycle Manager | The Nervous System |
| **BaseStateMachine** | Logic | Behavioral flow and decision making | The Brain |
| **BaseEntity** | Data | State authority and Instance proxy | The Body |
| **Scheduler** | Timing | Async execution and frame budgeting | The Pulse |

### 1. System Bootstrapping (Initialization)

Everything begins with the **Orchestrator**. Upon game start, the Orchestrator performs a "Discovery" phase:

1. It scans your folders for Entity and StateMachine modules.
2. It injects the Scheduler, Logger, and Signal into the shared global space.
3. It creates a network bridge (RemoteFunctions) so that the Server can talk to a debug console on the Client.

### 2. The Spawning Flow (Creation)

When spawning objects, the systems work in a "Body-First, Brain-Second" sequence:

1. **Entity Creation**: `Orchestrator.CreateEntity` creates a proxy for the physical model. It enforces a strict Schema.
2. **Brain Creation**: `Orchestrator.CreateStateMachine` is created to control that entity.
3. **The Link**: The Orchestrator passes the Entity into the Brain's Context. The Brain now has a Body to control.

### 3. The Runtime Loop (Execution)

1. **Decision (Brain)**: The FSM or BT decides on an action (e.g., "Takeoff").
2. **Instruction (Brain -> Body)**: The FSM sets `Entity.Throttle = 100`.
3. **Validation (Body)**: The Entity checks the Schema and saves the value in the `Pending` table.
4. **Transaction (Commit)**: The FSM calls `Entity:UpdateEntity()`.
5. **Execution (Pulse)**: The Scheduler ensures heavy logic stays within the **Frame Budget** (e.g., 5ms), preventing FPS drops.

---

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

Then, at runtime:

1. `Orchestrator:RegisterComponents()` populates `shared.Entity`, `shared.StateMachine`, `shared.Logger`, `shared.FSM.Scheduler`, `shared.Signal`, and `shared.FSM`.
2. Create objects via `Orchestrator.CreateEntity(...)` and `Orchestrator.CreateStateMachine(...)`.

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
-- Installation/bootstrapping example:
-- RegisterComponents compiles registries and initializes shared globals.
Orchestrator:RegisterComponents()

-- Configure the shared Scheduler instance (frame-budgeted task runner).
-- FrameBudget is seconds per Step; 0.005 = 5ms.
shared.FSM.Scheduler.Settings.FrameBudget = 0.005

-- Start scheduler ticking (connects to RunService events).
shared.FSM.Scheduler:Start()

-- Optional: expose the admin-gated ServiceManager API (server-only).
shared.FSM.Scheduler:ExposeAPI() -- optional (server-only; admin-gate)
```

If you want multiple schedulers, create additional instances manually:

```lua
-- Advanced: create an additional, independent Scheduler instance.
-- Use this if you want separate budgets/heaps per subsystem.
local extraScheduler = shared.FSM.Scheduler.new({
    -- Seconds per Step per event.
    FrameBudget = 0.005, -- seconds per Step per event
})

-- Start ticking this scheduler as well.
extraScheduler:Start()
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

Ensure your naming is consistent. “Job” is just a convention for StateMachine class names (e.g., `DoorJob`); the actual registration mechanism is the registry tables under `ReplicatedStorage/StateMachine`.

## Registration Guide (Entities & StateMachines)

This section is the canonical guide for registering and implementing Entities and StateMachines in this project.

### Supported registration modes

You can use any of these (they can be mixed):

1. **Factory + Registries (recommended)**: put definitions in `EntityRegistry` / `StateMachineRegistry`, call `Orchestrator:RegisterComponents()`, and use `shared.Entity.*` / `shared.StateMachine.*`.
2. **String-based lookup**: pass a string name to `Orchestrator.CreateEntity({ EntityClass = "DoorEntity", ... })` or `Orchestrator.CreateStateMachine({ StateMachineClass = "DoorJob", ... })` after registration.
3. **Manual classes**: create classes via `BaseEntity.Extend` / `BaseStateMachine.Extend` and pass the class table directly to `CreateEntity` / `CreateStateMachine` (no registry needed).

### 1) Register an Entity (Factory + Registry)

Create a registry entry in `ReplicatedStorage/Entity/EntityRegistry`.

```lua
-- EntityRegistry example: this is the source-of-truth for an Entity class template.
-- Orchestrator:RegisterComponents() compiles this into shared.Entity.SpinningPartEntity.
return {
    SpinningPartEntity = {
        Name = "SpinningPartEntity",
        Schema = {
            -- Replicated gameplay state
            IsSpinning = { Type = "boolean", Replicate = true, Persist = false },
            Speed = { Type = "number", Replicate = true },

            -- Internal/cache fields MUST be in the schema if you want to assign them
            _spinConn = { Type = "RBXScriptConnection" },
        },
    },
}
```

What the Entity registry controls:

- `Name`: class name
- `Schema`: what properties can be set on the entity proxy (type-checked)
- `Replicate`: whether a server-side change is broadcast to clients by Orchestrator
- `Persist`: whether the property is included in `Serialize()` / persistence saves

### 2) Implement an Entity properly (Attach methods)

The registry defines the **schema**. The behavior (visuals/domain helpers) is attached by adding methods to the compiled class.

Create `ReplicatedStorage/Entity/SpinningPartEntity`:

```lua
-- Entity implementation module example:
-- This attaches behavior (methods) to the compiled class table.
local RunService = game:GetService("RunService")

-- IMPORTANT: the compiled class exists only after Orchestrator:RegisterComponents()
assert(shared.Entity and shared.Entity.SpinningPartEntity, "Call Orchestrator:RegisterComponents() before requiring SpinningPartEntity")
local SpinningPartEntity = shared.Entity.SpinningPartEntity

function SpinningPartEntity:GetContext()
    -- Called by the base constructor; return context to cache instance references.
    -- NOTE: GetContext is optional.
    local inst = self.Instance
    return {
        _spinConn = nil,
        IsSpinning = self.IsSpinning or false,
        Speed = self.Speed or 0,
    }
end

function SpinningPartEntity:ApplyChanges(changes)
    -- ApplyChanges can run on the server (authority commit) and on the client (replication).
    -- Keep client-only visuals guarded.
    if not RunService:IsClient() then return end

    if changes.IsSpinning == false and self._spinConn then
        self._spinConn:Disconnect()
        self._spinConn = nil
        return
    end

    if changes.IsSpinning == true and not self._spinConn then
        self._spinConn = RunService.Heartbeat:Connect(function(dt)
            local speed = self.Speed or 3
            local part = self.Instance
            if part and part:IsA("BasePart") then
                part.CFrame = part.CFrame * CFrame.Angles(0, dt * speed, 0)
            end
        end)
        self:Manage(self._spinConn)
    end
end

-- Optional domain helpers (server-side typically calls these)
function SpinningPartEntity:SetSpinning(isSpinning: boolean, speed: number)
    self.IsSpinning = isSpinning
    self.Speed = speed
    return self:UpdateEntity()
end

return SpinningPartEntity
```

Key “gotchas”:

- Any property you assign (even “private” fields like `_hinge`) must exist in the Schema or it will be rejected.
- `UpdateEntity()` will error-log and return `false` if `ApplyChanges` was never overridden (the entity is considered “immutable”).
- If you want cached instance references, use `GetContext()` + schema entries for those fields.

### 3) Register a StateMachine (Factory + Registry)

Create a registry entry in `ReplicatedStorage/StateMachine/StateMachineRegistry`.

```lua
-- StateMachineRegistry example: defines the StateMachine class template.
-- Orchestrator:RegisterComponents() compiles this into shared.StateMachine.SpinJob.
return {
    SpinJob = {
        className = "SpinJob",
        validStates = { "Idle", "Spin" },
        terminalStates = { },
        context = {
            EntityId = nil,
        },
        Priority = 10, -- Low: run about every 10 frames
    },
}
```

What the StateMachine registry controls:

- `className`: class name
- `validStates` / `terminalStates`: transition safety + auto-finish behavior
- `context`: a template for the Context table (you can also pass extra fields at create-time)
- `Priority`: how often `_Update(dt)` runs (frame-skipping)

### 4) Implement a StateMachine properly (Attach RegisterStates)

Create `ReplicatedStorage/StateMachine/SpinJob`:

```lua
-- StateMachine implementation module example:
-- This attaches RegisterStates/OnCleanup (and any helpers) to the compiled class.
assert(shared.StateMachine and shared.StateMachine.SpinJob, "Call Orchestrator:RegisterComponents() before requiring SpinJob")
local SpinJob = shared.StateMachine.SpinJob

function SpinJob:RegisterStates()
    self:AddState("Idle", {
        OnEnter = function(_, fsm)
            if fsm.Entity then
                fsm.Entity:SetSpinning(false, 0)
            end
            fsm.WaitSpan = 1
            fsm.State = "Spin"
        end,
    }, { "Spin" })

    self:AddState("Spin", {
        OnEnter = function(_, fsm)
            if fsm.Entity then
                fsm.Entity:SetSpinning(true, 6)
            end
            fsm.WaitSpan = 2
            fsm.State = "Idle"
        end,
    }, { "Idle" })
end

function SpinJob:OnCleanup()
    if self.Entity then
        self.Entity:SetSpinning(false, 0)
    end
end

return SpinJob
```

### 5) Create instances (class table vs string)

After calling `Orchestrator:RegisterComponents()`:

```lua
-- Runtime creation example:
-- Create an Entity "body" first, then create an FSM "brain" and pass the entity in Context.
-- Option A: class table
local entity = Orchestrator.CreateEntity({
    EntityClass = shared.Entity.SpinningPartEntity,
    EntityId = "SpinPart",
    Context = { Instance = workspace.SpinPart },
})

-- Option B: string lookup (uses compiled registry)
local fsm = Orchestrator.CreateStateMachine({
    StateMachineClass = "SpinJob",
    StateMachineId = "SpinJob_01",
    Context = { Entity = entity },
})

fsm:Start({ State = "Idle" })
```

### 6) Manual (no-registry) registration

If you don’t want registries, you can build classes directly and pass them to Orchestrator:

```lua
-- Manual/no-registry example:
-- You define classes in code with BaseEntity.Extend / BaseStateMachine.Extend.
-- This is useful for prototypes/tests or highly dynamic class generation.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")

-- Orchestrator is still used for lifecycle management, pooling, and (optionally) replication/persistence.
local Orchestrator = require(SharedModules:WaitForChild("Orchestrator"))

-- Require bases from inside Orchestrator’s package (paths depend on how you mounted the repo)
-- Typical layout: ReplicatedStorage/SharedModules/Orchestrator/Factory/BaseEntity & BaseStateMachine
local BaseEntity = require(SharedModules.Orchestrator:WaitForChild("Factory"):WaitForChild("BaseEntity"))
local BaseStateMachine = require(SharedModules.Orchestrator:WaitForChild("Factory"):WaitForChild("BaseStateMachine"))

local MyEntity = BaseEntity.Extend({
    Name = "MyEntity",
    -- Schema controls what keys are writable and how they validate.
    Schema = { Value = { Type = "number", Replicate = true } },
})

-- ApplyChanges makes the entity mutable; UpdateEntity will fail if this isn't provided.
function MyEntity:ApplyChanges(_) end

local MyFSM = BaseStateMachine.Extend({
    className = "MyFSM",
    validStates = { "Start", "Done" },
    terminalStates = { "Done" },
    -- Render priority means "every frame".
    Priority = BaseStateMachine.Priorities.Render,
})

function MyFSM:RegisterStates()
    self:AddState("Start", function(fsm)
        -- Mutate entity data via schema, then commit.
        fsm.Entity.Value = 123
        fsm.Entity:UpdateEntity()

        -- Transition to the terminal state.
        fsm.State = "Done"
    end, { "Done" })
end

-- Even in manual mode, RegisterComponents sets up shared globals and internal wiring.
Orchestrator:RegisterComponents()

local e = Orchestrator.CreateEntity({ EntityClass = MyEntity, EntityId = "E1", Context = { Instance = workspace.Part } })
local m = Orchestrator.CreateStateMachine({ StateMachineClass = MyFSM, StateMachineId = "M1", Context = { Entity = e } })

-- Start the machine at the first state.
m:Start({ State = "Start" })
```

Use this mode for tests, prototypes, or games that prefer module-local definitions.

## Quick Start

This quick start uses the **Factory + Registry + Implementation module** workflow.

### 0) Roblox hierarchy

Create this structure:

- `ReplicatedStorage/SharedModules/Orchestrator` (this repo’s Orchestrator package)
- `ReplicatedStorage/Entity/EntityRegistry`
- `ReplicatedStorage/Entity/SpinningPartEntity`
- `ReplicatedStorage/StateMachine/StateMachineRegistry`
- `ReplicatedStorage/StateMachine/SpinJob`

Also create a Part in `Workspace` named `SpinPart`.

### 1) EntityRegistry

`ReplicatedStorage/Entity/EntityRegistry`:

```lua
-- Quick Start registry example:
-- Define an entity template; Orchestrator compiles it into shared.Entity.SpinningPartEntity.
return {
    SpinningPartEntity = {
        Name = "SpinningPartEntity",
        Schema = {
            -- These will replicate from server to clients.
            IsSpinning = { Type = "boolean", Replicate = true },
            Speed = { Type = "number", Replicate = true },

            -- Internal connection handle; must be declared if you assign to it.
            _spinConn = { Type = "RBXScriptConnection" },
        }
    }
}
```

### 2) Entity implementation

`ReplicatedStorage/Entity/SpinningPartEntity`:

```lua
-- Quick Start entity implementation:
-- ApplyChanges runs on both layers; guard client-only visuals with RunService.
local RunService = game:GetService("RunService")

assert(shared.Entity and shared.Entity.SpinningPartEntity, "Call Orchestrator:RegisterComponents() before requiring SpinningPartEntity")
local SpinningPartEntity = shared.Entity.SpinningPartEntity

function SpinningPartEntity:ApplyChanges(changes)
    -- In this example we only animate on the client.
    if not RunService:IsClient() then return end

    if changes.IsSpinning == false and self._spinConn then
        self._spinConn:Disconnect()
        self._spinConn = nil
        return
    end

    if changes.IsSpinning == true and not self._spinConn then
        self._spinConn = RunService.Heartbeat:Connect(function(dt)
            local speed = self.Speed or 3
            local part = self.Instance
            if part and part:IsA("BasePart") then
                part.CFrame = part.CFrame * CFrame.Angles(0, dt * speed, 0)
            end
        end)
        self:Manage(self._spinConn)
    end
end

function SpinningPartEntity:SetSpinning(isSpinning: boolean, speed: number)
    -- Server-side helper: set schema keys, then commit.
    self.IsSpinning = isSpinning
    self.Speed = speed
    return self:UpdateEntity()
end

return SpinningPartEntity
```

### 3) StateMachineRegistry

`ReplicatedStorage/StateMachine/StateMachineRegistry`:

```lua
-- Quick Start StateMachine registry example:
-- Defines the StateMachine template compiled into shared.StateMachine.SpinJob.
return {
    SpinJob = {
        className = "SpinJob",
        validStates = { "Idle", "Spin" },
        terminalStates = { },
        context = { },
        Priority = 10,
    }
}
```

### 4) StateMachine implementation

`ReplicatedStorage/StateMachine/SpinJob`:

```lua
-- Quick Start StateMachine implementation:
-- RegisterStates is where you define your named states and transitions.
assert(shared.StateMachine and shared.StateMachine.SpinJob, "Call Orchestrator:RegisterComponents() before requiring SpinJob")
local SpinJob = shared.StateMachine.SpinJob

function SpinJob:RegisterStates()
    self:AddState("Idle", function(fsm)
        -- Drive the entity (body) from the FSM (brain).
        fsm.Entity:SetSpinning(false, 0)
        fsm.WaitSpan = 1
        fsm.State = "Spin"
    end, { "Spin" })

    self:AddState("Spin", function(fsm)
        fsm.Entity:SetSpinning(true, 6)
        fsm.WaitSpan = 2
        fsm.State = "Idle"
    end, { "Idle" })
end

return SpinJob
```

### 5) Server bootstrap

`ServerScriptService/Bootstrap.server.lua`:

```lua
-- Quick Start (server) bootstrap example:
-- This runs on the server, compiles registries, attaches implementations, then spawns the runtime instances.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")

local Orchestrator = require(SharedModules:WaitForChild("Orchestrator"))
Orchestrator:RegisterComponents()

-- Attach implementations (must happen AFTER RegisterComponents)
require(ReplicatedStorage:WaitForChild("Entity"):WaitForChild("SpinningPartEntity"))
require(ReplicatedStorage:WaitForChild("StateMachine"):WaitForChild("SpinJob"))

shared.FSM.Scheduler:Start()

local part = workspace:WaitForChild("SpinPart")

local entity = Orchestrator.CreateEntity({
    EntityClass = "SpinningPartEntity",
    EntityId = "SpinPart",
    Context = { Instance = part },
})

local fsm = Orchestrator.CreateStateMachine({
    StateMachineClass = "SpinJob",
    StateMachineId = "SpinJob_01",
    Context = { Entity = entity },
})

fsm:Start({ State = "Idle" })
```

### 6) Client bootstrap

`StarterPlayerScripts/Bootstrap.client.lua`:

```lua
-- Quick Start (client) bootstrap example:
-- Clients also call RegisterComponents so shared.Entity/shared.StateMachine are available locally.
-- Then you require client-side implementations (usually visuals) for entities.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")

local Orchestrator = require(SharedModules:WaitForChild("Orchestrator"))
Orchestrator:RegisterComponents()

-- Attach client visual behavior
require(ReplicatedStorage:WaitForChild("Entity"):WaitForChild("SpinningPartEntity"))
```

## Architecture Concepts

1.  **StateMachine**: The controller that manages the current state, transitions, and lifecycle.
2.  **Context**: A shared table (`fsm.Context`) used to store data (e.g., `Ammo`, `Target`, `DoorStatus`) accessible by all states.
3.  **Entity Pattern**: The FSM should handle *logic* (decisions), while an external "Entity" class handles *mechanisms* (visuals, physics, tweens).
4.  **Sub-Machine**: A child FSM running inside a state of a parent FSM.

## API Reference

### Luau Types (IntelliSense / Autocomplete)

This repo uses Luau's static typing features where practical.

- Some modules export types directly (for example, `Logger` exports `LogLevel` and `LogEntry`).
- A common pattern in your own modules is to add `export type X = typeof(X)` to make the class table type easy to reference.

Example (your own Entity module):

```lua
-- Types-for-IntelliSense example:
-- Exporting typeof(SubclassTable) gives you a concrete type you can reference elsewhere.
local DoorEntity = BaseEntity.Extend({ Name = "DoorEntity", Schema = { /* ... */ } })
export type DoorEntity = typeof(DoorEntity)
```

These types are compile-time only; they do not affect runtime schema validation.

### Static Properties: Priorities
Defines how often the `OnHeartbeat` and transition checks run.

| Level | Value | Description |
| :--- | :--- | :--- |
| **Render** | 1 | Runs every frame. |
| **High** | 2 | Runs every 2 frames. |
| **Medium** | 5 | Runs every 5 frames. |
| **Low** | 10 | Runs every 10 frames. |
| **Background** | 30 | Runs every 30 frames (~0.5s at 60 FPS). |

### Constructor & Extension

#### `BaseStateMachine.Extend(definition)`
Creates a new class (subclass) template.
```lua
-- Extend(...) example:
-- This produces a reusable "class table" that you later attach RegisterStates/OnCleanup to.
local MyFSM = BaseStateMachine.Extend({
    className = "MyFSM",
    validStates = { "Idle", "Active" }, -- Optional: Restricts valid transitions
    terminalStates = { "Dead" },        -- Optional: States that trigger Finish()
    context = {},                       -- Optional: Default context values
    Priority = BaseStateMachine.Priorities.Medium
})
```

#### `BaseStateMachine.new(params)`
Creates a new instance. usually called via `MyFSM.new()`.

This framework primarily constructs machines via `BaseStateMachine.Extend(...).new(table)`.

- **Direct base constructor params** (when calling `BaseStateMachine.new` yourself):
    - `Id: string`
    - `Name: string`
    - `ValidStates: {string}?` (or `validStates`)
    - `TerminalStates: {string}?` (or `terminalStates`)
    - `Context: table?`
    - `Priority: number?`

- **Subclass constructor params** (when calling `MyFSM.new(table)`):
    - Must include `Id` or `StateMachineId`.
    - All fields in the table become `fsm.Context`.
    - For convenience, context keys are also readable as `fsm.SomeKey` via `__index`.
    - You can also access the instance itself via `fsm.super`.

#### When to use `Extend(...)` vs `new(...)`

Use `BaseStateMachine.Extend(definition)` when you want a **reusable, named StateMachine class**:

- Works with this project’s **Factory + Registry** model (registries compile into `shared.StateMachine.*`).
- Gives you a place to attach behavior once: `MyFSM:RegisterStates()`, `MyFSM:OnCleanup()`, helpers, etc.
- Ensures consistent defaults per class (`className`, `validStates`, `terminalStates`, `Priority`).

Use `BaseStateMachine.new(params)` when you want a **one-off instance** of the base runtime:

- Best for quick prototypes/tests or manual wiring.
- You must provide the fields yourself (`Name`, `ValidStates`, etc.) and you don’t get a registry-friendly “class table” to hang methods on unless you build your own wrapper.

### Core Methods

#### `fsm:Start(params)`
Begins execution and registers the FSM to the centralized heartbeat loop.
- **params**: `{ State: string, Args: {any}? }`

#### `fsm:ChangeState(params)`
Transitions to a new state.
- **params**: `{ Name: string, Args: {any}? }`
- **WaitSpan Support**: If `fsm.WaitSpan` is set, the transition is delayed by that duration (in seconds). WaitSpan is reset to `0` immediately when `ChangeState` is called.

#### `fsm:AddState(name, state, validOutcomes?)`
Registers a state logic.
- **name**: `string`
- **state**: `function` or `StateObject`
- **validOutcomes**: `string[]?` (Optional list of allowed next states for enforcement)

#### `fsm:AddSubMachine(name, subMachineClass, config)`
Registers a nested FSM (HFSM).

```lua
-- HFSM example (registering a nested machine):
-- AddSubMachine creates a state that runs another FSM and maps its outcomes back into parent transitions.
fsm:AddSubMachine("SubTask", CleaningJob, {
    InitialState = "Idle",
    Transitions = {
        OnCompleted = "NextTask",
        OnFailed = "RetryTask",
        OnCancelled = "Abort"
    },
    StoreReference = "CurrentCleaner" -- fsm.CurrentCleaner now holds the sub-fsm
})
```

#### `Orchestrator.PoolEntity(entityId)`
Deactivates an entity and adds it to an internal pool for later reuse. This is more efficient than `Destroy` for frequently spawned objects.
- **entityId**: `string`

#### `Orchestrator.GetPooledEntity(params)`
Retrieves an entity from the pool if available, otherwise creates a new one.
- **params**: Same as `CreateEntity`.

#### `Orchestrator.SendCommand(entityId, command, ...)`
(Client Only) Sends a command to the server for a specific entity.
- **entityId**: `string`
- **command**: `string`
- **...**: Variable arguments.

#### `Orchestrator.RegisterCommandHandler(entityId, command, handler)`
(Server Only) Registers a listener for commands sent from the client.
- **entityId**: `string`
- **command**: `string`
- **handler**: `function(player, ...any)`

#### `Orchestrator.RegisterEventBus(name)`
Creates a new local event bus (Signal).
- **name**: `string`
- **Returns**: `Signal` object.

#### `Orchestrator.FireEventBus(name, ...)`
Fires a local event bus by name.

#### `Orchestrator.AwaitEventBus(name, timeout?)`
Yields the current thread until an event bus with the specified name is registered.
- **name**: `string`
- **timeout**: `number?` (seconds)
- **Returns**: `Signal` object or `nil` if timed out.

#### `Orchestrator.RetryStateMachine(id)`
Destroys and recreates a StateMachine by its ID, preserving its current `Context`.

#### `fsm:Manage(object)`
Registers a "Disposable" to be cleaned up when the FSM is destroyed.

```lua
-- Connection will be disconnected automatically on fsm:Destroy()
fsm:Manage(game:GetService("RunService").Heartbeat:Connect(function() end))

-- Instances will be :Destroy()'d
fsm:Manage(Instance.new("Part"))
```

### Signals, Lifecycle, and Runtime Fields

#### Signals

- `fsm.Completed`: fires when `fsm:Finish()` runs
- `fsm.Failed`: fires when `fsm:Fail(reason)` runs
- `fsm.Cancelled`: fires when `fsm:Cancel()` runs
- `fsm.StateChanged`: fires on every transition with `(newStateName, oldStateName)`

```lua
-- Signals example:
-- StateChanged fires on every transition, letting you observe/debug control flow.
-- Assumes `fsm` is a running instance (after `:Start(...)`).
fsm.StateChanged:Connect(function(newState, oldState)
    print("Transitioned from", oldState, "to", newState)
end)
```

You can also transition using property syntax: `fsm.State = "SomeState"` (this calls `ChangeState` under the hood).

#### Lifecycle methods

- `fsm:Finish()` / `fsm:Fail(reason)` / `fsm:Cancel()` stop the machine and fire signals
- `fsm:Destroy()` tears down the machine and disposes all `Manage(...)` resources
- `fsm:RegisterStates()` and `fsm:OnCleanup()` are virtual hooks your subclasses override

#### Timing and transition helpers

- `fsm.WaitSpan`: delays the *next* transition attempt; it is consumed and reset to `0` on use. Any newer transition invalidates older delayed transitions.
- `validOutcomes` (passed to `AddState`) are enforced: transitions not listed are rejected and logged.
- `terminalStates`: terminal states can be **implicit** (not registered via `AddState`). Entering a terminal state auto-finishes the machine.

Usability notes:

- **Implicit terminal states can hide typos**: if you transition to a terminal state string that is not registered via `AddState`, the machine may `Finish()` without running state logic. To make typos noisy, prefer registering your terminal states explicitly and/or using `validOutcomes` guard rails.
- **WaitSpan invalidation is intentional but implicit**: if you schedule a delayed transition via `WaitSpan` and later trigger another transition, the delayed one is cancelled. There is no built-in callback when a delayed transition is invalidated. If you need cancellation awareness, track your own transition token in `Context` and check it before applying a delayed change.

#### Cleanup gotchas

- Object states get per-transition cleanup via `OnLeave`.
- Function states are legacy-style: if a function state returns a cleanup function, the current implementation executes it immediately after the state function returns (not on transition, and not at teardown). Prefer object states + `OnLeave` for per-transition cleanup.

## State Definitions

### 1. Function States (Simple)
Best for linear logic or simple actions.

Note: in the current implementation, returning a function will execute that cleanup immediately after the state function returns. For deterministic per-transition cleanup, prefer Object States + `OnLeave`.

```lua
-- Function state example:
-- Use this for simple/linear actions; the function runs when the state is entered.
fsm:AddState("Idle", function(self, ...)
    print("Entered Idle")
    
    -- Optional: Return cleanup function (runs immediately in the current implementation)
    return function()
        print("Cleaning up Idle")
    end
end)
```

### 2. Object States (Advanced)
Best for states requiring per-frame logic (`OnHeartbeat`) or complex event handling.

```lua
-- Object state example:
-- Use this when you need per-frame logic (OnHeartbeat) and deterministic per-transition cleanup (OnLeave).
local MyState = {
    OnEnter = function(self, fsm, ...) end,
    OnHeartbeat = function(self, fsm, dt) end,
    OnLeave = function(self, fsm) end,
    Transitions = {
        -- Auto-transition if Condition returns true
        { TargetState = "Walking", Condition = function(fsm, dt) return fsm.Context.IsMoving end }
    }
}
```

## Hierarchical FSM (HFSM)

You can nest an entire FSM inside a state of another FSM. The parent FSM will wait for the child to Complete, Fail, or Cancel before moving on.

### Usage
Use `AddSubMachine` in your `RegisterStates` method.

```lua
-- HFSM usage example:
-- This adds a sub-machine as a state and routes child completion/failure/cancel into parent states.
self:AddSubMachine("Locked", LockedSubFSM, {
    InitialState = "Secure",
    -- Map Child Events to Parent States
    Transitions = {
        OnCompleted = "Closed", -- Child finished successfully
        OnFailed = "Jammed",    -- Child failed
        OnCancelled = "Idle"    -- Child was cancelled
    },
    -- Optional: Store the child instance in Context for later access
    StoreReference = "LastLockedFSM"
})
```

### Data Passing
The Child FSM shares the **same Context table** as the Parent.
- **Parent**: Sets `fsm.Context.TargetId = 123`
- **Child**: Reads `fsm.Context.TargetId`
- **Child**: Sets `fsm.Context.Result = "Success"`
- **Parent**: Reads `fsm.Context.Result` after child completes.

## Advanced Patterns

### The Entity Pattern
Avoid putting visual/physics logic inside the FSM. Use an **Entity** class.

*   **Bad**: FSM sets `Part.Transparency = 0.5`.
*   **Good**: FSM calls `fsm.Entity:SetStealth(true)`.

This allows you to swap the Entity (e.g., different NPC models) without changing the FSM logic.

Example (FSM drives Entity, Entity owns visuals):

```lua
-- Entity (ReplicatedStorage/Entity/StealthEntity)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")

local BaseEntity = require(SharedModules:WaitForChild("BaseEntity"))

local StealthEntity = BaseEntity.Extend({
    Name = "StealthEntity",
    Schema = {
        IsStealthed = { Type = "boolean", Replicate = true, Description = "Whether the model is stealthed" },
    },
})

function StealthEntity:ApplyChanges(changes)
    if changes.IsStealthed ~= nil then
        local model = self.Instance
        for _, desc in ipairs(model:GetDescendants()) do
            if desc:IsA("BasePart") then
                desc.Transparency = changes.IsStealthed and 0.7 or 0
            end
        end
    end
end

return StealthEntity
```

```lua
-- FSM state (server): decides stealth on/off, then commits
self:AddState("Stealth", function(fsm)
    local entity = fsm.Context.Entity
    entity.IsStealthed = true
    entity:UpdateEntity()

    fsm.WaitSpan = 3
    fsm.State = "Unstealth"
end, { "Unstealth" })

self:AddState("Unstealth", function(fsm)
    local entity = fsm.Context.Entity
    entity.IsStealthed = false
    entity:UpdateEntity()
    fsm:Finish()
end)
```

### Behavior Trees
While FSMs are great for *states* (Opening, Closed), they can become messy for *decision making* (Should I open the door?).

The framework includes a dedicated [BehaviorTree](#behaviortree) component designed to drive FSMs. Use Behavior Trees for high-level strategy and FSMs for low-level execution.

#### Available BT Nodes:
- `BT.Selector(children)`: Runs children in order until one succeeds.
- `BT.Sequence(children)`: Runs children in order until one fails.
- `BT.Inverter(child)`: Returns Failure if child succeeds, and Success if child fails.
- `BT.Succeeder(child)`: Always returns Success.
- `BT.Condition(predicate)`: Calls `predicate(fsm)`. Returns Success if true, Failure if false.
- `BT.SetState(stateName)`: Transitions the FSM to the target state. Always returns Success.

### Event Bus

The `Orchestrator` provides a built-in event bus system for decoupled communication.

```lua
-- Register a bus
local bus = Orchestrator.RegisterEventBus("GlobalAlert")

-- Subscribe
bus:Connect(function(msg)
    print("Received alert:", msg)
end)

-- Fire from anywhere
Orchestrator.FireEventBus("GlobalAlert", "Invasion started!")

-- Yield for registration (useful for race conditions)
local bus = Orchestrator.AwaitEventBus("GlobalAlert", 5)
```

For networked events, you can use the `SendCommand` / `RegisterCommandHandler` pattern or regular `RemoteEvents`.

Common approaches in your game code:

- **Server-only bus**: a `BindableEvent` (or a small Signal implementation) stored in a shared module.
- **Client-only bus**: another `BindableEvent` in a client module.
- **Networked events**: your own RemoteEvent(s) using the command pattern described in the Orchestrator section.

Example (server-only bus via BindableEvent):

```lua
-- ServerBus (ModuleScript in ServerScriptService or ReplicatedStorage/SharedModules)
local BindableEvent = Instance.new("BindableEvent")

local Bus = {}
function Bus:Publish(message)
    BindableEvent:Fire(message)
end

function Bus:Subscribe(handler)
    return BindableEvent.Event:Connect(handler)
end

return Bus
```

```lua
-- Server usage
local Bus = require(path.to.ServerBus)

local conn = Bus:Subscribe(function(msg)
    if msg.Type == "DoorOpened" then
        print("Door opened:", msg.DoorId)
    end
end)

Bus:Publish({ Type = "DoorOpened", DoorId = "Door_01" })
```

Example (client-only bus):

```lua
-- ClientBus (ModuleScript under StarterPlayerScripts)
local BindableEvent = Instance.new("BindableEvent")

local Bus = {}
function Bus:Publish(message)
    BindableEvent:Fire(message)
end
function Bus:Subscribe(handler)
    return BindableEvent.Event:Connect(handler)
end
return Bus
```

Example (networked bus via RemoteEvent):

```lua
-- Server (once): create RemoteEvent
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameBus = ReplicatedStorage:FindFirstChild("GameBus") or Instance.new("RemoteEvent")
GameBus.Name = "GameBus"
GameBus.Parent = ReplicatedStorage

-- Publish from server to all clients
GameBus:FireAllClients({ Type = "Match/Countdown", Seconds = 10 })
```

```lua
-- Client: subscribe
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameBus = ReplicatedStorage:WaitForChild("GameBus")

GameBus.OnClientEvent:Connect(function(msg)
    if msg.Type == "Match/Countdown" then
        print("Match starts in", msg.Seconds)
    end
end)
```

## Best Practices

1.  **Use `fsm.Context`**: Avoid global variables.
2.  **Priority Management**: Set UI FSMs to `Render` and background AI to `Low` to save CPU.
3.  **Cleanup**: Always use `self:Manage(connection)` inside `OnEnter`.
4.  **Avoid Recursive States**: Do not transition to the same state within `OnEnter` without a delay or condition, as this causes a stack overflow.
5.  **Keep `ApplyChanges` context-safe**: `entity:UpdateEntity()` calls `entity:ApplyChanges(changes)` on the authority that commits the change (typically the server), and clients may also call `ApplyChanges` when receiving replicated change packets. Your `ApplyChanges` must be safe to run in both contexts.
6.  **Client-only visuals in `ApplyChanges`**: If `ApplyChanges` performs purely visual work (particles, sounds, camera/UI, `LocalTransparencyModifier`, etc.), guard it:

```lua
-- Best-practice example:
-- ApplyChanges may run on both server (authoritative commit) and client (replication).
-- Guard client-only visuals so the server never touches client-only properties.
local RunService = game:GetService("RunService")

function MyEntity:ApplyChanges(changes)
    if not RunService:IsClient() then
        return
    end
    -- visual-only application here
end
```

If you need both (server mechanics + client visuals), split the function into two internal helpers and call them behind `RunService:IsServer()` / `IsClient()` so you never accidentally run client-only properties on the server.

## Architectural Patterns

The BaseStateMachine architecture supports several architectural patterns that allow you to scale from a simple light switch to a complex autonomous jet. Here are the primary patterns you can implement with this system:

### 1. The Sequential (Linear) Pattern
This is the most basic pattern where states follow a strict "A to B to C" order. It is ideal for tutorials, cinematic sequences, or loading processes.

**Implementation:**
```lua
-- Sequential pattern example:
-- Each state sets WaitSpan (delay) and then transitions to the next state.
self:AddState("Intro", function(fsm) 
    fsm.WaitSpan = 2
    fsm.State = "Briefing" 
end)

self:AddState("Briefing", function(fsm) 
    fsm.WaitSpan = 5
    fsm.State = "Gameplay" 
end)
```

### 2. The Guarded Transition Pattern
This pattern uses `validOutcomes` to prevent "impossible" logic, such as jumping directly from `InHangar` to `Supersonic`. It ensures the FSM remains in a valid state regardless of input bugs.

**Implementation:**
```lua
-- Only allow Taxi or Maintenance after being in the Hangar
self:AddState("Hangar", self.HangarState, {"Taxi", "Maintenance"})

-- If code tries to do fsm.State = "Flight", the Logger will throw an ERROR
```

### 3. The Hierarchical Pattern (Sub-States)
Used for managing high-level logic and low-level details separately. For example, a "Combat" state can be a machine of its own containing "Aiming," "Firing," and "Reloading."

**Implementation:**
```lua
-- Hierarchical/Sub-machine pattern example:
-- AddSubMachine runs a child FSM and maps its outcomes back into parent transitions.
self:AddSubMachine("Combat", CombatFSMClass, {
    InitialState = "Aiming",
    Transitions = {
        OnCompleted = "Patrol", -- Combat ended successfully
        OnFailed = "Respawn"    -- Combat ended in death
    },
    StoreReference = "ActiveCombat" -- Accessible via fsm.Context.ActiveCombat
})
```

### 4. The Reactive (Event-Driven) Pattern
Instead of checking conditions every frame, the FSM reacts to external signals. This is highly performant because it leverages Roblox's event system.

**Implementation:**
```lua
-- Reactive pattern example:
-- Subscribe to an external signal/event in OnEnter and disconnect it in OnLeave.
self:AddState("Waiting", {
    OnEnter = function(state, fsm)
        state._conn = workspace.Button.Touched:Connect(function()
            fsm.State = "Triggered"
        end)
    end,
    OnLeave = function(state)
        if state._conn then state._conn:Disconnect() end
        state._conn = nil
    end
})
```

### 5. The Polling Pattern (Heartbeat Logic)
This is the standard for physics and AI. The machine "polls" the environment every frame or every few frames (based on Priority) to decide what to do.

**Implementation:**
```lua
-- Polling/Heartbeat pattern example:
-- OnHeartbeat runs every N frames (based on Priority) with accumulated dt.
self:AddState("Approach", {
    OnHeartbeat = function(state, fsm, dt)
        local distance = (fsm.Target.Position - fsm.Jet.Position).Magnitude
        if distance < 100 then
            fsm.State = "Attack"
        end
    end
})
```

### 6. The "Retry" or "Loop" Pattern
This handles intermittent failures (like a network request or a pathfinding calculation) by attempting the state again with a delay.

**Implementation:**
```lua
-- Retry/loop pattern example:
-- Retry the same state after a delay when work fails, otherwise continue.
self:AddState("CalculatePath", function(fsm)
    local success = fsm:DoComplexMath()
    if not success then
        fsm.WaitSpan = 1
        fsm.State = "CalculatePath" -- Loop back to self
    else
        fsm.State = "Move"
    end
end)
```

### 7. The Cleanup/Disposable Pattern
Crucial for Roblox development to prevent memory leaks. This pattern treats the state as a "container" for resources.

**Implementation:**
```lua
-- Cleanup/disposable pattern example:
-- The state allocates resources, then returns a cleanup function to dispose them.
self:AddState("ActiveEffect", function(fsm)
    local light = Instance.new("PointLight", fsm.JetPart)
    local sound = Instance.new("Sound", fsm.JetPart)
    
    -- Everything inside this function is nuked when the FSM is destroyed
    -- (Finish/Fail/Cancel/Destroy). For per-state cleanup, prefer Object States + OnLeave.
    return function()
        light:Destroy()
        sound:Destroy()
    end
end)
```

### 8. The Command Pattern (Input Separation)
This is vital for client-server communication. Instead of the FSM handling raw InputObject events, the client sends a "Command" which the server validates and converts into a State change.

**Implementation (Client):**
```lua
-- Command pattern (client) example:
-- Client sends an intent; server validates and performs the authoritative state change.
Orchestrator.SendCommand("Jet_01", "ToggleGear")
```

**Implementation (Server):**
```lua
-- Command pattern (server) example:
-- Server handles the command for a specific entity/job and updates authoritative state.
Orchestrator.RegisterCommandHandler("Jet_01", "ToggleGear", function(player)
    local fsm = Orchestrator.GetStateMachine("Jet_FSM_01")
    if fsm.State == "Landed" then
        fsm.State = "Takeoff"
    end
end)
```

### 9. The Pooled Pattern (High-Frequency Objects)
Reduces GC pressure by reusing Entities instead of destroying and recreating them.

**Implementation:**
```lua
-- When no longer needed
Orchestrator.PoolEntity("Bullet_001")

-- When a new one is needed
local bullet = Orchestrator.GetPooledEntity({
    EntityClass = shared.Entity.Bullet,
    Context = { StartPos = Vector3.new(0, 50, 0) }
})
```

### Summary Table of Patterns

| Pattern | Best Use Case | Benefit |
| :--- | :--- | :--- |
| **Sequential** | Tutorials / Cutscenes | Simple, predictable flow. |
| **Guarded** | Safety-critical systems (Physics) | Prevents logic errors and "teleporting" states. |
| **Hierarchical** | AI / Complex Vehicles | Organizes "Master" and "Slave" logic cleanly. |
| **Reactive** | UI / Interaction | Zero CPU cost when idle. |
| **Polling** | Flight Physics / Combat AI | Real-time responsiveness to environment. |
| **Retry** | API Calls / Pathfinding | Handles "Edge Case" failures gracefully. |
| **Cleanup** | Memory Management | Automatically prevents memory leaks in Roblox. |
| **Command** | User Interaction | Cleanly separates input (player) from logic (server). |
| **Pooled** | Projectiles / VFX | Dramatically reduces memory spikes and GC overhead. |

---

## BaseStateMachine

`BaseStateMachine` is the FSM/HFSM engine component of this project. If you’re looking for “BaseFiniteStateMachine”, this repository uses the shorter module name `BaseStateMachine` for the same idea.

### Documentation

`BaseStateMachine` is responsible for:

- Defining the StateMachine runtime object (states, transitions, and lifecycle).
- Running many machines efficiently via a centralized `RunService.Heartbeat` loop with time-slicing (`Priorities`).
- Emitting lifecycle and transition signals (`Completed`, `Failed`, `Cancelled`, `StateChanged`).
- Supporting hierarchical sub-machines (HFSM) via `AddSubMachine`.

In this project’s architecture:

- StateMachines generally own *decisions* and *control flow*.
- Entities generally own the replicated “view model” state and client-visible mechanics/visuals.

### Core Features

- **Centralized update loop**: machines register into one Heartbeat connection; each machine runs every N frames based on `Priority`.
- **Time-slicing / staggering**: machines use a per-instance `_offset` so a large group of identical priorities does not all tick on the same frame.
- **Two state styles**:
    - Function states (simple, synchronous steps)
    - Object states (structured `OnEnter` / `OnHeartbeat` / `OnLeave`)
- **Guard rails**:
    - Optional `validStates` list prevents typos and unexpected transitions.
    - Optional `validOutcomes` per-state restricts legal transitions.
- **Terminal states**: optional `terminalStates` list lets you define end-states that auto-`Finish()` (or `Fail` / `Cancel` when named accordingly).
- **Resource cleanup**: `Manage(...)` registers disposables that are cleaned up when the machine tears down.

### API Reference

#### Static Properties

##### `BaseStateMachine.Priorities`

Standard priority levels (frames between updates):

- `Render = 1`
- `High = 2`
- `Medium = 5`
- `Low = 10`
- `Background = 30`

Lower numbers run more often.

#### Static Methods

##### `BaseStateMachine.Extend(extensionParams)`

Creates a StateMachine subclass (class table) from a definition.

- **extensionParams**:
    - `className: string`
    - `validStates: string[]?`
    - `terminalStates: string[]?`
    - `Priority: number?`

Note: the current base implementation reads `className`, `validStates`, `terminalStates`, and `Priority`. Any extra keys are ignored unless your own subclass logic uses them.

The returned subclass has a `.new(table)` constructor, and you implement `Subclass:RegisterStates()` to define states.

##### `BaseStateMachine.new(params)`

Creates a new BaseStateMachine instance (usually called indirectly via `MyFSM.new(table)`).

- **params**:
    - `Id: string`
    - `Name: string?`
    - `ValidStates: string[]?`
    - `TerminalStates: string[]?`
    - `Context: any?`
    - `Priority: number?`

#### Instance Methods

##### `fsm:Start(params)`

Begins execution and transitions into the initial state.

- **params**: `{ State: string, Args: {any}? }`

##### `fsm:ChangeState(params)`

Transitions to a new state.

- **params**: `{ Name: string, Args: {any}? }`

Notes:

- You can also assign with property syntax: `fsm.State = "SomeState"` (calls `ChangeState`).
- If `fsm.WaitSpan > 0`, the transition is delayed; any newer transition invalidates older delayed transitions.

##### `fsm:AddState(name, state, validOutcomes?)`

Registers a state definition.

- **name**: `string`
- **state**: function state or object state
- **validOutcomes**: `string[]?`

State styles:

- **Function state**: `function(fsm, ...args)`
- **Object state**:
    - `OnEnter(state, fsm, ...args)`
    - `OnHeartbeat(state, fsm, dt)?`
    - `OnLeave(state, fsm)?`
    - `Transitions: { { TargetState: string, Condition: (fsm, dt) -> boolean } }?`

##### `fsm:AddSubMachine(name, subMachineClass, config)`

Registers a state that internally runs another StateMachine (HFSM).

- **name**: `string`
- **subMachineClass**: a subclass returned by `BaseStateMachine.Extend(...)`
- **config**:
    - `InitialState: string`
    - `Transitions: { OnCompleted: string, OnFailed: string, OnCancelled: string? }`
    - `StoreReference: string?` (stores the created sub-machine under `fsm.Context[StoreReference]`)

The parent machine can route to different states based on child completion/failure/cancellation.

##### `fsm:Manage(object)`

Registers a disposable to clean up when the machine tears down.

Supported types:

- `Instance` (calls `:Destroy()`)
- `RBXScriptConnection` (calls `:Disconnect()`)
- `function` (calls the function)
- Table with `:Destroy()` method

##### `fsm:Finish()` / `fsm:Fail(reason?)` / `fsm:Cancel()`
Stops the machine and fires lifecycle signals.

```lua
-- Lifecycle example:
-- Fail(reason) stops the machine, fires fsm.Failed(reason), and triggers teardown.
if not playerExists then
    fsm:Fail("Target player left the game")
end
```

##### `fsm:Destroy()`

Tears down the machine and disposes managed resources, then destroys internal BindableEvents.

##### `fsm:Log(params)`

Writes a log entry scoped to this StateMachine.

- **params**: `{ Level: "INFO"|"WARN"|"ERROR"|"DEBUG", Message: string, Data: any? }`

### Minimal Example

Small example showing a subclass, state registration, a delayed transition via `WaitSpan`, and an object state with `OnHeartbeat`:

```lua
-- Minimal BaseStateMachine example:
-- 1) Require the base, 2) Extend to define a class, 3) RegisterStates, 4) construct + Start.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local BaseStateMachine = require(SharedModules:WaitForChild("BaseStateMachine"))

local DoorJob = BaseStateMachine.Extend({
    className = "DoorJob",
    validStates = { "Idle", "Opening", "Open" },
    terminalStates = { "Open" },
    Priority = BaseStateMachine.Priorities.Medium,
})

function DoorJob:RegisterStates()
    self:AddState("Idle", function(fsm)
        -- Delay the next transition attempt
        fsm.WaitSpan = 0.25
        fsm.State = "Opening"
    end, { "Opening" })

    self:AddState("Opening", {
        OnEnter = function(state, fsm)
            fsm.Context.StartedAt = os.clock()
        end,
        OnHeartbeat = function(state, fsm, dt)
            -- Run polling logic at your chosen Priority
            local elapsed = os.clock() - (fsm.Context.StartedAt or os.clock())
            if elapsed >= 1.0 then
                fsm.State = "Open"
            end
        end,
        OnLeave = function(state, fsm)
            -- Per-transition cleanup goes here (preferred over function-state cleanup)
        end,
    }, { "Open" })
end

-- Usage
local fsm = DoorJob.new({
    StateMachineId = "Door_01",
    -- Add any context keys directly on this table
    DoorId = "Door_01",
})
fsm:Start({ State = "Idle" })
```

### Signals, Lifecycle, and Gotchas

- **Signals**:
    - `fsm.Completed`, `fsm.Failed`, `fsm.Cancelled`
    - `fsm.StateChanged(newStateName, oldStateName)`
- **Central loop behavior**: `Priority` is frame-based, not time-based; the loop accumulates `dt` for skipped frames and passes the accumulated `dt` into `_Update`.
- **WaitSpan invalidation**: delayed transitions are invalidated when a newer transition occurs; there is no built-in “delay cancelled” callback.
- **Function state cleanup**: if a function state returns a cleanup function, the current implementation executes it immediately after the state function returns (not on teardown). For reliable per-transition cleanup, prefer object states with `OnLeave`.
- **Implicit terminal states**: terminal states can complete the machine even without a registered state body; to make typos noisy, register your terminal states explicitly and/or use `validStates`.

## BehaviorTree

Behavior Trees (BT) are an alternative to FSMs for complex decision-making. While an FSM is great for managing **what** an agent is doing (Idle, Attacking, Patrolling), a BT is better at deciding **which** state the agent should be in based on a set of conditions.

### Core Concepts

The implementation is a functional, lightweight "stateless" tree. Each node is a function that takes a `context` (usually an FSM or an Entity) and returns a `Status`:
- `Success`: The task was completed.
- `Failure`: The task failed or conditions were not met.
- `Running`: The task is still in progress (highly useful for time-sliced AI).

### Node Types

#### 1. Composite Nodes
- **Selector**: Runs children in order until one **Succeeds**. If a child returns **Running**, the selector returns **Running**. If all fail, it returns **Failure**. (Similar to an OR gate).
- **Sequence**: Runs children in order until one **Fails**. If a child returns **Running**, the sequence returns **Running**. If all succeed, it returns **Success**. (Similar to an AND gate).

#### 2. Decorator Nodes
- **Inverter**: Swaps Success and Failure.
- **Succeeder**: Always returns Success (unless the child is Running).

#### 3. Leaf Nodes (Utility)
- **Condition**: Takes a predicate function. Returns Success if true, Failure if false.
- **SetState**: Specifically designed for FSM integration. Sets `fsm.State` to a new value and returns Success.

### Example: Guard AI

This tree checks if a target is in range. If yes, it attacks. If no, it patrols.

```lua
-- BehaviorTree example (driving an FSM):
-- The tree is evaluated each tick (e.g. from an FSM state's OnHeartbeat) and chooses the next state.
-- Requires Orchestrator:RegisterComponents() so shared.BehaviorTree is available.
local BT = shared.BehaviorTree

local GuardAI = BT.Selector({
    -- High priority: Attack if in range
    BT.Sequence({
        BT.Condition(function(fsm) 
            return fsm.Target and (fsm.Target.Position - fsm.Entity.Position).Magnitude < 20 
        end),
        BT.SetState("Attack")
    }),
    
    -- Fallback: Patrol
    BT.SetState("Patrol")
})

-- In your FSM's OnHeartbeat:
function MyFSM:OnHeartbeat(dt)
    GuardAI(self) -- The tree decides the next transition
end
```

## BaseEntity

### Documentation

The BaseEntity class is a Proxy-based Data Authority system. It acts as a middleware between raw Roblox Instances and your game logic, providing schema validation, state locking, and a transactional update model.

### Core Features

- **Encapsulation**: Uses a Proxy/Private Properties pattern to hide internal state and protect the underlying Instance.
- **Schema Validation**: Enforces strict type-checking and property existence based on a predefined schema.
- **Transactional Updates**: Changes are held in a Pending state and committed to the Data authority only via `UpdateEntity`.
- **Concurrency Control**: Built-in `AcquireLock` system to prevent multiple systems from modifying the same entity simultaneously.
- **Automatic Cleanup**: Automatically destroys the entity proxy when the underlying Roblox Instance is destroyed or removed from the DataModel.
- **Data Persistence**: Native support for saving/loading properties marked with `Persist = true` to Roblox DataStores.

### API Reference

#### Static Methods

##### `BaseEntity.Extend(extensionParams)`

Creates a new Entity subclass definition.

- **extensionParams**: `{ Name: string, Schema: { [string]: PropertyDef } }`

##### `BaseEntity.new(params, class?)`

Constructor for a new entity instance. Usually called via `Subclass.new()`.

#### Instance Methods

##### `entity:AcquireLock(callerId)`
Attempts to lock the entity to a specific ID. Returns `true` if successful.

```lua
-- Locking example:
-- AcquireLock prevents other systems from committing changes until you ReleaseLock.
if entity:AcquireLock("Player_123") then
    -- Mutations are staged into Pending.
    entity.Value = 100

    -- Commit requires the lock id when the entity is locked.
    entity:UpdateEntity("Player_123")

    -- Always release the lock when finished.
    entity:ReleaseLock("Player_123")
end
```

##### `entity:ReleaseLock(callerId)`
Releases a previously acquired lock. Returns `true` if released correctly by the lock owner.

##### `entity:UpdateEntity(lockingCallerId?)`
Commits all Pending property changes. This snapshots the Pending table and triggers the internal `ApplyChanges` method.

```lua
-- Transaction example:
-- Multiple schema writes can be batched and applied together with a single UpdateEntity().
entity.Health = 50
entity.IsDead = false
local success = entity:UpdateEntity() -- Batch apply multiple changes
```

##### `entity:SetContext(key, value)`
Stores non-schema data used for internal logic that doesn't affect the physical Instance or replication.

```lua
-- Option A: Method call
entity:SetContext("IsBeingWatched", true)

-- Option B: Call syntax
entity({ LastAttacker = "NPC_Mob_01" })
```

##### `entity:Manage(object)`

Registers a disposable object (Instance, Connection, function, or table with :Destroy) to be cleaned up when the Entity is destroyed.

##### `entity:GetValidProperties()`

Returns the schema table for this entity. Orchestrator uses this for replication filtering.

##### `entity:Destroy()`

Destroys the entity proxy, runs `Manage(...)` cleanup tasks, and fires `Destroyed`.

##### `entity:DefineSchema(schema)`

Replaces the schema at runtime.

##### `entity:ApplyChanges(changes)`

Abstract hook you implement in subclasses. Called by `UpdateEntity` with a stable snapshot of Pending changes.

##### `entity:Log(params)`

Writes to the entity's logger (mostly used internally, but available).

### Events

- `entity.StateUpdated(changes)`: fires after a successful `UpdateEntity`, where `changes` is the committed change set
- `entity.Destroyed()`: fires when the entity proxy is destroyed

### Schema definition

Schema entries are tables and the core requires at minimum:

- `Type`: string (checked against `typeof(value)`, plus `IsA` for Instances)
- `Description`: string? (documentation only)

Additional keys can be used by higher-level systems. For example, Orchestrator replication checks:

- `Replicate`: boolean? (if true, changes to this key may be sent via `EntityUpdateRemote`)
- `Persist`: boolean? (if true, the property is saved to DataStore if the entity is created with `Persistent = true`)

### Persistence Setup

Entities can automatically Save/Load from DataStores **on the server** when `Orchestrator:RegisterComponents()` has run:

1. **Mark Schema**: Set `Persist = true` on desired properties.
2. **Enable in Orchestrator**: Pass `Persistent = true` and an optional `PersistenceKey` to `Orchestrator.CreateEntity`.

Implementation details (current behavior):

- Persistence is server-only; clients do not save or load DataStores.
- The default DataStore name is `EntityPersistence` with a `KeyPrefix` of `Entity` (hardcoded in Orchestrator).
- Persisted data is taken from `BaseEntity:Serialize()` (only schema fields with `Persist = true`).
- Auto-save runs on every successful `UpdateEntity()` for persistent entities and again on `Orchestrator.DeleteEntity(...)`.

```lua
-- Persistence-enabled entity example:
-- Persistent=true wires the entity to EntityPersistence (server-side) for automatic load/save.
Orchestrator.CreateEntity({
    EntityClass = DoorEntity,
    EntityId = "MainDoor",
    Persistent = true,
    PersistenceKey = "WorldAsset_MainDoor" -- Unique DataStore key
})

### Saving & Loading Global State (Best Practices)

Use persistence for world/global state that should survive server restarts (doors, mission flags, world toggles). Recommended practices:

- **Keep payloads small**: Persist only essential schema fields marked `Persist = true` (serialization is schema-driven).
- **Choose stable keys**: Use explicit `PersistenceKey` values for global objects (e.g., `World/Door/MainGate`).
- **Version your data**: If you change schema, store a version number in data or metadata and migrate on load.
- **Throttle saves**: If you update frequently, debounce saves with Scheduler to avoid rate limits.
- **Handle failures**: Treat DataStore operations as fallible; log and retry (DataStoreHandler supports retry config).
- **Avoid client writes**: Clients should request changes via commands; server remains authoritative for persistence.
```

### Proxy lookup order (reads)

Reading `entity.SomeKey` resolves in this order:

1. class method/property (subclass)
2. `Pending[SomeKey]`
3. `Data[SomeKey]`
4. `Context[SomeKey]`
5. special keys (`Name`, `Instance`)
6. Schema-defined keys may fall back to `entity.Instance[SomeKey]` (best-effort)

Undefined schema keys read as `nil`.

### Mutability and safe writes

- Writing to keys not present in Schema is rejected and logged.
- **`ApplyChanges` mutability rules (class vs instance overrides)**:
    - Normal usage: override `ApplyChanges` on the **class** you create via `BaseEntity.Extend({ ... })`.
    - The entity is considered **mutable** if either:
        - the subclass overrides `ApplyChanges` (i.e. it is not the base abstract `BaseEntity.ApplyChanges`), or
        - you assign an `ApplyChanges` function on a specific **instance** at runtime (instance-level override).
    - Once the entity is mutable, `ApplyChanges` is treated as “locked” and should not be swapped again mid-lifecycle.

Why instance-level override exists:

- Advanced cases like runtime composition (same Entity class, different renderer), test doubles/mocks, or generated entities where `ApplyChanges` is injected.
- Most projects should avoid per-instance overrides and prefer class-level overrides for clarity and type safety.

Practical takeaway:

- If `UpdateEntity()` reports the entity is immutable, you haven’t provided an `ApplyChanges` implementation yet.
- Prefer defining `ApplyChanges` in the subclass definition whenever possible.
- The entity automatically destroys itself if its `Instance` is removed from the DataModel (via `AncestryChanged`).

### The Transactional Flow

The BaseEntity uses a specific lifecycle to ensure data integrity:

1. **Modification**: When you set `entity.Property = value`, the proxy validates the type against the Schema and stores it in a Pending table.
2. **Commit**: Calling `entity:UpdateEntity()` calls `ApplyChanges(changes)` first.
3. **Application**: If `ApplyChanges()` succeeds, Pending is copied to Data, Pending is cleared, and `StateUpdated(changes)` fires.

### Entity Updates & Replication (Deep Dive)

This project uses **server-authoritative entity updates**. In other words:

- Server code is responsible for mutating Entities and calling `UpdateEntity()`.
- Clients receive updates via remotes and apply them locally (they are not the authority).

#### Update pipeline (server)

The core `BaseEntity` update pipeline is:

1. You assign schema keys (property syntax): `entity.Health = 90`.
2. The proxy validates the type and stores the value in `Pending`.
3. You call `entity:UpdateEntity(lockId?)`.
4. `UpdateEntity` snapshots Pending into `changes`, then calls `entity:ApplyChanges(changes)`.
5. If `ApplyChanges` succeeds:
    - `Data` is updated with `changes`.
    - `Pending` is cleared.
    - `StateUpdated(changes)` fires.
6. Orchestrator listens to `StateUpdated` (server-side) and may replicate those changes to clients.

Important behavior:

- `UpdateEntity` returns `true` only if `ApplyChanges` succeeded.
- If `ApplyChanges` errors, Pending is preserved and no `StateUpdated` is fired.

#### Schema type system (what `Type` actually means)

`BaseEntity`’s schema validation is intentionally simple:

- For non-Instances: it checks `typeof(value) == def.Type`.
- For Instances: if `typeof(value) == "Instance"`, it additionally allows `value:IsA(def.Type)`.

That means your schema `Type` strings should match **Roblox `typeof` results** (e.g. `"number"`, `"string"`, `"Vector3"`, `"CFrame"`, `"Color3"`, `"EnumItem"`, `"Instance"`) or an **Instance class name** (e.g. `"Model"`, `"BasePart"`, `"Part"`).

Common `typeof`-based schema types you can safely use:

- Primitives: `"nil"`, `"boolean"`, `"number"`, `"string"`, `"table"`, `"function"`, `"thread"`
- Roblox datatypes (examples): `"Vector3"`, `"Vector2"`, `"CFrame"`, `"Color3"`, `"UDim2"`, `"Ray"`, `"EnumItem"`, `"BrickColor"`
- Instances:
    - Use `Type = "Instance"` to accept any Instance (because `typeof(instance) == "Instance"`).
    - Use a Roblox class name like `"BasePart"`, `"Part"`, `"Model"`, `"Attachment"` to enforce `IsA`.

Example:

```lua
-- Schema type-check example:
-- These entries demonstrate how Type strings map to typeof()/IsA() validation.
Schema = {
    AnyInstance = { Type = "Instance" },
    MustBePart = { Type = "Part" },
    MustBeModel = { Type = "Model" },
}
```

Limitations of this schema system:

- There is no deep validation for `table` values. If you set `Type = "table"`, any table shape is accepted.
- There is no built-in support for “union types” (e.g. number-or-nil). If you need optional fields, handle that at the schema/usage layer (or represent “unset” with a sentinel).
- Writes to keys not present in the Schema are rejected and logged.

Practical workarounds:

- **Optional values**: prefer explicit defaults (e.g. `0`, `false`, `""`) or store optional data in `Context` instead of Schema.
- **Union-like behavior**: represent “unset” with a sentinel value that still matches the schema type (e.g. `-1` or `""`), or split into multiple schema fields.
- **Complex structured data**: keep the schema key primitive and serialize yourself (e.g. JSON string) if you need to replicate it reliably.

Example: optional values via defaults (schema stays strict):

```lua
-- Schema: keep it strict
Schema = {
    TargetUserId = { Type = "number", Replicate = true, Description = "0 means unset" },
}

-- Server: interpret 0 as nil
if entity.TargetUserId == 0 then
    -- no target
else
    local targetUserId = entity.TargetUserId
end

-- Set/unset
entity.TargetUserId = 0
entity:UpdateEntity()
```

Example: union-like behavior by splitting fields:

```lua
-- Schema workaround example:
-- Simulate a "union" by splitting into a boolean flag + a value field.
Schema = {
    HasTarget = { Type = "boolean", Replicate = true, Description = "True when TargetPosition is meaningful" },
    TargetPosition = { Type = "Vector3", Replicate = true, Description = "Valid only when HasTarget == true" },
}

entity.HasTarget = true
entity.TargetPosition = Vector3.new(10, 5, 3)
entity:UpdateEntity()
```

Example: complex structured data via JSON string (replication-safe):

```lua
-- Requires HttpService for JSON encode/decode
local HttpService = game:GetService("HttpService")

Schema = {
    LoadoutJson = { Type = "string", Replicate = true, Description = "JSON payload" },
}

-- Server: encode a table payload
local loadout = { Primary = "Rifle", Mods = { "Scope", "Grip" }, Ammo = 120 }
entity.LoadoutJson = HttpService:JSONEncode(loadout)
entity:UpdateEntity()

-- Client ApplyChanges: decode when needed
function MyEntity:ApplyChanges(changes)
    if changes.LoadoutJson ~= nil then
        local ok, decoded = pcall(HttpService.JSONDecode, HttpService, changes.LoadoutJson)
        if ok then
            self({ Loadout = decoded }) -- keep decoded table in Context (non-replicated)
        end
    end
end
```

#### Replication rules (what gets sent)

Replication is **opt-in per field**.

- Orchestrator builds an update packet by iterating `changes` and including only keys whose schema entry has `Replicate = true`.
- That packet is broadcast to all clients on `EntityUpdateRemote`.

This means:

- If a key is not schema-defined, it cannot be written, and it cannot replicate.
- If a key is schema-defined but has no `Replicate = true`, it will never be included in replication packets.

#### When to replicate fields (and when not to)

Setting `Replicate = true` is a design decision: you’re choosing to send that field’s updates server → client via `EntityUpdateRemote`.

##### Good candidates for replication

Replicate fields when the client needs them to render accurate or responsive visuals/UI, or when client-side logic depends on the value:

- **Client-visible state**: door open/closed, health/armor, enabled/disabled, current animation state.
- **Client UI**: progress values, timers, status strings, interaction prompts.
- **Authoritative gameplay state the client must mirror**: team/ownership, target IDs, ability cooldown end times.
- **Low-frequency, stable values** that don’t change every frame.

Rule of thumb: replicate the *minimum* set of authoritative values the client needs to be correct.

##### Poor candidates for replication

Avoid replicating fields when:

- **The value is server-only / sensitive**: anti-cheat signals, hidden rolls, private targeting logic, server-only references.
- **It’s derived**: clients can compute it from other replicated fields (replicate inputs, not outputs).
- **It’s high-churn** (changes every frame): continuous physics telemetry, per-frame velocities, large transforms. Prefer Roblox’s built-in replication for physics/parts, or replicate at a lower rate / quantize.
- **It’s large or complex**: deep tables, big arrays, mixed-key maps. Prefer a compact encoding (e.g., JSON string) or a smaller “view model”.
- **It references Instances you can’t guarantee exist on the client** due to StreamingEnabled / replication order.

##### Patterns that keep replication clean

- **Replicate intent, not effects**: replicate `IsFiring` / `SfxNonce`, and let clients play sounds/particles locally.
- **Replicate IDs, not Instances**: replicate `TargetUserId` or an entity ID instead of a `Model` reference when possible.
- **Replicate timestamps/counters** instead of booleans for one-shots (see `nonce` pattern above).
- **Quantize & throttle**: if a value must replicate frequently, round/quantize it and only replicate when it changes meaningfully.

##### StreamingEnabled / replication-order note

If `StreamingEnabled` is on (or if Instances replicate in stages), clients can receive an update packet for an entity **before** all of the entity’s descendant Instances exist locally.

Practical implications:

- In `ApplyChanges`, prefer `FindFirstChild` + nil checks over assuming descendants exist.
- If you must wait, use `WaitForChild` with a short timeout to avoid yielding indefinitely.
- Consider a “lazy apply” approach: store `changes` in `Context` and re-attempt visual application when the required Instances appear.

Example helper (client-side):

```lua
-- StreamingEnabled helper example:
-- Wait for a descendant but return nil instead of yielding forever.
local function waitForChildOrNil(parent, name, timeout)
    local ok, child = pcall(function()
        return parent:WaitForChild(name, timeout)
    end)
    if ok then return child end
    return nil
end
```

##### Quick examples

Recommended to replicate:

```lua
-- Replication candidates example:
-- These are small, remote-serializable values that clients often need for UI/visuals.
Schema = {
    Health = { Type = "number", Replicate = true },
    IsOpen = { Type = "boolean", Replicate = true },
    CooldownEndsAt = { Type = "number", Replicate = true },
}
```

Usually not recommended to replicate:

```lua
-- Non-replication candidates example:
-- These are server-only, derived, or potentially large/high-churn values.
Schema = {
    DebugPath = { Type = "table", Replicate = false }, -- large/high-churn
    ServerSecret = { Type = "string", Replicate = false },
    DerivedSpeed = { Type = "number", Replicate = false }, -- compute from other state
}
```

#### Replication-safe data (what values are acceptable)

`EntityUpdateRemote` sends **raw values**; it does not sanitize or transform them.

There is no intermediate encode/decode layer for replication packets. If you need to replicate complex nested structures, you should explicitly serialize to a replication-safe representation (commonly a `string` payload) and decode on the client.

To keep replication reliable, only replicate values that Roblox remotes can serialize safely. Good defaults:

- Primitive/value types: `number`, `string`, `boolean`
- Common Roblox datatypes: `Vector3`, `CFrame`, `Color3`, `UDim2`, `EnumItem`
- Instances *only when you truly want to reference an Instance on the client* (and understand replication/streaming implications)

Strongly avoid replicating:

- `function`, `thread`, userdata that isn’t a supported Roblox datatype
- Deep or large tables (especially with cycles, metatables, Instances, or mixed value types)

If you replicate a `table`, it must be a small, acyclic table containing only remote-serializable values. Note that `BaseEntity` will accept `Type = "table"`, but Roblox remotes may error or drop values if the contents aren’t serializable.

Tip: if you must replicate a table, prefer an array-like shape with numeric indices and primitive values (no mixed keys), and keep it small.

#### Client application of replicated updates

On the client, Orchestrator applies updates like this:

- It writes replicated properties directly into `entity._privateProperties.Data`.
- It then calls `entity:ApplyChanges(changes)`.

This is intentionally different from server-side updates:

- Clients do **not** populate `Pending`.
- Clients do **not** validate schema types on replication.

So your `ApplyChanges` implementation should be able to run on the client and should tolerate receiving replicated `changes` directly.

#### `ApplyChanges` patterns (server vs client)

Because `ApplyChanges` can run in **both** environments (server during `UpdateEntity()`, client when applying replicated packets), it helps to follow a consistent shape.

##### Pattern A: One `ApplyChanges`, split helpers by environment

Use this when you have both server-side mechanics (constraints, physics, authoritative instance changes) *and* client-side cosmetics (sounds, particles, UI hints).

```lua
-- ApplyChanges pattern A:
-- One ApplyChanges entry point, then split into environment-specific helpers.
local RunService = game:GetService("RunService")

function MyEntity:ApplyChanges(changes)
    if RunService:IsServer() then
        self:_ApplyServerChanges(changes)
    end

    if RunService:IsClient() then
        self:_ApplyClientVisuals(changes)
    end
end

function MyEntity:_ApplyServerChanges(changes)
    -- Example: authoritative mechanics (replicated Instance properties)
    if changes.TargetPosition ~= nil then
        local root = self.Instance:FindFirstChild("Root")
        if root and root:IsA("BasePart") then
            root.AssemblyLinearVelocity = (changes.TargetPosition - root.Position).Unit * 30
        end
    end
end

function MyEntity:_ApplyClientVisuals(changes)
    -- Example: client-only visuals
    if changes.Throttle ~= nil then
        local sound = self.Instance:FindFirstChild("EngineSound")
        if sound and sound:IsA("Sound") then
            sound.PlaybackSpeed = 1 + (changes.Throttle / 100)
        end
    end
end
```

Notes:

- Prefer `FindFirstChild`/nil-checks in `ApplyChanges`. Client entities may exist before all descendants stream in.
- Avoid client-only properties on the server (e.g. `LocalTransparencyModifier`, camera/UI, local particle rigs).

##### Pattern B: Client-only `ApplyChanges` (server no-op)

Use this when your entity’s schema represents **logical state**, but the entity’s `ApplyChanges` is purely cosmetic.

```lua
-- ApplyChanges pattern B:
-- Server commits + replicates; client renders visuals only.
local RunService = game:GetService("RunService")

function MyEntity:ApplyChanges(changes)
    if not RunService:IsClient() then
        return -- server commits Data and replicates; client renders
    end

    -- Only visuals here (safe to assume local context)
    if changes.IsOpen == true then
        -- play tween / sound / particles
    end
end
```

This keeps the server authoritative (it still commits Data and replicates), while preventing headless/server-only errors and “double playing” effects.

##### Pattern C: One-shot replicated effects (sound/particles) using a nonce

If you want the **server** to be authoritative about *when* an effect happens, replicate a counter/timestamp-like field instead of a boolean.

Schema:

```lua
-- Nonce pattern schema example:
-- Replicate a monotonically increasing counter to trigger a one-shot effect on clients.
Schema = {
    SfxNonce = { Type = "number", Replicate = true, Description = "Increment to trigger client SFX once" },
}
```

Server:

```lua
-- Nonce pattern server example:
-- Increment then commit; clients can detect "changed" and play SFX once.
entity.SfxNonce = (entity.SfxNonce or 0) + 1
entity:UpdateEntity()
```

Client `ApplyChanges`:

```lua
-- Nonce pattern client example:
-- Only play the effect when the nonce value changes.
local RunService = game:GetService("RunService")

function MyEntity:ApplyChanges(changes)
    if not RunService:IsClient() then return end

    if changes.SfxNonce ~= nil then
        local last = self.Context.LastSfxNonce or 0
        if changes.SfxNonce > last then
            self.Context.LastSfxNonce = changes.SfxNonce
            -- play sound/emit particles exactly once per increment
        end
    end
end
```

This avoids edge cases where a replicated boolean can get “stuck true” or where re-applying the same visual would be ambiguous.

#### Telemetry snapshot vs replication updates

This repo uses two different “networking paths”:

- **Telemetry/sync**: `ServiceManagerRemote:InvokeServer("GetSyncData")` returns a sanitized snapshot (functions replaced, deep tables truncated).
- **Replication**: `EntityUpdateRemote` broadcasts raw property updates (only schema keys with `Replicate = true`).

The snapshot path is designed for debug/inspection. The replication path is designed for keeping client-side entities visually in sync.

### Implementation Example: Jet Engine Entity

#### 1. Define the Subclass

```lua
-- Entity implementation example (Jet Engine):
-- Extend BaseEntity to define schema + ApplyChanges that maps data -> Instance effects.
local BaseEntity = require(path.to.BaseEntity)

local JetEntity = BaseEntity.Extend({
    Name = "JetEntity",
    Schema = {
        Throttle = { Type = "number", Description = "0 to 100 engine power" },
        Afterburner = { Type = "boolean", Description = "Toggle for extra thrust" },
        EngineModel = { Type = "Model", Description = "Reference to the physical engine" }
    }
})

-- Implement the visual application logic
function JetEntity:ApplyChanges(changes)
    if changes.Throttle ~= nil then
        -- Actual Roblox Instance manipulation
        self.Instance.EngineSound.Pitch = 1 + (changes.Throttle / 100)
    end

    if changes.Afterburner == true then
        self.Instance.Exhaust.Particles.Enabled = true
    elseif changes.Afterburner == false then
        self.Instance.Exhaust.Particles.Enabled = false
    end
end

return JetEntity
```

#### 2. Usage in Game Logic

```lua
-- Entity usage example:
-- Construct an entity, set schema fields (staged), then commit via UpdateEntity().
local JetClass = require(path.to.JetEntity)
local myJet = JetClass.new({
    Name = "F16_Alpha",
    Instance = workspace.F16_Model,
    OwnerId = "Pilot_01"
})

-- Setting properties (Validated against Schema)
myJet.Throttle = 80
myJet.Afterburner = true

-- Commit the changes to the physical world
myJet:UpdateEntity()
```

### Edge Cases & Safety

- **Type Mismatch**: If you attempt to set `myJet.Throttle = "Fast"`, the entity will catch the type error (Expected number, got string), log a WARN, and refuse to update the Pending table.

---

## Signal

The framework includes a high-performance pure Lua `Signal` class that replaces standard `BindableEvents` for internal messaging and public API hooks.

### Core Methods

- **`:Connect(handler)`**: Standard listener connection.

```lua
-- Signal.Connect example:
-- Connect registers a handler and returns a Connection-like object.
signal:Connect(function(msg) print(msg) end)
```

- **`:Once(handler)`**: One-time listener connection.

```lua
-- Signal.Once example:
-- Once registers a handler that auto-disconnects after the first Fire.
signal:Once(function() print("I only run once") end)
```

- **`:Fire(...args)`**: Dispatches data to all listeners.

```lua
-- Signal.Fire example:
-- Fire dispatches args to all listeners (typically via task.spawn).
signal:Fire("Hello World")
```

- **`:Wait()`**: Yields the current thread until the signal is fired.

```lua
-- Signal.Wait example:
-- Wait yields until Fire is called, then returns the fired args.
local msg = signal:Wait()
```

### Usage Example

```lua
-- Full Signal usage example:
-- Create a signal, subscribe, then fire an event with typed payload.
local Signal = require(path.to.Signal)
local onExploded = Signal.new()

onExploded:Connect(function(pos, power)
    print("Exploded at", pos, "with power", power)
end)

onExploded:Fire(Vector3.zero, 10)
```
- **Locking**: If a system calls `AcquireLock("SystemA")`, any call to `UpdateEntity("SystemB")` will fail. This is critical for ensuring that a "Stunned" state or "Disabled" state can prevent a player from controlling the entity.
- **Invalid Access**: Accessing properties of an entity after its Instance has been `Destroy()`'d will return nil and log a warning, preventing your scripts from crashing on "Index nil" errors.

---

## BehaviorTree

`BehaviorTree` is a decision-making engine designed to complement `BaseStateMachine`. It allows you to build complex AI brains using a hierarchical tree of conditions and actions, avoiding the "spaghetti" of state transitions in a raw FSM.

### Core Concepts

- **Selector**: Runs children in order until one **Succeeds** (Logical OR / Fallback).
- **Sequence**: Runs children in order until one **Fails** (Logical AND / Steps).
- **Inverter**: Flips Success to Failure and vice-versa.
- **Action**: A leaf node that performs a task (e.g., changing FSM state).
- **Condition**: A leaf node that returns Success/Failure based on a check.

### API Reference

#### `BT.Selector(children)`
Returns `Success` if any child succeeds (Logical OR).

```lua
-- BehaviorTree.Selector example:
-- Selector tries children in order until one returns Success/Running.
local checkTarget = BT.Selector({
    BT.Condition(function(fsm) return fsm.Target ~= nil end),
    BT.Condition(function(fsm) return fsm.NearbySound ~= nil end)
})
```

#### `BT.Sequence(children)`
Returns `Success` only if all children succeed (Logical AND).

```lua
-- BehaviorTree.Sequence example:
-- Sequence runs children in order; if any fails, the sequence fails.
local attemptAttack = BT.Sequence({
    BT.Condition(function(fsm) return fsm.HasWeapon end),
    BT.Condition(function(fsm) return fsm.Mana > 10 end),
    BT.SetState("Attacking")
})
```

#### `BT.SetState(stateName)`
An action node that sets the FSM's `State` to `stateName`. Always returns `Success`.

```lua
-- BehaviorTree.SetState example:
-- Returns a node that transitions the FSM to the target state.
BT.SetState("Fleeing")
```

#### `BT.Condition(predicate)`
Converts a boolean function into a BT node.

```lua
-- BehaviorTree.Condition example:
-- Wrap a predicate into a node that returns Success/Failure.
BT.Condition(function(fsm) 
    return fsm.Entity.Health < 50 
end)
```

### Usage Example: Guard AI

```lua
-- Guard AI example:
-- Build a decision tree that chooses an FSM state based on current context.
-- Requires Orchestrator:RegisterComponents() so shared.FSM.BehaviorTree is available.
local BT = shared.FSM.BehaviorTree

-- Define the brain
local guardBrain = BT.Selector({
    -- Priority 1: If health is low, retreat
    BT.Sequence({
        BT.Condition(function(fsm) return fsm.Entity.Health < 20 end),
        BT.SetState("Retreating")
    }),
    -- Priority 2: If we see a player, attack
    BT.Sequence({
        BT.Condition(function(fsm) return fsm.Context.HasTarget end),
        BT.SetState("Attacking")
    }),
    -- Priority 3: Otherwise, stay idle
    BT.SetState("Idle")
})

-- Run the brain inside an FSM state
function GuardJob:RegisterStates()
    self:AddState("Deciding", {
        OnHeartbeat = function(state, fsm, dt)
            guardBrain(fsm) -- The brain decides the next state
        end
    })
end
```

### Patterns

#### 1. The Transactional "Batch" Pattern

This is the intended primary use case. Instead of updating the Roblox Instance every time a variable changes (which can be expensive), you batch multiple changes and commit them in a single frame.

Pattern: State Authority -> Pending Changes -> Commit.

```lua
-- Transactional batch example:
-- Multiple schema writes are staged into Pending, then committed once.
-- Batching multiple changes
entity.Throttle = 100
entity.GearDown = false
entity.TargetVector = Vector3.new(0, 100, 0)

-- Only now does the physical Instance actually update
entity:UpdateEntity()
```

#### 2. The Concurrency "Lock" Pattern

Useful in multiplayer or complex AI environments where multiple systems might try to control the same entity. The lock ensures that only the "Authorized" system can call `UpdateEntity`.

Use Case: A "Stun" mechanic in combat.

```lua
-- Lock pattern example:
-- The lock id must match when committing changes, preventing competing systems.
if entity:AcquireLock("StunSystem") then
    entity.IsStunned = true
    entity:UpdateEntity("StunSystem")

    task.delay(2, function()
        if entity and entity.IsValid then
            entity.IsStunned = false
            entity:UpdateEntity("StunSystem")
            entity:ReleaseLock("StunSystem")
        end
    end)
end
```

#### 3. The "Ghost" State Pattern (Context Data)

Sometimes you need to store data that is relevant to the entity but not part of the physical Instance or the public Schema (e.g., a "LastTimeDamaged" timestamp). The `__call` syntax allows you to inject "Context" data.

Pattern: Internal metadata storage.

```lua
-- Using the __call metamethod to set context
entity({
    LastPosition = Vector3.new(0, 0, 0),
    IsInvulnerable = true
})

-- Accessing it later
if entity.IsInvulnerable then
    print("Cannot damage")
end
```

#### 4. The Observer Pattern (Instance Tracking)

The BaseEntity automatically listens to `AncestryChanged`. This pattern ensures that if a Part is deleted from the workspace (by a player, a script, or falling into the Void), the Lua object cleans itself up immediately to prevent memory leaks.

Pattern: Self-destructing objects.

```lua
-- No manual cleanup required: destroying the Instance invalidates the entity
workspace.F16_Model:Destroy()

-- If you need to react, use the entity's Destroyed signal:
entity.Destroyed:Connect(function()
    print("Entity destroyed; stop AI, release references, etc.")
end)

-- You can also defensively check validity before using it:
if not entity.IsValid then
    return
end
```

#### 5. The Schema Enforcement Pattern

This pattern is used to prevent "Type Safety" bugs that are common in vanilla Luau. It acts as a gatekeeper, ensuring that data sent to the entity is valid before it ever reaches the physics engine.

Pattern: Fail-fast validation.

| Input Value | Schema Requirement | Result |
| :--- | :--- | :--- |
| `100` | `Type = "number"` | Success (Added to Pending) |
| `"100"` | `Type = "number"` | Fail (Logs Error, Value Ignored) |
| `workspace.Part` | `Type = "BasePart"` | Success (Using `IsA` check) |

#### 6. The Controller-Entity Pattern

This is the most powerful pattern, where the BaseStateMachine acts as the "Brain" and the BaseEntity acts as the "Body."

Implementation:

1. The StateMachine (Brain) decides the jet should "Takeoff."
2. It calculates the necessary Throttle and Pitch.
3. It writes these values to the Entity (Body).
4. The Entity updates the sounds, particles, and VectorForces.

Summary of Patterns:

| Pattern | Purpose | When to use |
| :--- | :--- | :--- |
| Transactional | Performance | High-frequency physics/visual updates. |
| Locking | Synchronization | Prevent "Fighting" between AI and Player. |
| Context | Metadata | Storing non-physical logic data. |
| Observer | Memory Safety | Managing life-cycles of temporary entities. |
| Schema | Type Safety | Large teams or complex data structures. |

Controller↔Entity example (FSM writes schema fields, Entity applies visuals):

```lua
-- In a StateMachine state (server)
self:AddState("Takeoff", {
    OnEnter = function(state, fsm)
        local entity = fsm.Context.Entity
        entity.Throttle = 100
        entity.GearDown = false
        entity:UpdateEntity()

        fsm.WaitSpan = 2
        fsm.State = "InFlight"
    end,
})
```

---

## Scheduler

The Scheduler is a high-performance utility designed to handle asynchronous execution and recurring logic with a focus on Frame Budgeting. It acts as the "Traffic Controller" for your game's CPU time, ensuring that heavy tasks don't cause frame drops.

### API Reference

#### `Scheduler.new(settings?)`

Creates a new scheduler instance.

- **settings**: optional settings table. `FrameBudget` is the most commonly tuned option.

#### `scheduler:Start()`

Connects the scheduler to RunService signals and begins calling `scheduler:Step(eventName)` automatically.

Events supported by default:

- Server and client: `Heartbeat`, `Stepped`, `PreSimulation`, `PostSimulation`
- Client only: `RenderStepped`

#### `scheduler:Schedule(params)`

Schedules a task.

- **params**: `{ TaskName, TaskAction, TaskExecutionDelay?, IsRecurringTask?, Priority?, Event? }`
    - `TaskName: string` (unique key; scheduling another task with the same name overwrites the previous)
    - `TaskAction: () -> ()` (executed via `task.spawn`)
    - `TaskExecutionDelay: number?` (seconds; default `0`)
    - `IsRecurringTask: boolean?` (default `false`)
    - `Priority: number?` (default `1`; higher number runs first among tasks due in the same Step)
    - `Event: string?` (default `"Heartbeat"`; must match a signal name that `Start()` wires)

Returns the created Task object (or `nil` if invalid).

#### Common helpers

##### `scheduler:Deschedule(name)`

Cancels a scheduled task by name.

```lua
-- Scheduler helper example:
-- Remove a pending/recurring task from the schedule.
scheduler:Deschedule("DelayedAction")
```

##### `scheduler:ExecuteTask(taskOrName)`

Executes a task immediately, bypassing any scheduled delay.

```lua
-- Scheduler helper example:
-- Run a task now (useful for admin tooling or urgent work).
scheduler:ExecuteTask("DelayedAction")
```

##### `scheduler:GetTask(name)`

Returns the task object for the given name.

```lua
-- Scheduler helper example:
-- Fetch the task object (for inspection/resetting counters/etc.).
local taskObj = scheduler:GetTask("MyTask")
```

##### `scheduler:GetTaskCount()`
Returns the total number of scheduled tasks.

##### `scheduler:Clear()`
Removes all scheduled tasks.

##### `scheduler:GenerateKey()`
Generates a unique GUID for task naming.

```lua
-- Scheduler helper example:
-- Generate a unique name/key if you don't want to hand-author task names.
local key = scheduler:GenerateKey()
```

### Configuration

#### Frame budget

Frame budgeting is **configurable** per scheduler instance via `Settings.FrameBudget`.

- Unit: **seconds** per `Step(...)` call (per event)
- Default in constructor: `0.005` (5ms)
- Fallback in `Step` if missing: `0.002` (2ms)

You can configure it at creation:

```lua
-- Scheduler configuration example:
-- Set FrameBudget at construction time (seconds per Step).
shared.FSM.Scheduler = shared.FSM.Scheduler.new({ FrameBudget = 0.010 })
```

Or at runtime:

```lua
-- Scheduler configuration example:
-- Adjust FrameBudget on the live scheduler instance.
shared.FSM.Scheduler.Settings.FrameBudget = 0.010
```

Important: the budget limits how much work the scheduler *dispatches* per frame. Tasks still run in spawned threads, so very heavy/yielding tasks can still cause overall CPU pressure.

#### Orchestrator / ServiceManager settings

If you expose the scheduler API, settings can also be updated via the debug remotes (admin-gated). Treat this as a tooling path, not a gameplay dependency.

### Performance Characteristics

- Uses a min-heap per event, sorted by `NextRun`, to efficiently find due tasks.
- When multiple tasks are due at once, it sorts the ready list by `Priority` (higher runs first).
- **Task Aging (Fairness)**: To prevent **Priority Starvation**, deferred tasks gain an "Effective Priority" boost over time: `Priority + (ConsecutiveDelays * AgingFactor)`.
- Uses a "lazy removal" strategy: cancelled/overwritten tasks are removed from the heap when encountered.

### Priority Strategy (High / Medium / Low)

Use priority to reflect *urgency* and *user-visible impact* rather than task complexity:

- **High**: Player-facing responsiveness (input handling, critical gameplay state, near-camera AI).
- **Medium**: Regular gameplay logic that should stay timely but can slip under load (AI updates, periodic scans).
- **Low / Background**: Non-critical maintenance (analytics, far-away AI, cleanup, autosave triggers).

Guidelines to avoid **priority starvation**:

- Keep **high-priority** tasks short and bounded.
- Stagger recurring tasks with small randomized delays.
- Prefer lower priorities for large batches; the aging system will eventually lift them.
- If a low-priority task becomes time-sensitive, temporarily raise its priority only for that window.

### Known Limitations

- **Name collisions overwrite**: tasks are keyed by `TaskName`. Use `scheduler:GenerateKey()` or a naming convention to avoid collisions.
- **Burst scheduling has overhead**: if thousands of tasks become due simultaneously, sorting and dispatching can be noticeable.
- **Thread-per-task dispatch**: each task runs via `task.spawn`. Keep task bodies short and bounded; avoid unbounded yields inside tight recurring tasks.

### 4. Use Case Patterns for Flight Simulation

#### Pattern: The Budgeted Physics Sub-Step

Use this to run complex lift/drag calculations that don't need to happen every single frame but are too heavy for a simple Heartbeat loop.

```lua
-- Scheduler pattern example (budgeted sub-step):
-- Schedule a recurring task that runs at a fixed cadence within the scheduler's frame budget.
local LuaScheduler = shared.FSM.Scheduler
LuaScheduler:Schedule({
    TaskName = "ComplexAeroUpdate",
    TaskAction = function()
        -- Heavy math involving Floating Origin and multi-part lift
        CalculateAdvancedLift(JetEntity)
    end,
    TaskExecutionDelay = 0.1, -- Run 10 times a second
    IsRecurringTask = true,
    Priority = 10 -- High priority
})
```

#### Pattern: The Background "Garbage" Collector

Run non-essential tasks (like updating a far-away AI's state) at a very low priority with a strict budget.

```lua
-- Scheduler pattern example (background maintenance):
-- Low priority + long delay lets this work slip under load without impacting players.
local LuaScheduler = shared.FSM.Scheduler
LuaScheduler:Schedule({
    TaskName = "FarAwayAICleanup",
    TaskAction = function()
        -- Logic that can afford to be delayed if the game is lagging
    end,
    Priority = 1, -- Low priority
    IsRecurringTask = true,
    TaskExecutionDelay = 5
})
```

### 5. Summary Table

| Feature | Impact | Developer Benefit |
| :--- | :--- | :--- |
| Heap-based Queue | High Performance | Handles thousands of tasks with minimal CPU cost. |
| Frame Budgeting | Stability | Prevents frame-rate spikes during heavy operations. |
| `xpcall` Wrapper | Reliability | One crashing task won't stop the entire scheduler. |
| API Exposure | Observability | Allows for real-time debugging via admin consoles. |

### Comprehensive Use Cases & Architectural Patterns

#### 1. The Frame-Budgeting Pattern

This is the most critical use case for performance-intensive games (like flight simulators). Instead of executing all "due" tasks and potentially causing a frame spike, the scheduler pauses execution once a time limit (e.g., 5ms) is reached.

Pattern: High-Volume, Low-Urgency Processing.

Use Case: Updating the AI of 100 far-away surface-to-air missile (SAM) sites.

Benefit: Even if the AI logic is heavy, the player's FPS remains stable because the scheduler defers the remaining AI updates to the next frame.

Example (dispatch many tasks, let the budget spread them out):

```lua
-- Scheduler pattern example (frame budgeting):
-- Fan out many small tasks; the scheduler spreads dispatch across frames.
local scheduler = shared.FSM.Scheduler
-- Tight budget to demonstrate deferral
scheduler.Settings.FrameBudget = 0.002

-- Imagine you have a lot of NPCs to scan; schedule each scan as its own task.
for _, npc in ipairs(workspace.NPCs:GetChildren()) do
    local id = npc:GetAttribute("NpcId") or npc.Name
    scheduler:Schedule({
        TaskName = "NPCScan_" .. tostring(id),
        Event = "Heartbeat",
        Priority = 1,
        TaskExecutionDelay = 0, -- due immediately
        TaskAction = function()
            -- Keep this bounded; expensive work should be chunked further.
            -- DoScan(npc)
        end,
    })
end
```

#### 2. The Recurring Heartbeat Pattern

Used to replace standard `while true do` loops. By using the scheduler, you gain centralized logging and the ability to "pause" or "reset" the loop externally.

Pattern: Consistent State Polling.

Use Case: A jet's fuel consumption logic that subtracts fuel every 1 second.

```lua
-- Scheduler pattern example (recurring task):
-- Replace while-loops with a named recurring task you can inspect/reset.
local LuaScheduler = shared.FSM.Scheduler
LuaScheduler:Schedule({
    TaskName = "FuelConsumption",
    TaskAction = function() Jet.Fuel -= Rate end,
    TaskExecutionDelay = 1,
    IsRecurringTask = true
})
```

#### 3. The Priority-Queue Pattern

Not all tasks are created equal. This pattern ensures that "Critical" logic (like landing gear physics) runs before "Flavor" logic (like updating a cockpit clock), even if they are due at the same time.

Pattern: Tiered Execution.

Use Case: Prioritizing InputHandling (Priority 10) over CloudRenderingUpdates (Priority 1).

Behavior: The scheduler sorts the "Ready" heap by Priority before execution.

Example (higher priority runs first among tasks due the same Step):

```lua
-- Scheduler pattern example (priority queue):
-- Multiple due tasks are dispatched in Priority order (higher first).
local scheduler = shared.FSM.Scheduler

-- Both tasks are due after 0.2s; the higher Priority should dispatch first.
scheduler:Schedule({
    TaskName = "UpdateCockpitClock",
    Priority = 1,
    TaskExecutionDelay = 0.2,
    IsRecurringTask = false,
    Event = "Heartbeat",
    TaskAction = function() print("Clock") end,
})

scheduler:Schedule({
    TaskName = "LandingGearPhysics",
    Priority = 10,
    TaskExecutionDelay = 0.2,
    IsRecurringTask = false,
    Event = "Heartbeat",
    TaskAction = function() print("Landing gear") end,
})
```

#### 4. The "Throttled" API Pattern

Prevents your game from hitting Roblox rate limits (like HttpService or DataStore limits) by spacing out requests over time.

Pattern: Resource Conservation.

Use Case: Saving player data or sending analytics.

Implementation: Instead of saving immediately on every change, schedule a "Save" task with a 30-second delay that gets overwritten (reset) every time a new change occurs.

Example (debounced save using name overwrite):

```lua
-- Scheduler pattern example (throttled/debounced API):
-- Use a stable TaskName so re-scheduling overwrites the pending save, acting like a debounce.
local scheduler = shared.FSM.Scheduler

local function ScheduleSave(userId)
    -- Re-scheduling with the same TaskName overwrites/resets the task.
    scheduler:Schedule({
        TaskName = "SavePlayer_" .. tostring(userId),
        TaskExecutionDelay = 30,
        IsRecurringTask = false,
        Priority = 5,
        Event = "Heartbeat",
        TaskAction = function()
            -- SavePlayerData(userId)
        end,
    })
end

-- Call this whenever player data changes.
ScheduleSave(player.UserId)
```

#### 5. The Garbage Collection & Cleanup Pattern

Used for managing temporary objects that shouldn't exist forever, but don't need to be deleted immediately after use.

Pattern: Delayed Disposal.

Use Case: Deleting missile "Debris" parts 10 seconds after an explosion.

Benefit: Centralizing this in the scheduler allows you to see exactly how many "Cleanup" tasks are pending in your performance stats.

Example (delete debris after N seconds):

```lua
-- Scheduler pattern example (delayed disposal):
-- Schedule a one-shot cleanup task to destroy an Instance after a delay.
local scheduler = shared.FSM.Scheduler

local function ScheduleDestroy(instance, delaySeconds)
    local taskName = "Cleanup_" .. scheduler:GenerateKey()
    scheduler:Schedule({
        TaskName = taskName,
        TaskExecutionDelay = delaySeconds,
        Event = "Heartbeat",
        TaskAction = function()
            if instance and instance.Parent then
                instance:Destroy()
            end
        end,
    })
    return taskName
end

local debris = Instance.new("Part")
debris.Parent = workspace
ScheduleDestroy(debris, 10)
```

#### 6. The Distributed Load Pattern (Staggering)

If you have 10 systems that all need to run every 1 second, you shouldn't run them all on the same frame. This pattern uses `math.random()` or offsets to "stagger" the NextRun times.

Pattern: Load Balancing.

Use Case: 50 NPCs checking for the nearest player.

Result: By giving each NPC a slightly different start delay, you distribute the CPU load evenly across 60 frames instead of 1.

Example (stagger recurring NPC sensing loops):

```lua
-- Scheduler pattern example (distributed load):
-- Stagger start offsets so recurring tasks don't all run on the same frame.
local scheduler = shared.FSM.Scheduler

for _, npc in ipairs(workspace.NPCs:GetChildren()) do
    local id = npc:GetAttribute("NpcId") or npc.Name
    local startOffset = math.random() -- 0..1 second offset

    scheduler:Schedule({
        TaskName = "Sense_" .. tostring(id),
        Event = "Heartbeat",
        IsRecurringTask = true,
        TaskExecutionDelay = 1 + startOffset,
        Priority = 1,
        TaskAction = function()
            -- SenseNearestPlayer(npc)
        end,
    })
end
```

#### 7. The "Retry-with-Backoff" Pattern

Used for tasks that might fail due to external factors (like a raycast not hitting a streaming part yet).

Pattern: Resilience.

Use Case: Attempting to lock a target. If the raycast fails because the terrain hasn't loaded, the task reschedules itself with an increased delay.

Example (self-rescheduling with exponential backoff):

```lua
-- Scheduler pattern example (retry with backoff):
-- A task can re-schedule itself with increasing delays until it succeeds.
local scheduler = shared.FSM.Scheduler

local function ScheduleRaycastWithBackoff(name, origin, direction)
    local attempt = 0

    local function try()
        attempt += 1
        local result = workspace:Raycast(origin, direction)
        if result then
            -- Success path
            -- HandleHit(result)
            return
        end

        -- Backoff: 0.1s, 0.2s, 0.4s, 0.8s ... clamped
        local delaySeconds = math.min(2, 0.1 * (2 ^ (attempt - 1)))
        scheduler:Schedule({
            TaskName = name,
            TaskExecutionDelay = delaySeconds,
            Event = "Heartbeat",
            Priority = 5,
            TaskAction = try,
        })
    end

    -- initial attempt
    scheduler:Schedule({
        TaskName = name,
        TaskExecutionDelay = 0,
        Event = "Heartbeat",
        Priority = 5,
        TaskAction = try,
    })
end

ScheduleRaycastWithBackoff("AcquireTarget_01", Vector3.new(), Vector3.new(0, -500, 0))
```

Summary of Scheduler Use Cases:

| Pattern | Primary Benefit | Jet Framework Example |
| :--- | :--- | :--- |
| Budgeting | FPS Stability | Aerodynamic lift calculations for large fleets. |
| Recurring | Logic Control | Engine temperature and heat-soak simulation. |
| Priority | Responsiveness | Flight control inputs always override UI updates. |
| Staggering | CPU Leveling | Distributing radar scans for multiple wingmen. |
| Cleanup | Memory Safety | Removing spent shell casings and flare particles. |

---

## Logger

The Logger is a lightweight, standardized logging utility used by the framework and exposed for your own code.

Key behaviors:

- Stores recent log entries in-memory (`History`) with a fixed max size.
- Supports `OperationId` (string) to correlate logs across multi-step flows (e.g., a StateMachine run).
- Can optionally format output with timestamps and (optionally) rich text.
- Can be disabled at runtime by setting `logger.Enabled = false`.

### API Reference

#### `Logger.new(params)`
Creates a new Logger instance.

```lua
-- Create a named Logger instance (useful for tagging/correlating logs).
local logger = Logger.new({ Name = "AI_Controller" })
```

#### `logger:Log(params)`
Logs a message.

```lua
-- Log a structured entry (level/message/operation id + optional data payload).
logger:Log({ 
    Level = "INFO", 
    Message = "Character spawned", 
    OperationId = "Spawn_001",
    Data = { Pos = Vector3.new(0, 10, 0) }
})
```

#### `logger:GetHistory()`
Returns the log history array.

```lua
-- Read back the in-memory history (bounded by Logger max history size).
local history = logger:GetHistory()
print("Total logs:", #history)
```

### Configuration

The Logger has a few simple module-level toggles (timestamp display, rich text, max history). If you need per-game configuration, treat these as constants you can customize in your fork.

### Framework integration points

- Entities call `entity:Log(params)` which delegates into the entity's internal Logger instance.
- StateMachines call `fsm:Log(params)` (and core code uses the shared logger singleton for framework-level logs).

## Orchestrator

The Orchestrator is the Central Nervous System of the framework. It serves as a unified Registry, Factory, and Lifecycle Manager that connects the BaseEntity, BaseStateMachine, and Scheduler into a single, cohesive engine.

### Core Roles

- **Dependency Injection**: Injects core modules into the shared global space for easy access across the project.
- **Instance Registry**: Tracks every active Entity and StateMachine by a unique ID to prevent duplicates and allow global retrieval.
- **Lifecycle Management**: Handles the instantiation, error-trapping (`xpcall`), and automatic destruction of components.
- **Remote Observability**: Provides a sanitized API for external tools (like a Service Manager UI) to inspect the live state of the server.

### API Reference

#### Initialization

##### `Orchestrator:RegisterComponents()`

Initializes the framework and compiles your registered classes into the shared registries.

What it does (current implementation):

1. Creates `shared.FSM` (and assigns `shared.Logger`, `shared.Signal`, and a `shared.FSM.Scheduler` instance).
2. Requires the bundled Factory (shipped inside Orchestrator).
3. Reads definitions from:
    - `ReplicatedStorage/Entity/EntityRegistry`
    - `ReplicatedStorage/StateMachine/StateMachineRegistry`
4. Compiles those definitions into classes via `BaseEntity.Extend(...)` and `BaseStateMachine.Extend(...)`.
5. Populates `shared.Entity` and `shared.StateMachine` with the compiled classes.

Important: `RegisterComponents()` compiles **definitions**, but it does not automatically require your optional “implementation modules” (the scripts where you attach `ApplyChanges`, `GetContext`, `RegisterStates`, etc.). You should require those yourself (after `RegisterComponents()`), on the server and/or client depending on where the behavior should exist.

Client behavior (current implementation): calling `RegisterComponents()` on the client will also:

- call `Orchestrator.InitClientListeners()`
- invoke `ServiceManagerRemote:InvokeServer("RequestEntitySnapshot")` to seed existing entities

Manual control note:

- In the current implementation, there is **no** “register-only” mode for clients: you cannot populate `shared.Entity` / `shared.StateMachine` via `RegisterComponents()` without also wiring listeners and making the snapshot request.
- If you need to delay networking (e.g., until a loading screen finishes), delay calling `RegisterComponents()` until you’re ready.
- Avoid calling `InitClientListeners()` manually if you already called `RegisterComponents()`; otherwise you can double-wire listeners.
- If you want fine-grained control (register now, connect listeners later), you’ll need to split this behavior in your fork (e.g., add a flag or separate methods).

### Runtime Context: Shared vs Server vs Client

Orchestrator contains a mix of methods that are:

- **Shared** (safe to call on either server or client)
- **Server-only** (only does work on the server)
- **Client-only** (only does work on the client)

#### Shared methods (server + client)

##### `Orchestrator.CreateEntity(params)`
Creates or retrieves a unique Entity.

```lua
-- Create (or retrieve) an Entity by a stable ID.
local myEntity = Orchestrator.CreateEntity({
    EntityClass = shared.Entity.BotEntity,
    EntityId = "Bot_01",
    Context = { Instance = somePart }
})
```

##### `Orchestrator.CreateStateMachine(params)`
Creates or retrieves a unique StateMachine.

```lua
-- Create (or retrieve) a StateMachine by a stable ID, passing any needed Context.
local myFSM = Orchestrator.CreateStateMachine({
    StateMachineClass = shared.StateMachine.BotFSM,
    StateMachineId = "Bot_FSM_01",
    Context = { Entity = myEntity }
})
```

##### `Orchestrator.RetryStateMachine(stateMachineId)`
Restarts a StateMachine from its initial state using its existing context.

```lua
-- Restart a previously-created StateMachine from its initial state.
Orchestrator.RetryStateMachine("Bot_FSM_01")
```

##### `Orchestrator.GetEntity(entityId)` / `Orchestrator.GetEntities()`
Retrieves active entities.

```lua
-- Fetch a single Entity by ID (or enumerate all active Entities).
local entity = Orchestrator.GetEntity("Bot_01")
local allEntities = Orchestrator.GetEntities()
```

##### `Orchestrator.GetStateMachine(stateMachineId)` / `Orchestrator.GetStateMachines()`
Retrieves active StateMachines.

```lua
-- Fetch a single StateMachine by ID.
local fsm = Orchestrator.GetStateMachine("Bot_FSM_01")
```

##### `Orchestrator.CancelStateMachine(stateMachineId)`
Stops a StateMachine and signals cancellation.

```lua
-- Stop a running StateMachine and mark it as cancelled.
Orchestrator.CancelStateMachine("Bot_FSM_01")
```

##### `Orchestrator.DeleteEntity(entityId)`
Destroys an entity and removes it from the registry.

```lua
-- Destroy an Entity and remove it from Orchestrator's tracking.
Orchestrator.DeleteEntity("Bot_01")
```

Notes:

- These functions exist in both environments, but their side-effects differ.
- For example, `CreateEntity` will register entities locally on the client (for visuals), while the server is the authority that drives updates and replication.

#### Server-only methods

- `Orchestrator.StartServiceManagerAPI()`
- `Orchestrator.HandleReplication(entityId, changes, schema)`

The server also triggers the creation of remotes and emits server-to-client events.

#### Client-only methods

- `Orchestrator.InitClientListeners()`

This wires `ServiceManagerEvent` and `EntityUpdateRemote` listeners and applies updates to client-side entities.

### Client Bootstrapping (LocalScript example)

The server-side boot flow is straightforward (`RegisterComponents`, create Entities/StateMachines). Client setup typically needs two things:

1. Register shared module references.
2. Start listeners and request an initial snapshot so the client can spawn local entities before updates arrive.

In the current implementation, `Orchestrator:RegisterComponents()` already does both steps on the client (it calls `InitClientListeners()` and invokes `RequestEntitySnapshot`).

Example structure (StarterPlayerScripts LocalScript):

```lua
-- Client boot: require Orchestrator and register components.
-- Note: on the client, RegisterComponents() also wires listeners and requests a snapshot.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local Orchestrator = require(SharedModules:WaitForChild("Orchestrator"))

Orchestrator:RegisterComponents()
```

Notes:

- Avoid calling `InitClientListeners()` manually if you are already calling `RegisterComponents()` on the client; otherwise you can end up with duplicate connections.
- If you don't want the snapshot path in production, you can disable it (or gate it) and rely on server-spawn events + replication updates.
- The telemetry snapshot (`GetSyncData`) is for inspection and may truncate data; use `RequestEntitySnapshot` for client seeding.

### Entity Replication System (Detailed)

Orchestrator’s entity replication is based on three parts:

1. **Entities fire `StateUpdated(changes)`** after a successful `UpdateEntity()`.
2. **Orchestrator listens to `StateUpdated`** (server-side) and filters changes using schema metadata.
3. **Clients receive and apply the filtered changes**.

#### End-to-end flow

Server:

1. Server code sets schema fields on an entity and calls `entity:UpdateEntity()`.
2. `entity.StateUpdated` fires with the committed `changes` table.
3. Orchestrator receives that event and calls `Orchestrator.HandleReplication(entityId, changes, entity:GetValidProperties())`.
4. `HandleReplication` builds an `updatePacket` containing only keys where `schema[key].Replicate == true`.
5. Orchestrator broadcasts `EntityUpdateRemote:FireAllClients(entityId, updatePacket)`.

Client:

1. `EntityUpdateRemote.OnClientEvent` receives `(entityId, updatePacket)`.
2. Orchestrator finds the local entity via `Orchestrator.GetEntity(entityId)`.
3. It writes packet values directly into `entity._privateProperties.Data`.
4. It calls `entity:ApplyChanges(updatePacket)` to update visuals.

Design implications:

- Replication is server → client only; there is no built-in “client submits entity changes” API.
- Replication is **schema-driven** and **field-level opt-in** via `Replicate = true`.
- Clients bypass schema validation during replication; the server must ensure replicated values are safe.

Replication transport (current implementation):

- Uses `RemoteEvent`s (`EntityUpdateRemote` and `ServiceManagerEvent`) and a `RemoteFunction` (`ServiceManagerRemote`).
- It does not use Attributes or ValueObjects.
- BaseEntity does not automatically replicate by itself; replication happens because Orchestrator listens to `entity.StateUpdated` on the server and then emits RemoteEvents.

### Client→Server Input (Command Pattern)

The framework provides a built-in Command Pattern to allow clients to request authoritative changes on the server.

#### `Orchestrator.SendCommand(entityId, command, ...)`
(Client-only) Sends a command to the server for a specific entity.

```lua
-- On Client
Orchestrator.SendCommand("Door_01", "Open", "Keycard_01")
```

#### `Orchestrator.RegisterCommandHandler(entityId, command, handler)`
(Server-only) Registers logic to handle a client command.

```lua
-- On Server
Orchestrator.RegisterCommandHandler("Door_01", "Open", function(player, keyUsed)
    local door = Orchestrator.GetEntity("Door_01")
    if keyUsed == "Keycard_01" then
        door.IsOpen = true
        door:UpdateEntity()
    end
end)
```

---

### Entity Pooling

 pooling is used to recycle entities instead of destroying them, reducing GC pressure.

#### `Orchestrator.PoolEntity(entityId)`
Deactivates an entity and adds it to the internal pool for its class.

```lua
-- Deactivate and pool an Entity for later reuse (reduces GC).
Orchestrator.PoolEntity("Bullet_101")
```

#### `Orchestrator.GetPooledEntity(params)`
Retrieves an entity of the specified class from the pool, or creates a new one if empty.

```lua
-- Retrieve an Entity from the pool (or create one) and re-bind its Context.
local bullet = Orchestrator.GetPooledEntity({
    EntityClass = shared.Entity.Bullet,
    EntityId = "Bullet_102",
    Context = { Instance = bulletPart }
})
```

Keep commands replication-safe (primitive values), and never trust the client to directly mutate authoritative state.

### ServiceManager Remote API (Debug/Inspection)

Orchestrator also exposes a `RemoteFunction` API intended for telemetry and debugging:

- RemoteFunction: `ServiceManagerRemote`
- RemoteEvent: `ServiceManagerEvent`

Request types handled on the server include:

- `"GetSyncData"`: returns a sanitized snapshot (StateMachines, Entities, logs, history, and optional Scheduler sync)
- `"UpdateSettings"`: updates scheduler settings (if `shared.FSM.Scheduler` exists)
- `"FSM"`: management actions like cancelling/retrying machines
- `"ConsoleCommand"`: simple server-side console commands and forwarding to Scheduler
- `"Scheduler"`: forwards actions into Scheduler (if present)
- `"RequestEntitySnapshot"`: returns enough data for clients to spawn existing entities and seed `Data`

Security note: `ServiceManagerRemote` does not enforce an admin check by default. If you ship this in a live game, add an authorization gate.

Production guidance (strongly recommended):

- Treat `ServiceManagerRemote` as a **debug backdoor** until proven otherwise.
- Gate every request type by authorization (user allowlist, group rank, private server owner, etc.) and consider disabling entirely outside Studio.
- Assume any client can attempt to call it; never expose write actions (UpdateSettings / ConsoleCommand / Scheduler actions) without checks.

If you build an admin panel, also rate-limit these requests to avoid accidental performance issues.

Example (gate ServiceManagerRemote without modifying the framework):

```lua
-- ServerScriptService: run after Orchestrator:RegisterComponents() (so OnServerInvoke is set)
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ServiceManagerRemote = ReplicatedStorage:WaitForChild("ServiceManagerRemote")
local original = ServiceManagerRemote.OnServerInvoke

local ADMIN_USER_IDS = {
    [12345678] = true,
}

local function isAdmin(player)
    return ADMIN_USER_IDS[player.UserId] == true
end

ServiceManagerRemote.OnServerInvoke = function(player, requestType, ...)
    if not isAdmin(player) then
        return nil
    end
    if original then
        return original(player, requestType, ...)
    end
    return nil
end
```



##### `Orchestrator.RetryStateMachine(id)`

Performs a "Warm Restart." It destroys the existing StateMachine and immediately creates a new one using the same Context data. This is ideal for resetting logic without losing the Entity's state (e.g., restarting an AI brain while the NPC stays in the same position).

##### `Orchestrator.DeleteAllEntities()`

Destroys all tracked Entities and clears the registry.

##### `Orchestrator.CancelAll()`

Cancels/destroys all tracked StateMachines and clears the registry.

### Architectural Patterns

#### 1. The "Brain-Body" Linkage

The most common pattern is using the Orchestrator to link a physical Entity (the body) to a StateMachine (the brain).

```lua
-- Create the Body
local myJet = Orchestrator.CreateEntity({
    EntityClass = shared.Entity.Jet,
    EntityId = "Alpha-1",
    Context = { Instance = jetModel }
})

-- Create the Brain and pass the Body into the Context
Orchestrator.CreateStateMachine({
    StateMachineClass = shared.StateMachine.JetAI,
    StateMachineId = "Alpha-1-Brain",
    Context = { Entity = myJet }
})
```

#### 2. The Singleton Service

Use the Orchestrator to manage global services that should only run once, such as a Round Manager or Weather Controller. By providing a hardcoded ID, you ensure only one instance ever exists.

Example (idempotent creation):

```lua
-- Idempotently create/get a global service StateMachine by using a fixed ID.
local serviceA = Orchestrator.CreateStateMachine({
    StateMachineClass = shared.StateMachine.WeatherSystem,
    StateMachineId = "GLOBAL_WEATHER_SERVICE",
})

-- Later (or in another script): you get the same instance back.
local serviceB = Orchestrator.CreateStateMachine({
    StateMachineClass = shared.StateMachine.WeatherSystem,
    StateMachineId = "GLOBAL_WEATHER_SERVICE",
})

assert(serviceA == serviceB)
```

#### 3. Remote Inspection (The "God View")

The Orchestrator includes a `Sanitize` function that prepares complex Lua tables for network transmission. This allows developers to view a "Snapshot" of the game's logic from a client-side debug console.

Important: the framework provides the *data path* (`GetSyncData` / events), but it does not include a built-in visual debugger UI or Roblox plugin. You implement the admin panel/UI yourself.

| Data Type | Sanitization Result |
| :--- | :--- |
| Function | Replaced with string "function" (prevents remotes from erroring). |
| Instance | Passed as reference (Roblox handles this). |
| Deep Tables | Truncated at depth 3 to prevent network congestion. |

Example (client debug poll loop):

```lua
-- StarterPlayerScripts (admin-only UI / debug)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServiceManagerRemote = ReplicatedStorage:WaitForChild("ServiceManagerRemote")

local function Refresh()
    local sync = ServiceManagerRemote:InvokeServer("GetSyncData")
    if not sync or not sync.FSM then return end

    for id, sm in pairs(sync.FSM.StateMachines or {}) do
        print(id, sm.Name, sm.State)
    end
end

task.spawn(function()
    while task.wait(1) do
        Refresh()
    end
end)
```

### Lifecycle Flow

1. **Creation**: Orchestrator validates parameters and calls `.new()`.
2. **Tracking**: The instance is added to the internal registry.
3. **Active State**: The component runs, sending StateChanged signals to the Orchestrator.
4. **Auto-Cleanup**: Upon completion or failure, the Orchestrator calls `:Destroy()` and removes the reference from the registry to allow for garbage collection.

### Summary Table

| Method | Role | Best For |
| :--- | :--- | :--- |
| `RegisterComponents` | Bootloader | System startup/setup. |
| `CreateStateMachine` | Factory | Spawning AI, Missions, or Character logic. |
| `CreateEntity` | Factory | Spawning Vehicles, NPCs, or interactive objects. |
| `RetryStateMachine` | Recovery | Debugging or resetting stuck logic. |
| `CancelAll` | Emergency | Round transitions or server shutdowns. |

### Orchestrator Patterns (Expanded)

#### 1. The "Singleton Service" Pattern

Some systems should only ever have one instance running (e.g., a MatchManager or EnvironmentController). By providing a static string ID to the Orchestrator, you guarantee that any subsequent call to "create" that service simply returns the existing one.

Pattern: Global State Authority.

Developer Action: Hardcode the StateMachineId.

Why: Prevents accidental duplicate loops from running, which could leak memory or double-process logic.

```lua
-- No matter how many times this runs, only one "WeatherService" exists.
local weather = Orchestrator.CreateStateMachine({
    StateMachineClass = shared.StateMachine.WeatherSystem,
    StateMachineId = "GLOBAL_WEATHER_SERVICE"
})
```

#### 2. The "Body-Brain" (Entity-FSM) Coupling

The Orchestrator is designed to link the Body (BaseEntity) and the Brain (BaseStateMachine). This pattern ensures that logic and data remain decoupled but communicative.

Pattern: Component Synchronization.

Developer Action: Pass the Entity object into the StateMachine's Context.

Why: This allows you to swap out the "Brain" (AI vs. Player control) without ever touching the "Body" (the Jet's physics and parts).

Example (swap brains, keep body):

```lua
-- Swap a StateMachine ("brain") while keeping the same Entity ("body").
local entity = Orchestrator.GetEntity("Alpha-1")
if not entity then return end

-- Cancel old brain (if any)
local brainId = "Alpha-1-Brain"
Orchestrator.CancelStateMachine(brainId)

-- Create a new brain that reuses the same body
local newBrain = Orchestrator.CreateStateMachine({
    StateMachineClass = shared.StateMachine.JetAutopilot,
    StateMachineId = brainId,
    Context = { Entity = entity },
})

newBrain:Start({ State = "Idle" })
```

#### 3. The "Warm Restart" (Recovery) Pattern

When a complex logic sequence fails or gets stuck, developers often have to kill the whole object. The RetryStateMachine pattern allows you to reboot the logic while preserving the current data.

Pattern: Logic Resilience.

Use Case: An AI Jet gets stuck in a navigation loop.

Developer Action: Call `Orchestrator.RetryStateMachine("Jet_01_Brain")`.

Outcome: The FSM is destroyed and recreated, but its Context (TargetPlayer, Fuel, Ammo) is passed back in, allowing the Jet to resume without "respawning" the physical model.

Example (kick a stuck brain):

```lua
-- Restart a stuck StateMachine without respawning the physical model.
Orchestrator.RetryStateMachine("Jet_01_Brain")
```

#### 4. The "God-View" Telemetry Pattern

The Orchestrator exposes a sanitized synchronization API. This allows developers to build external "Admin Tools" or "Command Centers" that see exactly what every entity is doing in real-time.

Pattern: Remote Observability.

Use Case: Creating a "Commander Mode" map.

Implementation: Use `ServiceManagerRemote:InvokeServer("GetSyncData")` to get a snapshot of active StateMachines/Entities plus Scheduler telemetry (if `shared.FSM.Scheduler` is set).

Note: the snapshot is sanitized (functions replaced, deep tables truncated) so it can be sent over remotes safely.

Security note: Orchestrator's ServiceManager remote API does not enforce an admin check by default. If you expose this in a live game, add your own authorization gate.

Example (single snapshot pull):

```lua
-- Client (admin-only): get snapshot on demand
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServiceManagerRemote = ReplicatedStorage:WaitForChild("ServiceManagerRemote")

local sync = ServiceManagerRemote:InvokeServer("GetSyncData")
print(sync and sync.FSM and sync.FSM.History)
```

#### 5. The Automatic Cleanup Pattern

One of the biggest causes of lag in Roblox is "zombie" threads—code that keeps running after the object is gone. The Orchestrator automates this via signals.

Pattern: Lifecycle Automation.

Developer Action: Simply call `Finish()`, `Fail()`, or `Cancel()` inside your StateMachine.

Outcome: The Orchestrator detects the signal, records the result in the History, removes the ID from the registry, and calls `Destroy()` to prune all managed connections and tasks.

Example (FSM ends itself; Orchestrator cleans it up):

```lua
-- Pattern: a state calls Finish(); Orchestrator detects completion and auto-cleans.
self:AddState("DoWork", {
    OnEnter = function(state, fsm)
        local conn = workspace.ChildAdded:Connect(function() end)
        fsm:Manage(conn)

        -- Do work, then finish
        fsm:Finish()
    end,
})
```

#### 6. The "Batch Operation" Pattern

During world transitions (like a round ending or a map change), you need to clear the board. The Orchestrator provides "Nuke" options to safely wind down the game.

Pattern: Mass Teardown.

Developer Action: `Orchestrator.CancelAll()` and `Orchestrator.DeleteAllEntities()`.

Why: Instead of manually tracking every spawned jet, bullet, and NPC, the Orchestrator iterates through its internal registry and ensures every single one triggers its `:OnCleanup()` and `:OnLeave()` logic for a clean exit.

Example (end-of-round teardown):

```lua
-- End-of-round cleanup: stop all StateMachines, then destroy all tracked Entities.
Orchestrator.CancelAll()
Orchestrator.DeleteAllEntities()
```

Summary of Orchestrator Patterns:

| Pattern | Developer Benefit | Example Scenario |
| :--- | :--- | :--- |
| Singletons | Prevents logic duplication | Global TimeOfDay management. |
| Brain-Body | Modular code | Swapping a Pilot for an AI Autopilot mid-flight. |
| Warm Restart | Bug recovery | Resetting a "stuck" boss without healing it. |
| Telemetry | Easier debugging | Inspecting Server performance from a Client UI. |
| Auto-Cleanup | Memory safety | Ensuring a missile's logic stops after it explodes. |
| Mass Teardown | Clean transitions | Clearing the map for the next round. |

---

## Tests

The project includes a lightweight in-game unit test harness under `tests/`.

### Test layout (Roblox Explorer)

`TestRunner` expects a specific folder structure:

- `ReplicatedStorage/FiniteStateMachineTests` (Folder)
    - `TestRunner` (ModuleScript)
    - `TestBase` (ModuleScript)
    - `Tests` (Folder)
        - `Test_BaseStateMachine` (ModuleScript)
        - `Test_BaseEntity` (ModuleScript)
        - `Test_Scheduler` (ModuleScript)
        - `Test_Logger` (ModuleScript)
        - `Test_Orchestrator` (ModuleScript)
        - `Test_BehaviorTree` (ModuleScript)

Note: In this repo, the test modules are currently located directly under `tests/`. If you want to run them in-game with `TestRunner`, place them under a `Tests` folder in `ReplicatedStorage/FiniteStateMachineTests`.

Notes:

- Each `Test_*` module must return a table with a `Run()` function.
- `TestRunner` clones `TestBase` into each test module before requiring it (so tests can do `script:FindFirstChild("TestBase")`).
- The test suites currently require framework modules from `ReplicatedStorage/SharedModules`.
    - If you follow this README’s recommended layout (`ReplicatedStorage/Modules`), either add a compatibility `SharedModules` folder, or update the first few lines of each `Test_*` module to point to `Modules` instead.

### Running all tests

Run from the Command Bar (server context) or a one-off Script:

```lua
-- Run the full test suite (server context).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local testRoot = ReplicatedStorage:WaitForChild("FiniteStateMachineTests")
require(testRoot:WaitForChild("TestRunner")).RunAll()
```

### What’s covered

- `Test_BaseStateMachine`:
    - State lifecycle: basic transitions, invalid transitions, transition interruption, transition counts
    - Timing: `WaitSpan` delay, delayed transition invalidation, wait cancellation on `Destroy()`
    - Terminal behavior: explicit terminal states and implicit `Failed`/`Cancelled`/custom completion names
    - Events: `Completed`, `Failed`, `Cancelled` fire as expected
    - Subclassing: `.Extend(...)`, `RegisterStates()`, and `tostring()` identity
    - HFSM: `AddSubMachine`, parent transitions on child completion, cancellation propagation + cancellation mapping
    - Cleanup: legacy cleanup return functions, `Manage()` cleanup for functions/tables, RBX connections, and Instances
    - Priority: time-slicing sanity check (high priority runs more often than low)
- `Test_BaseEntity`:
    - Schema: `DefineSchema` and type enforcement (including `Instance` class checks like `Part`)
    - Transaction model: pending vs committed values, and `UpdateEntity()` applying changes
    - Safety: immutability by default (fails if `ApplyChanges` not overridden), error handling when `ApplyChanges` throws
    - Lifecycle: destroyed entities stop exposing data; auto-destruction when the backing `Instance` is destroyed
    - Subclassing: `.Extend(...)`, `ApplyChanges` overrides, `tostring()`
    - Locking: `AcquireLock` / `ReleaseLock` ownership enforcement in `UpdateEntity`
    - Context/management: context injection via `__call`, `SetContext`, and `Manage()` cleanup
- `Test_Scheduler`:
    - Scheduling: delayed tasks, immediate/negative-delay tasks, ordering by execution time
    - Cancellation: `Deschedule`, rescheduling behavior, and task lookup
    - Stress: large burst scheduling (10k tasks)
    - Recurrence: recurring task runs and self-deschedules
    - Input validation: invalid settings return `nil` and do not create tasks
    - Execution controls: `ExecuteTask` by name or task object, `ResetTask`
    - Budgeting: frame-budget deferral behavior
    - Observability: `History` records failures; `GetSyncData()` includes settings/tasks
- `Test_Logger`:
    - Basic initialization, history recording, and log fields (e.g. `OperationId`)
- `Test_Orchestrator`:
    - Entity factory: create/get/idempotent create/delete
    - StateMachine factory: create/get/idempotent create/cancel registry cleanup
    - Retry: `RetryStateMachine` context preservation (requires class registered in `shared.StateMachine`)
    - Mass operations: `DeleteAllEntities()` and `CancelAll()`
    - ServiceManager API: remote creation check (skips if not in a server context)
- `Test_BehaviorTree`:
    - Core nodes: `Condition`, `Selector`, `Sequence`, `Inverter`, `Succeeder`
    - Actions: `SetState`
    - Composition: nested tree evaluation correctness

### What’s not covered (yet)

- Orchestrator discovery scanning (folder traversal + auto-registration)
- Full client/server replication pipeline (Entity update remotes, command remotes) and security gates
- Persistence integration (`EntityPersistence` / DataStores) and failure modes
- End-to-end gameplay integration tests (Entities + FSM + Scheduler working together in a running place)

---

## Framework Core

The framework core is the **4 Pillars** model described in [Architecture: The 4 Pillars](#architecture-the-4-pillars). That section defines the roles (Orchestrator, BaseStateMachine, BaseEntity, Scheduler) and the end-to-end lifecycle. Use it as the canonical reference for how the system boots, spawns, runs, and cleans up.

If you need implementation examples, see the earlier sections on **Quick Start**, **BaseStateMachine**, **BaseEntity**, and **Scheduler** for concrete patterns.
