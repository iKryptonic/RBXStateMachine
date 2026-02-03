# Architecture

This framework integrates the Brain, Body, Pulse, and Nervous System of your project into a single, high-performance lifecycle.

## The 4 Pillars

| Component | Layer | Role | Analog |
| :--- | :--- | :--- | :--- |
| **Orchestrator** | Service | Global Registry & Lifecycle Manager | The Nervous System |
| **BaseStateMachine** | Logic | Behavioral flow and decision making | The Brain |
| **BaseEntity** | Data | State authority and Instance proxy | The Body |
| **Scheduler** | Timing | Async execution and frame budgeting | The Pulse |

## System Bootstrapping (Initialization)

Everything begins with the **Orchestrator**. Upon game start, the Orchestrator performs a “Discovery” phase:

1. It scans your folders for Entity and StateMachine modules.
2. It injects the Scheduler, Logger, and Signal into the shared global space.
3. It creates a network bridge (RemoteFunctions) so that the Server can talk to a debug console on the Client.

## The Spawning Flow (Creation)

When spawning objects, the systems work in a “Body-First, Brain-Second” sequence:

1. **Entity Creation**: `Orchestrator.CreateEntity` creates a proxy for the physical model. It enforces a strict Schema.
2. **Brain Creation**: `Orchestrator.CreateStateMachine` is created to control that entity.
3. **The Link**: The Orchestrator passes the Entity into the Brain's Context. The Brain now has a Body to control.

## The Runtime Loop (Execution)

1. **Decision (Brain)**: The FSM or BT decides on an action.
2. **Instruction (Brain -> Body)**: The FSM sets schema fields on the Entity.
3. **Validation (Body)**: The Entity checks the Schema and stages the value.
4. **Transaction (Commit)**: The FSM calls `Entity:UpdateEntity()`.
5. **Execution (Pulse)**: The Scheduler enforces a frame budget to avoid spikes.

## Architecture Concepts

1. **StateMachine**: The controller that manages the current state, transitions, and lifecycle.
2. **Context**: A shared table (`fsm.Context`) used to store data accessible by all states.
3. **Entity Pattern**: The FSM should handle logic (decisions), while an external Entity class handles mechanisms (visuals, physics, tweens).
4. **Sub-Machine**: A child FSM running inside a state of a parent FSM.

## Best Practices

1. Use `fsm.Context` instead of globals.
2. Use priorities: UI FSMs at `Render`, background AI at `Low`.
3. Always use `self:Manage(...)` for cleanup.
4. Avoid recursive self-transitions inside `OnEnter` without a delay/condition.
5. Keep `ApplyChanges` context-safe: it may run on server (commit) and on client (replication).

Client-only visuals in `ApplyChanges` should be guarded:

```lua
local RunService = game:GetService("RunService")

function MyEntity:ApplyChanges(changes)
    if not RunService:IsClient() then
        return
    end
    -- visual-only application here
end
```
