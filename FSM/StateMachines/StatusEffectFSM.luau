--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StatusEffectFSM = {
    Name = "StatusEffectFSM",
    className = "StatusEffectFSM",
    validStates = { "Active", "Expired", "Failed" },
    terminalStates = { "Expired", "Failed" },
    initialState = "Active",
}

local function getOrchestrator()
    local lower = (shared :: any).fsm
    if lower ~= nil then
        return lower.Orchestrator or lower
    end
    local upper = (shared :: any).FSM
    if upper ~= nil and upper.Orchestrator then
        return upper.Orchestrator
    end

    local orchestratorModule = ReplicatedStorage:FindFirstChild("Orchestrator")
    if orchestratorModule and orchestratorModule:IsA("ModuleScript") then
        local ok, result = pcall(require, orchestratorModule)
        if ok then
            return result
        end
    end

    error("Orchestrator is not registered")
end

local function getStatusEffectDefs()
    return require(ReplicatedStorage:WaitForChild("shared"):WaitForChild("StatusEffectDefs"))
end

local function cloneActiveEffects(charEntity: any): { any }
    local current = charEntity and charEntity.ActiveStatusEffects
    if typeof(current) ~= "table" then
        return {}
    end

    local clone = table.clone(current)
    for index, value in ipairs(clone) do
        if typeof(value) == "table" then
            clone[index] = table.clone(value)
        end
    end
    return clone
end

local function findEffectEntryIndex(activeEffects: { any }, instanceId: string): number?
    for index, entry in ipairs(activeEffects) do
        if typeof(entry) == "table" and entry.InstanceId == instanceId then
            return index
        end
    end
    return nil
end

local function getHumanoid(charEntity: any): Humanoid?
    local character = charEntity and charEntity.Instance
    if character and character:IsA("Model") then
        return character:FindFirstChildOfClass("Humanoid")
    end
    return nil
end

local function syncHumanoid(charEntity: any)
    local humanoid = getHumanoid(charEntity)
    if not humanoid then
        return
    end

    local maxHealth = tonumber(charEntity.MaxHealth)
    if maxHealth and maxHealth > 0 then
        humanoid.MaxHealth = maxHealth
    end
    local currentHealth = tonumber(charEntity.Health)
    if currentHealth then
        charEntity.Health = math.clamp(currentHealth, 0, humanoid.MaxHealth)
        humanoid.Health = charEntity.Health
    end
end

local function hasOtherFlagProvider(charEntity: any, instanceId: string, flagName: string): boolean
    local defs = getStatusEffectDefs()
    local activeEffects = charEntity and charEntity.ActiveStatusEffects
    if typeof(activeEffects) ~= "table" then
        return false
    end

    for _, entry in ipairs(activeEffects) do
        if typeof(entry) ~= "table" or entry.InstanceId == instanceId then
            continue
        end
        local def = defs.Get(entry.EffectId)
        local flags = def and def.ApplyFlags
        if typeof(flags) == "table" and flags[flagName] ~= nil then
            return true
        end
    end
    return false
end

local function hasOtherStun(charEntity: any, instanceId: string): boolean
    local activeEffects = charEntity and charEntity.ActiveStatusEffects
    if typeof(activeEffects) ~= "table" then
        return false
    end

    for _, entry in ipairs(activeEffects) do
        if typeof(entry) == "table" and entry.InstanceId ~= instanceId and entry.EffectId == "Stun" then
            return true
        end
    end
    return false
end

local function removeEffectEntry(charEntity: any, instanceId: string)
    local activeEffects = cloneActiveEffects(charEntity)
    local index = findEffectEntryIndex(activeEffects, instanceId)
    if index then
        table.remove(activeEffects, index)
    end
    charEntity.ActiveStatusEffects = activeEffects
end

local function reverseEffect(fsm: any)
    if not fsm._effectApplied then
        return
    end

    local charEntity = fsm.CharacterEntity
    local def = fsm.Definition
    if not charEntity or not def then
        fsm._effectApplied = false
        return
    end

    removeEffectEntry(charEntity, fsm.Id)

    if typeof(def.StatModifiers) == "table" then
        for stat, modifier in pairs(def.StatModifiers) do
            if typeof(modifier) == "number" and typeof(charEntity[stat]) == "number" then
                charEntity[stat] = (tonumber(charEntity[stat]) or 0) - modifier
            end
        end
    end

    if typeof(def.ApplyFlags) == "table" then
        for flagName, flagValue in pairs(def.ApplyFlags) do
            if flagValue ~= nil and not hasOtherFlagProvider(charEntity, fsm.Id, flagName) then
                if typeof(flagValue) == "boolean" and typeof(charEntity[flagName]) == "boolean" then
                    charEntity[flagName] = false
                else
                    charEntity[flagName] = nil
                end
            end
        end
    end

    if def.Id == "Stun" and not hasOtherStun(charEntity, fsm.Id) and fsm._stunSnapshot then
        if typeof(charEntity.CanMove) == "boolean" then
            charEntity.CanMove = fsm._stunSnapshot.CanMove
        end
        if typeof(charEntity.MoveSpeedCap) == "number" then
            charEntity.MoveSpeedCap = fsm._stunSnapshot.MoveSpeedCap
        end
    end

    if typeof(charEntity.Health) == "number" and typeof(charEntity.MaxHealth) == "number" then
        charEntity.Health = math.clamp(charEntity.Health, 0, charEntity.MaxHealth)
    end
    if typeof(charEntity.Stamina) == "number" and typeof(charEntity.MaxStamina) == "number" then
        charEntity.Stamina = math.clamp(charEntity.Stamina, 0, charEntity.MaxStamina)
    end
    if typeof(charEntity.Mana) == "number" and typeof(charEntity.MaxMana) == "number" then
        charEntity.Mana = math.clamp(charEntity.Mana, 0, charEntity.MaxMana)
    end

    syncHumanoid(charEntity)
    charEntity:UpdateEntity()
    fsm._effectApplied = false
end

local function applyTick(fsm: any)
    local charEntity = fsm.CharacterEntity
    local def = fsm.Definition
    if not charEntity or not def then
        return
    end

    local humanoid = getHumanoid(charEntity)
    local changed = false
    local tickDamage = tonumber(def.TickDamage) or 0
    local tickHeal = tonumber(def.TickHeal) or 0

    if tickDamage > 0 then
        if humanoid then
            humanoid:TakeDamage(tickDamage)
            charEntity.Health = humanoid.Health
        elseif typeof(charEntity.Health) == "number" then
            charEntity.Health = math.max(0, charEntity.Health - tickDamage)
        end
        changed = true
    end

    if tickHeal > 0 and typeof(charEntity.Health) == "number" then
        local maxHealth = tonumber(charEntity.MaxHealth) or charEntity.Health
        charEntity.Health = math.clamp(charEntity.Health + tickHeal, 0, maxHealth)
        if humanoid then
            syncHumanoid(charEntity)
        end
        changed = true
    end

    if changed then
        charEntity:UpdateEntity()
    end
end

function StatusEffectFSM:RegisterStates()
    self:AddState("Active", {
        OnEnter = function(_, fsm)
            if typeof(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
                fsm:Fail("Missing CharacterEntityId")
                return
            end
            if typeof(fsm.EffectId) ~= "string" or fsm.EffectId == "" then
                fsm:Fail("Missing EffectId")
                return
            end

            local orchestrator = getOrchestrator()
            local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
            local def = getStatusEffectDefs().Get(fsm.EffectId)
            if not charEntity then
                fsm:Fail("CharacterEntity not found")
                return
            end
            if not def then
                fsm:Fail("Status effect not found")
                return
            end

            fsm.CharacterEntity = charEntity
            fsm.Definition = def
            fsm._tickAccumulator = 0
            fsm._effectApplied = true

            local activeEffects = cloneActiveEffects(charEntity)
            local index = findEffectEntryIndex(activeEffects, fsm.Id)
            local entry = {
                InstanceId = fsm.Id,
                EffectId = def.Id,
                StartedAt = os.clock(),
                Duration = tonumber(def.Duration) or 0,
                Stacks = 1,
            }
            if index then
                activeEffects[index] = entry
            else
                table.insert(activeEffects, entry)
            end
            charEntity.ActiveStatusEffects = activeEffects

            if typeof(def.StatModifiers) == "table" then
                for stat, modifier in pairs(def.StatModifiers) do
                    if typeof(modifier) == "number" and typeof(charEntity[stat]) == "number" then
                        charEntity[stat] = (tonumber(charEntity[stat]) or 0) + modifier
                    end
                end
            end

            if typeof(def.ApplyFlags) == "table" then
                for flagName, flagValue in pairs(def.ApplyFlags) do
                    if flagValue ~= nil then
                        charEntity[flagName] = flagValue
                    end
                end
            end

            if def.Id == "Stun" then
                fsm._stunSnapshot = {
                    CanMove = charEntity.CanMove,
                    MoveSpeedCap = charEntity.MoveSpeedCap,
                }
                if typeof(charEntity.CanMove) == "boolean" then
                    charEntity.CanMove = false
                end
                if typeof(charEntity.MoveSpeedCap) == "number" then
                    charEntity.MoveSpeedCap = 0
                end
            end

            if typeof(charEntity.Health) == "number" and typeof(charEntity.MaxHealth) == "number" then
                charEntity.Health = math.clamp(charEntity.Health, 0, charEntity.MaxHealth)
            end
            if typeof(charEntity.Stamina) == "number" and typeof(charEntity.MaxStamina) == "number" then
                charEntity.Stamina = math.clamp(charEntity.Stamina, 0, charEntity.MaxStamina)
            end
            if typeof(charEntity.Mana) == "number" and typeof(charEntity.MaxMana) == "number" then
                charEntity.Mana = math.clamp(charEntity.Mana, 0, charEntity.MaxMana)
            end

            syncHumanoid(charEntity)
            charEntity:UpdateEntity()
            fsm:ScheduleTransition(math.max(tonumber(def.Duration) or 0, 0), "Expired")
        end,
        OnHeartbeat = function(_, fsm, dt)
            local def = fsm.Definition
            if not def then
                return
            end

            local interval = tonumber(def.TickInterval) or 0
            if interval <= 0 then
                return
            end

            fsm._tickAccumulator = (tonumber(fsm._tickAccumulator) or 0) + dt
            while fsm._tickAccumulator >= interval do
                fsm._tickAccumulator -= interval
                applyTick(fsm)
            end
        end,
    }, { "Expired", "Failed" })

    self:AddState("Expired", {
        OnEnter = function(_, fsm)
            reverseEffect(fsm)
        end,
    }, {})

    self:AddState("Failed", function() end, {})
end

function StatusEffectFSM:OnCleanup()
    reverseEffect(self)
end

return StatusEffectFSM
