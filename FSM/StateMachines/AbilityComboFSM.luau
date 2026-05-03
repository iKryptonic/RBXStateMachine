--!strict
--[=[
	@module AbilityComboFSM
	@description Defines the `AbilityComboFSM` state machine module and its exported API.
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local Shared = ReplicatedStorage:WaitForChild("shared")
local EquipHelpers = require(Shared:WaitForChild("EquipHelpers"))
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))
local ResourceHelpers = require(Helpers:WaitForChild("ResourceHelpers"))

local AbilityComboFSM = {
	Name = "AbilityComboFSM",
	className = "AbilityComboFSM",
	validStates = {
		"Idle",
		"ValidateAbility",
		"CheckMana",
		"DeductMana",
		"PlayComboStep",
		"ProcessComboEvents",
		"AdvanceStep",
		"Cooldown",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "ValidateAbility",
}

local function getAbilityCombosDefs(orchestrator: any)
	return ModuleLoader.requireSharedModule(orchestrator, "AbilityCombosDefs")
end

local function getEntities(fsm: any): (any?, any?)
	local orchestrator = fsm:GetOrchestrator()
	if not orchestrator then
		return nil, nil
	end
	return orchestrator.GetEntity(fsm.CharacterEntityId), orchestrator.GetEntity(fsm.PlayerEntityId)
end

local function tableContainsAbility(container: any, abilityId: string): boolean
	if typeof(container) ~= "table" then
		return false
	end
	if container[abilityId] == true or container[abilityId] == abilityId then
		return true
	end
	for key, value in pairs(container) do
		if key == abilityId or value == abilityId then
			return true
		end
	end
	return false
end

local function resolveWeaponType(itemId: string?): string?
	if typeof(itemId) ~= "string" or itemId == "" then
		return nil
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end

	local item = assets:FindFirstChild(itemId, true)
	if not item then
		return nil
	end

	local itemData = EquipHelpers.GetItemData(item)
	if itemData and typeof(itemData.WeaponType) == "string" then
		return itemData.WeaponType
	end

	return nil
end

local function resolveManaEntity(playerEntity: any, charEntity: any): any?
	if playerEntity and tonumber(playerEntity.Mana) ~= nil then
		return playerEntity
	end
	if charEntity and tonumber(charEntity.Mana) ~= nil then
		return charEntity
	end
	return charEntity or playerEntity
end

local function getAbilityDef(fsm: any): any?
	local cached = fsm.Context._abilityDef
	if cached then
		return cached
	end
	local orchestrator = fsm:GetOrchestrator()
	if not orchestrator then
		return nil
	end
	local defs = getAbilityCombosDefs(orchestrator)
	local abilityId = tostring(fsm.AbilityId or "")
	local abilityDef = defs.GetAbility(abilityId)
	if abilityDef then
		fsm.Context._abilityDef = abilityDef
	end
	return abilityDef
end

local function getComboStep(fsm: any): (any?, number)
	local abilityDef = getAbilityDef(fsm)
	if not abilityDef or typeof(abilityDef.ComboSequence) ~= "table" then
		return nil, 0
	end
	local stepIndex = math.max(1, tonumber(fsm.Context._comboStepIndex) or 1)
	return abilityDef.ComboSequence[stepIndex], stepIndex
end

--[=[
	@description Records a cooldown expiration timestamp for an ability on the given entity.
	Clones AbilityCooldowns to avoid shared-reference mutation, writes the new
	timestamp, and calls UpdateEntity to replicate.
	@param entity any — The entity to write cooldown to
	@param abilityId string — The ability ID to put on cooldown
	@param cooldownEnd number — os.clock() timestamp when cooldown expires
	@param lockId string — FSM ID used as lock token for UpdateEntity
	@writes entity.AbilityCooldowns[abilityId]
]=]
local function recordCooldown(entity: any, abilityId: string, cooldownEnd: number, lockId: string)
	if not entity then
		return
	end
	local cooldowns = if typeof(entity.AbilityCooldowns) == "table" then table.clone(entity.AbilityCooldowns) else {}
	cooldowns[abilityId] = cooldownEnd
	entity.AbilityCooldowns = cooldowns
	if type(entity.SetContext) == "function" then
		entity:SetContext("_abilityCooldowns", cooldowns)
	end
	if type(entity.UpdateEntity) == "function" then
		entity:UpdateEntity(lockId)
	end
end
--[=[
	@description Handles `RegisterStates` for `AbilityComboFSM`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function AbilityComboFSM:RegisterStates()
	--[=[
		@state Idle
		@description Handles the `Idle` state for `AbilityComboFSM`.
	]=]

	self:AddState("Idle", function() end, { "ValidateAbility" })
	--[=[
		@state ValidateAbility
		@description Handles the `ValidateAbility` state for `AbilityComboFSM`.
	]=]

	self:AddState("ValidateAbility", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity, playerEntity = getEntities(fsm)
			if not orchestrator then
				fsm:Fail("Orchestrator not found")
				return
			end
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end
			if not playerEntity then
				fsm:Fail("PlayerEntity not found")
				return
			end

			local abilityId = tostring(fsm.AbilityId or "")
			if abilityId == "" then
				fsm:Fail("AbilityId required")
				return
			end

			local abilityDef = getAbilityCombosDefs(orchestrator).GetAbility(abilityId)
			if not abilityDef then
				fsm:Fail("Ability definition not found")
				return
			end
			if typeof(abilityDef.ComboSequence) ~= "table" or #abilityDef.ComboSequence == 0 then
				fsm:Fail("Ability combo sequence missing")
				return
			end

			if typeof(abilityDef.WeaponType) == "string" and abilityDef.WeaponType ~= "" then
				local equippedWeaponType = resolveWeaponType(charEntity.EquippedRight)
				if equippedWeaponType ~= abilityDef.WeaponType then
					fsm:Fail("Incorrect weapon type")
					return
				end
			end

			local unlocked = tableContainsAbility(playerEntity.UnlockedAbilities, abilityId)
			local equipped = tableContainsAbility(playerEntity.EquippedAbilities, abilityId)
			if not unlocked and not equipped then
				fsm:Fail("Ability is not unlocked")
				return
			end

			local cooldowns = if typeof(charEntity.AbilityCooldowns) == "table"
				then charEntity.AbilityCooldowns
				elseif typeof(playerEntity.AbilityCooldowns) == "table"
				then playerEntity.AbilityCooldowns
				else {}
			if (tonumber(cooldowns[abilityId]) or 0) > os.clock() then
				fsm:Fail("Ability is on cooldown")
				return
			end

			fsm.Context._abilityDef = abilityDef
			fsm.Context._comboStepIndex = math.max(1, tonumber(fsm.Context._comboStepIndex) or 1)
			fsm.State = "CheckMana"
		end,
	}, { "CheckMana", "Failed" })
	--[=[
		@state CheckMana
		@description Handles the `CheckMana` state for `AbilityComboFSM`.
	]=]

	self:AddState("CheckMana", {
		OnEnter = function(_, fsm)
			local abilityDef = getAbilityDef(fsm)
			local charEntity, playerEntity = getEntities(fsm)
			if not abilityDef or not charEntity or not playerEntity then
				fsm:Fail("Ability mana context missing")
				return
			end
			local manaEntity = resolveManaEntity(playerEntity, charEntity)
			if not manaEntity then
				fsm:Fail("Mana entity not found")
				return
			end
			local manaCost = tonumber(abilityDef.ManaCost) or 0
			if (tonumber(manaEntity.Mana) or 0) < manaCost then
				fsm:Fail("Not enough mana")
				return
			end
			fsm.State = "DeductMana"
		end,
	}, { "DeductMana", "Failed" })
	--[=[
		@state DeductMana
		@description Handles the `DeductMana` state for `AbilityComboFSM`.
	]=]

	self:AddState("DeductMana", {
		OnEnter = function(_, fsm)
			local abilityDef = getAbilityDef(fsm)
			local charEntity, playerEntity = getEntities(fsm)
			if not abilityDef or not charEntity or not playerEntity then
				fsm:Fail("Ability mana context missing")
				return
			end
			local manaEntity = resolveManaEntity(playerEntity, charEntity)
			local manaCost = tonumber(abilityDef.ManaCost) or 0
			if not manaEntity or not ResourceHelpers.deductMana(manaEntity, manaCost) then
				fsm:Fail("Not enough mana")
				return
			end
			if type(manaEntity.UpdateEntity) == "function" then
				manaEntity:UpdateEntity(fsm.Id)
			end
			fsm.State = "PlayComboStep"
		end,
	}, { "PlayComboStep", "Failed" })
	--[=[
		@state PlayComboStep
		@description Handles the `PlayComboStep` state for `AbilityComboFSM`.
	]=]

	self:AddState("PlayComboStep", {
		OnEnter = function(_, fsm)
			local step, stepIndex = getComboStep(fsm)
			local charEntity = select(1, getEntities(fsm))
			if typeof(step) ~= "table" then
				fsm:Fail("Combo step not found")
				return
			end

			fsm.Context._currentStep = step
			fsm.Context._currentStepIndex = stepIndex

			local animationName = if typeof(step.Animation) == "string" then step.Animation else ""
			if animationName ~= "" then
				local onAnimate = fsm.Context._onAnimate
				if typeof(onAnimate) == "function" then
					pcall(onAnimate, animationName, step.Speed, 0.1)
				end
				if charEntity then
					IntentHelpers.appendIntent(
						fsm:GetOrchestrator(),
						charEntity,
						"Animation",
						{ Name = animationName, Speed = if typeof(step.Speed) == "number" then step.Speed else 1, FadeTime = 0.1 },
						fsm.CharacterEntityId,
						fsm.CharacterEntityId,
						fsm.Id
					)
				end
			end

			local duration = math.max(0, tonumber(step.Duration) or 0)
			if duration > 0 then
				fsm.WaitSpan = duration
			end
			fsm.State = "ProcessComboEvents"
		end,
	}, { "ProcessComboEvents", "Failed" })
	--[=[
		@state ProcessComboEvents
		@description Handles the `ProcessComboEvents` state for `AbilityComboFSM`.
	]=]

	self:AddState("ProcessComboEvents", {
		OnEnter = function(_, fsm)
			local step = fsm.Context._currentStep
			local stepIndex = tonumber(fsm.Context._currentStepIndex) or 1
			local abilityId = tostring(fsm.AbilityId or "")
			if typeof(step) ~= "table" then
				fsm:Fail("Current combo step missing")
				return
			end

			if typeof(step.DamageEvent) == "table" then
				fsm:Log({
					Level = "INFO",
					Message = string.format("[AbilityComboFSM] %s step %d damage event: %s", abilityId, stepIndex, HttpService:JSONEncode(step.DamageEvent)),
				})
			end
			if typeof(step.Effect) == "table" then
				fsm:Log({
					Level = "INFO",
					Message = string.format("[AbilityComboFSM] %s step %d effect event: %s", abilityId, stepIndex, HttpService:JSONEncode(step.Effect)),
				})
			end
			fsm.State = "AdvanceStep"
		end,
	}, { "AdvanceStep", "Failed" })
	--[=[
		@state AdvanceStep
		@description Handles the `AdvanceStep` state for `AbilityComboFSM`.
	]=]

	self:AddState("AdvanceStep", {
		OnEnter = function(_, fsm)
			local abilityDef = getAbilityDef(fsm)
			if not abilityDef or typeof(abilityDef.ComboSequence) ~= "table" then
				fsm:Fail("Ability combo context missing")
				return
			end
			local nextStepIndex = (tonumber(fsm.Context._comboStepIndex) or 1) + 1
			fsm.Context._comboStepIndex = nextStepIndex
			if nextStepIndex <= #abilityDef.ComboSequence then
				fsm.State = "PlayComboStep"
			else
				fsm.State = "Cooldown"
			end
		end,
	}, { "PlayComboStep", "Cooldown", "Failed" })
	--[=[
		@state Cooldown
		@description Handles the `Cooldown` state for `AbilityComboFSM`.
	]=]

	self:AddState("Cooldown", {
		OnEnter = function(_, fsm)
			local abilityDef = getAbilityDef(fsm)
			local charEntity, playerEntity = getEntities(fsm)
			local abilityId = tostring(fsm.AbilityId or "")
			if not abilityDef or abilityId == "" then
				fsm:Fail("Cooldown context missing")
				return
			end

			local cooldown = math.max(0, tonumber(abilityDef.Cooldown) or 0)
			local cooldownEnd = os.clock() + cooldown
			recordCooldown(charEntity, abilityId, cooldownEnd, fsm.Id)
			recordCooldown(playerEntity, abilityId, cooldownEnd, fsm.Id)
			if cooldown > 0 then
				fsm.WaitSpan = cooldown
			end
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })
	--[=[
		@state Completed
		@description Handles the `Completed` terminal state for `AbilityComboFSM`.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
		@state Failed
		@description Handles the `Failed` terminal state for `AbilityComboFSM`.
	]=]

	self:AddState("Failed", function() end, {})
end

return AbilityComboFSM
