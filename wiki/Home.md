# Welcome to RBXStateMachine

**RBXStateMachine** is a modular, high-performance, object-oriented framework designed for building complex gameplay systems in Roblox. It integrates state management, entity orchestration, and frame-budgeted execution into a cohesive lifecycle.

---

## 🚀 Quick Links

| [Getting Started](Getting-Started) | [Quick Start](Quick-Start) | [Registration Guide](Registration-Guide) |
| :--- | :--- | :--- |
| Core concepts & installation | Your first entity & FSM in 5 mins | How to define your logic |

| [Architecture](Architecture) | [API Reference](API-Reference) | [Tests](Tests) |
| :--- | :--- | :--- |
| The "4 Pillars" design | Deep dive into every method | Validation & quality assurance |

---

## 🧠 Why RBXStateMachine?

*   **Brain vs. Body separation**: Logic (FSM) is decoupled from physical mechanics (Entity).
*   **Frame Budgeting**: The built-in Scheduler prevents CPU spikes, ensuring smooth gameplay even with hundreds of active agents.
*   **Scalable**: Built for professional workflows involving Factory patterns and data-driven registries.
*   **Server-Authoritative**: Includes first-class support for replication, persistence, and client-to-server command buses.

> [!TIP]
> Use the sidebar on the right (or bottom on mobile) to navigate deep into the technical specifications.

---

## 🛠️ The Core Loop

1.  **Decision**: A StateMachine decides an action must happen.
2.  **State Update**: The StateMachine updates properties on its controlled Entity.
3.  **Commit**: The changes are committed via `UpdateEntity()`.
4.  **Pulse**: The Scheduler executes the update logic within the next available frame budget.
