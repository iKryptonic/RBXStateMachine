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
	@module AbilityComboFSM
	@description Validates a combo ability, spends mana, plays each combo step, processes per-step events, records cooldowns, and finishes after the last step.
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
	@description Returns the ability combos defs for this FSM, or `nil` when it cannot be found.
	@param orchestrator any  -- Orchestrator used to resolve entities, modules, or child jobs.
	@return any -- Resolved ability combos defs, or `nil` when unavailable.
]=]

local function getAbilityCombosDefs(orchestrator: any)
	return ModuleLoader.requireSharedModule(orchestrator,"AbilityCombosDefs")
end

--[=[
	@description Resolves the character and player entities referenced by this combo request.
	@param fsm any  -- AbilityComboFSM instance carrying the combo request and cached step data.
	@return any -- Character entity followed by player entity, or `nil, nil` when the orchestrator is unavailable.
]=]

local function getEntities(fsm: any): (any?, any?)
	local orchestrator = fsm:GetOrchestrator()
	if not orchestrator then
		return nil, nil
	end
	return orchestrator.GetEntity(fsm.CharacterEntityId), orchestrator.GetEntity(fsm.PlayerEntityId)
end

--[=[
	@description Performs the `tableContainsAbility` helper work.
	@param container any  -- Container table to inspect or mutate.
	@param abilityId any  -- Ability identifier to resolve.
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
	@description Resolves an item's `WeaponType` from replicated assets so ability combos can verify the equipped weapon requirement.
	@param itemId any  -- Item identifier for the request.
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
	@description Chooses the entity that currently owns mana, preferring the player entity and falling back to the character entity.
	@param playerEntity any  -- Player entity being read from or written to.
	@param charEntity any  -- Character entity being read from or written to.
	@return any -- Resolved mana entity, or `nil` when unavailable.
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
	@description Returns the ability def for this FSM, or `nil` when it cannot be found.
	@param fsm any  -- AbilityComboFSM instance carrying the combo request and cached step data.
	@return any -- Resolved ability def, or `nil` when unavailable.
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
	@description Resolves the current combo step from `_comboStepIndex`, clamping the index to at least `1`.
	@param fsm any  -- AbilityComboFSM instance carrying the combo request and cached step data.
	@return any -- Combo step table followed by the resolved 1-based step index, or `nil, 0` when the combo sequence is missing.
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
	@description Entry placeholder that waits for callers to start the combo flow at `ValidateAbility`.
	Transitions:
	Writes: none.

]=]

	self:AddState("Idle", function() end, {"ValidateAbility" })

	--[=[
	@state ValidateAbility
	@description Resolves ability, character, and player data, then checks combo sequence, weapon type, unlock state, and cooldown before mana spend.
	Transitions:
	- `CheckMana` when OnEnter finishes or falls through its guard checks.
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
	@description Resolves the active mana owner and ensures it can pay the combo's mana cost before spending.
	Transitions:
	- `DeductMana` when OnEnter finishes or falls through its guard checks.
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
	@description Deducts mana from the chosen mana entity, replicates that spend with the FSM lock id, and fails immediately when the cost cannot be paid.
	Transitions:
	- `PlayComboStep` when OnEnter finishes or falls through its guard checks.
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
	@description Loads the current combo step, caches step data and index, emits the step animation intent, and stages the step duration in `WaitSpan`.
	Transitions:
	- `ProcessComboEvents` when OnEnter finishes or falls through its guard checks.
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
	@description Logs any configured damage or effect events for the current combo step before advancing the combo pointer.
	Transitions:
	- `AdvanceStep` when OnEnter finishes or falls through its guard checks.
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
	@description Advances `_comboStepIndex` and either loops to the next combo step or enters cooldown once the sequence is exhausted.
	Transitions:
	- `PlayComboStep` when OnEnter finishes or falls through its guard checks.
	- `Cooldown` when OnEnter finishes or falls through its guard checks.
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
	- `Completed` when OnEnter finishes or falls through its guard checks.
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
