--!strict


local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local Shared = ReplicatedStorage:WaitForChild("shared")
local EquipHelpers = require(Shared:WaitForChild("EquipHelpers"))
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))
local ResourceHelpers = require(Helpers:WaitForChild("ResourceHelpers"))

--[=[
	@Name AbilityComboFSM
	@Author iKrypto
	@Description Server-authoritative ability combo execution FSM. Drives a multi-step
	combo sequence for an equipped ability: validates the ability is unlocked and off
	cooldown, checks and deducts mana, plays each combo step's animation in sequence
	(with DamageEvent/Effect processing per step), then enters a cooldown period before
	completing.

	State flow:
	ValidateAbility → CheckMana → DeductMana → PlayComboStep → ProcessComboEvents
	→ AdvanceStep → (loop to PlayComboStep if more steps) → Cooldown → Completed
	Any state may → Failed on validation/resource errors.

	Context fields:
	- _abilityDef: table — cached ability definition from AbilityCombosDefs
	- _comboStepIndex: number — current 1-based index into ComboSequence
	- _currentStep: table — the active combo step being processed
	- _currentStepIndex: number — snapshot of _comboStepIndex at PlayComboStep entry
	- _onAnimate: function? — optional client-side animation callback

	Required params:
	- AbilityId: string — ID matching a key in AbilityCombosDefs.Abilities
	- CharacterEntityId: string — registry ID for the CharacterEntity
	- PlayerEntityId: string — registry ID for the PlayerEntity
]=]

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
	terminalStates = {"Completed","Failed" },
	initialState = "ValidateAbility",
}

--[=[
	@description Returns the ability combos defs used by this state machine when it can be resolved.
	@param orchestrator any -- Input consumed by `getAbilityCombosDefs`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getAbilityCombosDefs(orchestrator: any)
	return ModuleLoader.requireSharedModule(orchestrator,"AbilityCombosDefs")
end

--[=[
	@description Returns the entities used by this state machine when it can be resolved.
	@param fsm any -- Input consumed by `getEntities`.
	@param any? any -- Input consumed by `getEntities`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getEntities(fsm: any): (any?, any?)
	local orchestrator = fsm:GetOrchestrator()
	if not orchestrator then
		return nil, nil
	end
	return orchestrator.GetEntity(fsm.CharacterEntityId), orchestrator.GetEntity(fsm.PlayerEntityId)
end

--[=[
	@description Helper for the table contains ability step used by this state machine.
	@param container any -- Input consumed by `tableContainsAbility`.
	@param abilityId any -- Input consumed by `tableContainsAbility`.
	@return boolean -- Whether the helper completed successfully.
]=]

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

--[=[
	@description Resolves weapon type from the current FSM context and available runtime data.
	@param itemId any -- Input consumed by `resolveWeaponType`.
	@return string -- Resolved string value used by the FSM.
]=]

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

--[=[
	@description Resolves mana entity from the current FSM context and available runtime data.
	@param playerEntity any -- Input consumed by `resolveManaEntity`.
	@param charEntity any -- Input consumed by `resolveManaEntity`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function resolveManaEntity(playerEntity: any, charEntity: any): any?
	if playerEntity and tonumber(playerEntity.Mana) ~= nil then
		return playerEntity
	end
	if charEntity and tonumber(charEntity.Mana) ~= nil then
		return charEntity
	end
	return charEntity or playerEntity
end

--[=[
	@description Returns the ability def used by this state machine when it can be resolved.
	@param fsm any -- Input consumed by `getAbilityDef`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

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

--[=[
	@description Returns the combo step used by this state machine when it can be resolved.
	@param fsm any -- Input consumed by `getComboStep`.
	@param number any -- Input consumed by `getComboStep`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

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
	@description Registers the runtime states, transitions, and terminal behavior for `AbilityComboFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function AbilityComboFSM:RegisterStates()


	--[=[
		@state Idle
		@description Runs the `idle` stage of `AbilityComboFSM`.
			Transitions:
			Writes: none.
	]=]

	self:AddState("Idle", function() end, {"ValidateAbility" })


	--[=[
		@state ValidateAbility
		@description Validates the required runtime context and prerequisites.
			Transitions:
			- `CheckMana` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context._abilityDef`, stores `Context._comboStepIndex`, sets `ComboSequence`, sets `_abilityDef`, sets `_comboStepIndex`.
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
	}, {"CheckMana","Failed" })


	--[=[
		@state CheckMana
		@description Runs the `check mana` stage of `AbilityComboFSM`.
			Transitions:
			- `DeductMana` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
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
	}, {"DeductMana","Failed" })


	--[=[
		@state DeductMana
		@description On enter, replicates entity changes.
			Transitions:
			- `PlayComboStep` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: replicates entity changes.
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
	}, {"PlayComboStep","Failed" })


	--[=[
		@state PlayComboStep
		@description On enter, stores `Context._currentStep`, stores `Context._currentStepIndex`, sets `_currentStep`.
			Transitions:
			- `ProcessComboEvents` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context._currentStep`, stores `Context._currentStepIndex`, sets `_currentStep`, sets `_currentStepIndex`, emits an intent.
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

			local animationName = if typeof(step.Animation) == "string" then step.Animation else""
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
	}, {"ProcessComboEvents","Failed" })


	--[=[
		@state ProcessComboEvents
		@description On enter, writes to the log.
			Transitions:
			- `AdvanceStep` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: writes to the log.
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
	}, {"AdvanceStep","Failed" })


	--[=[
		@state AdvanceStep
		@description On enter, stores `Context._comboStepIndex`, sets `_comboStepIndex`.
			Transitions:
			- `PlayComboStep` when this stage finishes its immediate work or falls through its guard checks.
			- `Cooldown` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context._comboStepIndex`, sets `_comboStepIndex`.
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
	}, {"PlayComboStep","Cooldown","Failed" })


	--[=[
		@state Cooldown
		@description Arms the cooldown window before returning control.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
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
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success sink reached after `Cooldown` records the new cooldown timestamp on the character and player entities. `OnEnter` is a no-op because all cooldown writes already happened.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink for ability validation, mana spending, combo-step resolution, or cooldown-context errors. `OnEnter` is a no-op because failure bookkeeping happens before entry.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Failed", function() end, {})
end

return AbilityComboFSM
