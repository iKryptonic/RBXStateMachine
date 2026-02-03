# Quick Start

This quick start uses the **Factory + Registry + Implementation module** workflow.

## 0) Roblox hierarchy

Create this structure in `ReplicatedStorage`:

*   `SharedModules/Orchestrator`
*   `Entity/EntityRegistry`
*   `Entity/SpinningPartEntity`
*   `StateMachine/StateMachineRegistry`
*   `StateMachine/SpinJob`

> [!NOTE]
> Also create a Part in `Workspace` named **SpinPart** for this demo.

## 1) EntityRegistry

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

## 2) Entity implementation

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

## 3) StateMachineRegistry

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

## 4) StateMachine implementation

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

## 5) Server bootstrap

`ServerScriptService/Bootstrap.server.lua`:

```lua
-- Quick Start (server) bootstrap example:
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

## 6) Client bootstrap

`StarterPlayerScripts/Bootstrap.client.lua`:

```lua
-- Quick Start (client) bootstrap example:
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")

local Orchestrator = require(SharedModules:WaitForChild("Orchestrator"))
Orchestrator:RegisterComponents()

-- Attach client visual behavior
require(ReplicatedStorage:WaitForChild("Entity"):WaitForChild("SpinningPartEntity"))
```
