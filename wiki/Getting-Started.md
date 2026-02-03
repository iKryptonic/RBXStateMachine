# Getting Started

Setup the directory structure for your project.

---

## 📂 1. Structure
```text
ReplicatedStorage
├── Entity/
│   ├── EntityRegistry.luau
│   └── MyEntity.luau
└── StateMachine/
    ├── StateMachineRegistry.luau
    └── MyAI.luau
```

## 🚀 2. Bootstrapping

### Server
```lua
local FSM = require(ReplicatedStorage.RBXStateMachine)
FSM.Orchestrator:RegisterComponents()
FSM.Orchestrator.StartServiceManagerAPI()
```

### Client
```lua
local FSM = require(ReplicatedStorage.RBXStateMachine)
FSM.Orchestrator:RegisterComponents()
-- Note: InitClientListeners is handled within RegisterComponents' internal call stack
```

---

## 🏗️ 3. Workflow
1.  Define the **Registry** (Data Interface).
2.  Write the **Implementation** (Methods/Logic).
3.  The **Orchestrator** compiles them at runtime.
