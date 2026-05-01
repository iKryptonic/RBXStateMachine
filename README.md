# RBXStateMachine

**RBXStateMachine** is a high-performance, full-stack architectural framework for Roblox. It is designed to manage complex gameplay logic, server-authoritative state replication, and CPU budgeting for games that need to scale from a handful of agents to thousands.

It is not just a finite-state-machine library. It is a complete runtime — registry, scheduler, networking, persistence, dev console, and AI primitives — built around four cooperating components: **Brain**, **Body**, **Pulse**, and **Nervous System**.

> 📖 **Full documentation lives in the [Project Wiki](https://github.com/iKryptonic/RBXStateMachine/wiki)** (36 pages, ~500 KB).
> Start with the **[5-Minute Quick Start](https://github.com/iKryptonic/RBXStateMachine/wiki/Quick-Start)** or the **[System Architecture](https://github.com/iKryptonic/RBXStateMachine/wiki/Architecture)** deep dive.

---

## 🏛️ The "4 Pillars" Architecture

The framework enforces a strict separation of concerns through four cooperating components:

| Pillar | Component | Responsibility | Analog |
| :--- | :--- | :--- | :--- |
| 🧠 **Brain** | [`BaseStateMachine`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-BaseStateMachine) | Decision making, transitions, AI logic | The thinker |
| 🛡️ **Body** | [`BaseEntity`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-BaseEntity) | Schema-validated data + Instance proxy | The actor |
| ⚡ **Pulse** | [`Scheduler`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-Scheduler) | Frame-budgeted time-slicing | The heartbeat |
| 🕸️ **Nervous System** | [`Orchestrator`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-Orchestrator) | Registry, factory, replication, lifecycle | The microkernel |

This separation is what lets you put 500+ NPCs on a server without dropping frames, replicate state to clients without writing a single `RemoteEvent`, and refactor the AI for one entity without touching the visuals for another.

📐 See **[System Architecture](https://github.com/iKryptonic/RBXStateMachine/wiki/Architecture)** for the runtime diagram and bootstrap order.

---

## 🌟 Key Features

### Core Runtime
* **⚡ Frame-Budgeted Execution** — The [Scheduler](https://github.com/iKryptonic/RBXStateMachine/wiki/API-Scheduler) caps work per frame at a configurable budget (default 5–15 ms) with **priority aging** so background jobs never starve.
* **🧬 Hierarchical FSMs (HFSM)** — Nest sub-machines inside states (e.g. a `Combat` state containing `Melee` / `Ranged`). See **[Hierarchical FSM](https://github.com/iKryptonic/RBXStateMachine/wiki/Hierarchical-FSM)**.
* **🌳 Functional Behavior Trees** — Composable `Sequence`, `Selector`, `Parallel`, `Decorator`, `Action`, `Condition` nodes via [`BehaviorTree`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-BehaviorTree).
* **♻️ Resource Tracking** — Every FSM/Entity has a `Manage()` method that auto-disconnects connections, destroys instances, and runs cleanup callbacks on `Stop()`.

### Data & Replication
* **🔒 Transactional Schema** — Entities use a stage-and-commit flow (`SetField` → `UpdateEntity()`); validation fails atomically with no partial writes. See **[Replication Pipeline](https://github.com/iKryptonic/RBXStateMachine/wiki/Replication-Pipeline)**.
* **📡 Automatic Replication** — Mark a schema field with `Replicate = true` and the framework wires the `RemoteEvent`, batches deltas, applies rate limits, and sanitizes inbound writes.
* **💾 Integrated Persistence** — One-line opt-in via [`EntityPersistence`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-EntityPersistence) saves entity state to DataStores. Includes versioning + migrations ([Versioning](https://github.com/iKryptonic/RBXStateMachine/wiki/Versioning)) and a 7-second write throttle out of the box.
* **🛡️ Server Authority** — Inbound `RemoteEvent` payloads are sanitized to a configurable depth (default 8) and rate-limited per player.

### Performance & Scaling
* **🧵 Parallel Workers** — [`ActorPool`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-ActorPool) dispatches CPU-heavy jobs to Roblox `Actor` instances for true parallel execution.
* **♻️ Entity Pooling** — Recycle entities across spawns to avoid GC pressure in high-frequency systems (projectiles, particles). See **[Pooling Strategy](https://github.com/iKryptonic/RBXStateMachine/wiki/Pooling-Strategy)**.
* **📊 Performance Tuning** — Capacity planning, profiling, and budget math: **[Performance Tuning](https://github.com/iKryptonic/RBXStateMachine/wiki/Performance-Tuning)**.

### Operations & Debugging
* **🖥️ Built-in Dev Console** — [`ServiceManager`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-ServiceManager) ships a 9-page in-game UI: logs, entities, FSMs, performance, history, terminal, settings, etc.
* **📝 Structured Logger** — [`Logger`](https://github.com/iKryptonic/RBXStateMachine/wiki/API-Logger) with a 500-entry circular buffer, log levels, and console streaming.
* **🧪 Spec-style Tests** — Full unit + integration suite under `FSM/Tests/` (Replication, Pooling, Discovery, Scheduler, Logger, Mocking, etc.). See **[Testing & Validation](https://github.com/iKryptonic/RBXStateMachine/wiki/Tests)**.

---

## 📂 Project Structure

```
RBXStateMachine/
├── FSM/                          ← The core engine (4 Pillars + auxiliary systems)
│   ├── Orchestrator/             ← Registry, Factory, ActorPool, ServiceManager, NetworkManager
│   ├── Factory/                  ← BaseEntity, BaseStateMachine, PersistenceManager, Registry
│   ├── EntityRegistry.luau       ← Runtime entity registry
│   ├── StateMachineRegistry.luau ← Runtime state-machine registry
│   ├── Client.client.luau        ← Client bootstrap script
│   ├── Tests/                    ← Spec-style unit & integration tests
│   └── README.md                 ← Deep technical implementation reference
│
├── example/                      ← Working reference implementations
│   ├── DoorEntityExample.luau    ← Schema, replication, instance proxying
│   ├── DoorStateMachineExample.luau ← Multi-state FSM with validation & failure paths
│   └── GameControllerExample.luau   ← Bootstrap + entity/FSM creation flow
│
└── RBXStateMachine.wiki/         ← Wiki source (36 pages, comprehensive guide)
```

The **wiki is a separate git repository** mounted as a nested directory; it is published at <https://github.com/iKryptonic/RBXStateMachine/wiki>.

---

## 🚀 Quick Installation

### 1. Sync into your project

Use **[Rojo](https://rojo.space/)** (or your tool of choice) to sync the `FSM/` directory into `ReplicatedStorage` as `RBXStateMachine`. Place your custom Entity and StateMachine modules as **direct children of `ReplicatedStorage`** — the Orchestrator's `Factory` discovers these folders by name:

```text
ReplicatedStorage/
├── RBXStateMachine/    ← The framework (this repo's FSM/ folder)
├── Entity/             ← Your *Entity.luau modules go here
└── StateMachine/       ← Your *StateMachine.luau modules go here
```

📚 Folder layout details: **[Registration Guide](https://github.com/iKryptonic/RBXStateMachine/wiki/Registration-Guide)**.

### 2. Bootstrap (Server)

```lua
-- ServerScriptService/Bootstrap.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FSM = require(ReplicatedStorage:WaitForChild("RBXStateMachine"))

-- Discover Entity/StateMachine modules and wire up remotes, scheduler, logger.
FSM.Orchestrator:RegisterComponents()
```

### 3. Bootstrap (Client)

```lua
-- StarterPlayerScripts/Bootstrap.client.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
ReplicatedStorage:WaitForChild("Entity")
ReplicatedStorage:WaitForChild("StateMachine")

local FSM = require(ReplicatedStorage:WaitForChild("RBXStateMachine"))
FSM.Orchestrator:RegisterComponents()
```

`FSM/Client.client.luau` ships as a ready-to-use client bootstrap if you'd rather sync that directly under `StarterPlayerScripts`.

📚 Full walkthrough with error handling and verification: **[Installation Guide](https://github.com/iKryptonic/RBXStateMachine/wiki/Getting-Started)**.

---

## ⚡ Hello, World — A Spinning Part

```lua
-- ServerScriptService/Bootstrap.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FSM = require(ReplicatedStorage:WaitForChild("RBXStateMachine"))
FSM.Orchestrator:RegisterComponents()

local part = workspace.SpinningPart -- any Part in workspace

-- 1. Wrap the Instance in a schema-validated Entity.
local entity = FSM.Orchestrator.CreateEntity({
    EntityClass = "SpinnerEntity",
    EntityId    = "Spinner1",
    Context     = { Instance = part },
})

-- 2. Attach a brain that drives it.
local fsm = FSM.Orchestrator.CreateStateMachine({
    StateMachineClass = "SpinnerStateMachine",
    StateMachineId    = "Spinner1_FSM",
    Context           = { SpinnerEntity = entity },
})

fsm:Start({ State = "Spinning" })
```

The `SpinnerEntity` and `SpinnerStateMachine` modules live under `ReplicatedStorage/Entity/` and `ReplicatedStorage/StateMachine/` respectively. See `example/DoorEntityExample.luau` for a complete reference implementation, or the **[Quick Start](https://github.com/iKryptonic/RBXStateMachine/wiki/Quick-Start)** for a full walkthrough.

---

## 📖 Documentation Map

The wiki is structured by audience:

| You want to… | Go to |
| :--- | :--- |
| Build your first agent in 5 minutes | **[Quick Start](https://github.com/iKryptonic/RBXStateMachine/wiki/Quick-Start)** |
| Understand the runtime end-to-end | **[Architecture](https://github.com/iKryptonic/RBXStateMachine/wiki/Architecture)** |
| Look up a method signature | **[API Reference](https://github.com/iKryptonic/RBXStateMachine/wiki/API-Reference)** |
| Learn how state replicates to clients | **[Replication Pipeline](https://github.com/iKryptonic/RBXStateMachine/wiki/Replication-Pipeline)** |
| Build nested AI states | **[Hierarchical FSM](https://github.com/iKryptonic/RBXStateMachine/wiki/Hierarchical-FSM)** |
| Persist player/entity data | **[EntityPersistence](https://github.com/iKryptonic/RBXStateMachine/wiki/API-EntityPersistence)** + **[Versioning](https://github.com/iKryptonic/RBXStateMachine/wiki/Versioning)** |
| Hit 60 FPS with 500+ NPCs | **[Performance Tuning](https://github.com/iKryptonic/RBXStateMachine/wiki/Performance-Tuning)** + **[Pooling Strategy](https://github.com/iKryptonic/RBXStateMachine/wiki/Pooling-Strategy)** |
| Write production-grade code | **[Best Practices](https://github.com/iKryptonic/RBXStateMachine/wiki/Best-Practices)** + **[Production Readiness](https://github.com/iKryptonic/RBXStateMachine/wiki/Production-Readiness)** |
| Diagnose a bug | **[Debugging](https://github.com/iKryptonic/RBXStateMachine/wiki/Debugging)** + **[FAQ](https://github.com/iKryptonic/RBXStateMachine/wiki/FAQ)** |
| Migrate from another FSM library | **[Migration Guide](https://github.com/iKryptonic/RBXStateMachine/wiki/Migration-Guide)** |
| Look up unfamiliar terms | **[Glossary](https://github.com/iKryptonic/RBXStateMachine/wiki/Glossary)** |

> 💡 The **[Wiki Home](https://github.com/iKryptonic/RBXStateMachine/wiki)** has full Beginner / Intermediate / Expert learning paths.

---

## 🎯 Should I Use This Framework?

**✅ Use RBXStateMachine if you are…**
- Building a multiplayer game with server authority
- Managing 50+ NPCs / agents / entities concurrently
- Need persistent player or world data
- Working in a team where consistent patterns matter
- Building anything where dropped frames are unacceptable

**❌ Consider alternatives if you are…**
- Prototyping a 3-day game jam entry
- Building a single-player showcase with simple if/else logic
- Working solo on a small project where the architectural overhead outweighs the benefits

---

## 🧪 Testing

The framework ships with a comprehensive Spec-style test suite under `FSM/Tests/`:

- **Unit tests**: Logger, Mocking, Orchestrator, Discovery, Scheduler, Replication Security, Registry, Pool Reuse, Fail-with-nil-history, …
- **Integration tests**: DataStoreEntity, EntityPooling, Factory, ServiceManager, Replication, Iteration Safety, …

Run them via your Roblox test runner of choice. See **[Testing & Validation](https://github.com/iKryptonic/RBXStateMachine/wiki/Tests)** for setup and authoring conventions.

---

## 📚 Learn More

- 🏠 **[Wiki Home](https://github.com/iKryptonic/RBXStateMachine/wiki)** — Full table of contents and learning paths
- 📐 **[FSM/README.md](FSM/README.md)** — Deep technical reference for framework internals
- 💬 **[FAQ & Troubleshooting](https://github.com/iKryptonic/RBXStateMachine/wiki/FAQ)** — Common questions answered
- 🐛 **[Issues](https://github.com/iKryptonic/RBXStateMachine/issues)** — Bug reports and feature requests welcome
