# 5-Minute Quick Start: The Spinning Part

### 🏗️ Step 1: Entity Registry
```lua
return {
    SpinPart = {
        Name = "SpinPart",
        Schema = { IsSpinning = { Type = "boolean", Replicate = true } }
    }
}
```

### 🧠 Step 2: AI Implementation
```lua
function SpinAI:RegisterStates()
    self:AddState("Idle", function(fsm)
        fsm.Entity.IsSpinning = true
        fsm.WaitSpan = 1
        fsm.State = "Spinning"
    end)
end
```

### 🚀 Step 3: Spawn
```lua
local part = Instance.new("Part", workspace)
local e = Orchestrator.CreateEntity({ EntityClass = "SpinPart", Context = { Instance = part } })
local ai = Orchestrator.CreateStateMachine({ StateMachineClass = "SpinAI", Context = { Entity = e } })
ai:Start({ State = "Idle" })
```
