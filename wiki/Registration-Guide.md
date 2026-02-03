# Registration Guide (Entities & StateMachines)

This section is the canonical guide for registering and implementing Entities and StateMachines in this project.

## Supported registration modes

You can use any of these (they can be mixed):

1. **Factory + Registries (recommended)**: put definitions in `EntityRegistry` / `StateMachineRegistry`, call `Orchestrator:RegisterComponents()`, and use `shared.Entity.*` / `shared.StateMachine.*`.
2. **String-based lookup**: pass a string name to `Orchestrator.CreateEntity({ EntityClass = "DoorEntity", ... })` or `Orchestrator.CreateStateMachine({ StateMachineClass = "DoorJob", ... })` after registration.
3. **Manual classes**: create classes via `BaseEntity.Extend` / `BaseStateMachine.Extend` and pass the class table directly to `CreateEntity` / `CreateStateMachine` (no registry needed).

## 1) Register an Entity (Factory + Registry)

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

## 2) Implement an Entity properly (Attach methods)

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

## 3) Register a StateMachine (Factory + Registry)

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

## 4) Implement a StateMachine properly (Attach RegisterStates)

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

## 5) Create instances (class table vs string)

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

## 6) Manual (no-registry) registration

If you don’t want registries, you can build classes directly and pass them to Orchestrator.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")

local Orchestrator = require(SharedModules:WaitForChild("Orchestrator"))

local BaseEntity = require(SharedModules.Orchestrator:WaitForChild("Factory"):WaitForChild("BaseEntity"))
local BaseStateMachine = require(SharedModules.Orchestrator:WaitForChild("Factory"):WaitForChild("BaseStateMachine"))

local MyEntity = BaseEntity.Extend({
    Name = "MyEntity",
    Schema = { Value = { Type = "number", Replicate = true } },
})

function MyEntity:ApplyChanges(_) end

local MyFSM = BaseStateMachine.Extend({
    className = "MyFSM",
    validStates = { "Start", "Done" },
    terminalStates = { "Done" },
    Priority = BaseStateMachine.Priorities.Render,
})

function MyFSM:RegisterStates()
    self:AddState("Start", function(fsm)
        fsm.Entity.Value = 123
        fsm.Entity:UpdateEntity()
        fsm.State = "Done"
    end, { "Done" })
end

Orchestrator:RegisterComponents()

local e = Orchestrator.CreateEntity({ EntityClass = MyEntity, EntityId = "E1", Context = { Instance = workspace.Part } })
local m = Orchestrator.CreateStateMachine({ StateMachineClass = MyFSM, StateMachineId = "M1", Context = { Entity = e } })

m:Start({ State = "Start" })
```
