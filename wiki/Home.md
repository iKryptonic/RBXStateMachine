# FiniteStateMachine

**FiniteStateMachine** is a modular, object-oriented framework for building and orchestrating gameplay logic in Roblox.

`BaseStateMachine` is one component of this project (the FSM/HFSM engine). The repo also includes `BaseEntity` (schema + replication-friendly entity pattern), `Scheduler` (frame-budgeted task dispatch), `Logger`, and `Orchestrator` (registry/factory + replication + service remotes).

## Quick links

- [Getting Started](Getting-Started.md)
- [Registration Guide (Entities & StateMachines)](Registration-Guide.md)
- [Quick Start](Quick-Start.md)
- [Architecture](Architecture.md)
- [API Reference (Cheatsheet)](API-Reference.md)
- [Tests](Tests.md)

## Core Features

- **Centralized Loop**: Efficiently manages multiple FSMs using a single `Heartbeat` connection with customizable priority levels (Time-Slicing).
- **Hierarchical FSM (HFSM)**: Natively supports nesting FSMs within states to handle complex logic layers.
- **Resource Tracking**: Automatic cleanup of Instances, Connections, and functions via the `Manage` method.
- **Flexible States**: Supports both simple function-based states (closures) and complex object-oriented states.
- **Context Sharing**: Seamlessly share data between states and sub-machines via a unified `Context` table.

## Architecture: The 4 Pillars

| Component | Layer | Role | Analog |
| :--- | :--- | :--- | :--- |
| **Orchestrator** | Service | Global Registry & Lifecycle Manager | The Nervous System |
| **BaseStateMachine** | Logic | Behavioral flow and decision making | The Brain |
| **BaseEntity** | Data | State authority and Instance proxy | The Body |
| **Scheduler** | Timing | Async execution and frame budgeting | The Pulse |

## Typical startup (server)

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Orchestrator = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("Orchestrator"))

-- Compiles registries into shared.Entity.* and shared.StateMachine.*
Orchestrator:RegisterComponents()

-- Attach behavior modules (optional, but recommended)
require(ReplicatedStorage:WaitForChild("Entity"):WaitForChild("DoorEntity"))
require(ReplicatedStorage:WaitForChild("StateMachine"):WaitForChild("DoorJob"))

-- Starts the global frame-budgeted task scheduler
shared.FSM.Scheduler:Start()
```
