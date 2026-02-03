# Welcome to RBXStateMachine

**RBXStateMachine** is not just an FSM library; it is a full-stack architectural framework for Roblox. It is designed to solve the complexity of large-scale gameplay logic by enforcing a strict separation between **Decision Making** (The Brain), **Data Representation** (The Body), and **Execution Timing** (The Pulse).

---

## 🏛️ The Philosophy of Separation

Most Roblox projects suffer from "Mega-Scripts" where input, logic, visuals, and networking are all entangled. RBXStateMachine solves this through three core paradigms:

### 1. The Brain (BaseStateMachine)
The Brain handles **decisions**. It doesn't care how a door moves; it only care *that* it is opening. It transitions through states like `Idle`, `Opening`, `Open`, and `Closing`.
*   [Learn more about StateMachines →](API-BaseStateMachine)

### 2. The Body (BaseEntity)
The Body handles **mechanics**. It wraps a physical Roblox `Instance`. When the Brain says "Open", the Body executes the tween, plays the sound, and updates the schema.
*   [Learn more about Entities →](API-BaseEntity)

### 3. The Pulse (Scheduler)
The Pulse handles **performance**. In a game with 500 NPCs, running logic for every NPC every frame will cause lag. The Scheduler "slices" time, ensuring that only a small portion of logic runs per frame, keeping your FPS stable.
*   [Learn more about the Scheduler →](API-Scheduler)

---

## 🌟 Key Features

*   **⚡ Frame-Budgeted Execution**: Never drop a frame again. The Scheduler ensures your logic stays within a millisecond budget.
*   **🔗 Hierarchical FSM (HFSM)**: Nest complex states within states (e.g., a `Combat` state that contains `Melee` and `Ranged` sub-states).
*   **📡 Built-in Replication**: Mark a schema field as `Replicate = true`, and the framework handles the networking for you.
*   **💾 Infinite Persistence**: Save entity states to DataStores with one line of configuration.
*   **🌳 Functional Behavior Trees**: A lightweight, composable alternative for complex AI decision nodes.

---

## 🚦 How to Navigate the Docs

If you are new here, follow this path:

1.  **[Installation Guide](Getting-Started)**: Set up the folder structure.
2.  **[5-Minute Quick Start](Quick-Start)**: Build your first "Spinning Part" agent.
3.  **[System Architecture](Architecture)**: Understand the "4 Pillars" and how they talk to each other.
4.  **[API Reference](API-Reference)**: Use this as your daily cheatsheet once you're comfortable.

> [!TIP]
> This framework is "Opinionated". It assumes you want a professional, server-authoritative structure. If you are building a simple hobby project, some of these concepts may feel like "over-engineering"—but for production-ready games, they are your best friend.

---

## 🤝 Community & Support

RBXStateMachine is built for developers who care about **maintainability** and **performance**. If you find a bug or have a suggestion, please check the [Testing](Tests) page to see how we validate our code.
