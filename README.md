# RBXStateMachine

**RBXStateMachine** is a high-performance, full-stack architectural framework for Roblox designed to manage complex gameplay logic, state replication, and performance budgeting.

---

## 🏛️ The "4 Pillars" Architecture

This framework enforces a clean separation of concerns through four core components:

1.  **🧠 The Brain (BaseStateMachine)**: Handles logic, AI decision-making, and state transitions.
2.  **🛡️ The Body (BaseEntity)**: A schema-validated data wrapper for physical Roblox Instances with built-in replication and persistence.
3.  **⚡ The Pulse (Scheduler)**: A frame-budgeted task runner that ensures stable server performance even with thousands of active agents.
4.  **🕸️ The Nervous System (Orchestrator)**: The microkernel that manages registration, discovery, and networking.

---

## 🌟 Key Features

*   **🔒 Transactional Data**: Entities use a "Stage-Commit" flow via `UpdateEntity()` to ensure data integrity.
*   **📡 Automatic Replication**: Mark schema fields for replication, and the framework handles the remotes for you.
*   **⚖️ Priority Aging**: The Scheduler prevents high-priority tasks from starving background tasks.
*   **💾 Integrated Persistence**: One-line configuration for saving entity state to DataStores.
*   **🌳 Functional AI**: Includes a lightweight Behavioral Tree implementation.

---

## 📂 Project Structure

*   **/FSM**: The core engine. Contains the implementation of the 4 Pillars and auxiliary systems.
    *   *See [FSM/README.md](FSM/README.md) for deep technical implementation details.*
*   **/wiki**: Comprehensive guides, tutorials, and API references.
    *   *See the [Wiki Home](wiki/Home.md) for the full documentation suite.*
*   **/tests**: A robust suite of Spec-style unit and integration tests.

---

## 🚀 Quick Installation

1.  Sync this repository into your project using **Rojo**.
2.  Standard Roblox hierarchy for components (required by Factory):
    ```text
    ReplicatedStorage
    ├── Entity/
    └── StateMachine/
    ```
3.  Initialize on both Server and Client:
    ```lua
    local FSM = require(ReplicatedStorage.RBXStateMachine)
    FSM.Orchestrator:RegisterComponents()
    ```

---

## 📖 Learn More

For full documentation, tutorials, and advanced patterns, visit the **[Project Wiki](wiki/Home.md)**.
