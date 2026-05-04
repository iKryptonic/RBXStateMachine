--!strict


local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local Shared = ReplicatedStorage:WaitForChild("shared")
local EquipHelpers = require(Shared:WaitForChild("EquipHelpers"))
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local EntityHelpers = require(Helpers:WaitForChild("EntityHelpers"))
local CombatHelpers = require(Helpers:WaitForChild("CombatHelpers"))
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))
local ResourceHelpers = require(Helpers:WaitForChild("ResourceHelpers"))

--[=[
	@module CastFSM
	@description Runs the cast flow for abilities from validation and resource checks through cast timing, intent emission, and recovery.
]=]

local CastFSM = {
	Name = "CastFSM",
	className = "CastFSM",
	validStates = {
		"Idle",
		"ValidateAbility",
		"ValidateResources",
		"AcquireLock",
		"DeductResources",
		"EmitCastAnimation",
		"WaitCastDuration",
		"ValidateNotInterrupted",
		"Execute",
		"ExecuteMeleeSingle",
		"ExecuteMeleeAoE",
		"ExecuteProjectile",
		"ExecuteSelfHeal",
		"ExecuteInstantHeal",
		"ExecuteInstantStamina",
		"ExecuteInstantMana",
		"ExecuteDash",
		"ExecuteTargetedAoE",
		"EmitFinishAnimation",
		"SetCooldown",
		"ReleaseLock",
		"Completed",
		"Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Idle",
}

local DEFAULT_MELEE_RADIUS = 6
local DEFAULT_PROJECTILE_SPEED = 120
local DEFAULT_PROJECTILE_LIFETIME = 3
local DEFAULT_DASH_DURATION = 0.2

--[=[
	@description Returns the ability defs used by this state machine when it can be resolved.
	@param orchestrator any -- Input consumed by `getAbilityDefs`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getAbilityDefs(orchestrator: any)
	return ModuleLoader.requireSharedModule(orchestrator,"AbilityDefs")
end

--[=[
	@description Returns the talent tree defs used by this state machine when it can be resolved.
	@param orchestrator any -- Input consumed by `getTalentTreeDefs`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getTalentTreeDefs(orchestrator: any)
	return ModuleLoader.requireSharedModule(orchestrator,"TalentTreeDefs")
end

--[=[
	@description Returns the status effect defs used by this state machine when it can be resolved.
	@param orchestrator any -- Input consumed by `getStatusEffectDefs`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getStatusEffectDefs(orchestrator: any)
	return ModuleLoader.requireSharedModule(orchestrator,"StatusEffectDefs")
end

--[=[
	@description Returns the item data used by this state machine when it can be resolved.
	@param itemId any -- Input consumed by `getItemData`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getItemData(itemId: string?): any?
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

	local dataModule = EquipHelpers.ResolveDataModule(item)
	if not dataModule then
		return nil
	end

	local ok, data = pcall(require, dataModule)
	return if ok then data else nil
end

--[=[
	@description Resolves weapon type from the current FSM context and available runtime data.
	@param charEntity any -- Input consumed by `resolveWeaponType`.
	@return string -- Resolved string value used by the FSM.
]=]

local function resolveWeaponType(charEntity: any): string?
	local right = charEntity.EquippedRight
	if typeof(right) == "string" and right ~= "" then
		local data = getItemData(right)
		if data and typeof(data.WeaponType) == "string" then
			return data.WeaponType
		end
	end

	local left = charEntity.EquippedLeft
	if typeof(left) == "string" and left ~= "" then
		local data = getItemData(left)
		if data and typeof(data.WeaponType) == "string" then
			return data.WeaponType
		end
	end

	return nil
end

--[=[
	@description Helper for the is ability unlocked step used by this state machine.
	@param orchestrator any -- Input consumed by `isAbilityUnlocked`.
	@param playerEntity any -- Input consumed by `isAbilityUnlocked`.
	@param castDef any -- Input consumed by `isAbilityUnlocked`.
	@return boolean -- Whether the helper completed successfully.
]=]

local function isAbilityUnlocked(orchestrator: any, playerEntity: any, castDef: any): boolean
	if castDef.SourceType ~= "Ability" then
		return true
	end

	local learned = playerEntity and playerEntity.LearnedAbilities
	if typeof(learned) == "table" then
		if learned[castDef.Id] == true then
			return true
		end
		for key, value in pairs(learned) do
			if key == castDef.Id or value == castDef.Id then
				return true
			end
		end
	end

	local talentUnlocked = getTalentTreeDefs(orchestrator).IsAbilityUnlocked(castDef.Id, playerEntity)
	if talentUnlocked ~= nil then
		return talentUnlocked
	end

	local playerLevel = if playerEntity then tonumber(playerEntity.Level) or 1 else 1
	local unlockLevel = tonumber(castDef.UnlockLevel) or 1
	return playerLevel >= unlockLevel
end

--[=[
	@description Helper for the are abilities blocked step used by this state machine.
	@param orchestrator any -- Input consumed by `areAbilitiesBlocked`.
	@param charEntity any -- Input consumed by `areAbilitiesBlocked`.
	@param string? any -- Input consumed by `areAbilitiesBlocked`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function areAbilitiesBlocked(orchestrator: any, charEntity: any): (boolean, string?)
	local activeStatusEffects = charEntity and charEntity.ActiveStatusEffects
	if typeof(activeStatusEffects) ~= "table" then
		return false, nil
	end

	local defs = getStatusEffectDefs(orchestrator)
	for _, entry in ipairs(activeStatusEffects) do
		if typeof(entry) ~= "table" then
			continue
		end

		local def = defs.Get(entry.EffectId)
		if def then
			if def.BlockAbilities then
				return true, tostring(def.Name or entry.EffectId) .." prevents ability usage"
			end
			local flags = def.ApplyFlags
			if typeof(flags) == "table" and flags.IsStunned == true then
				return true, tostring(def.Name or entry.EffectId) .." prevents ability usage"
			end
		end
	end

	return false, nil
end

--[=[
	@description Resolves cast def from the current FSM context and available runtime data.
	@param fsm any -- Input consumed by `resolveCastDef`.
	@param orchestrator any -- Input consumed by `resolveCastDef`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function resolveCastDef(fsm: any, orchestrator: any): any?
	local cached = fsm.Context._castDef
	if cached then
		return cached
	end

	local abilityDefs = getAbilityDefs(orchestrator)
	local rawDef = fsm.Context._abilityDef
	local sourceType = if rawDef and typeof(rawDef.SourceType) == "string" then rawDef.SourceType else"Ability"
	if not rawDef and typeof(fsm.AbilityId) == "string" and fsm.AbilityId ~= "" then
		rawDef = abilityDefs.GetAbility(fsm.AbilityId)
	elseif not rawDef and typeof(fsm.ConsumableId) == "string" and fsm.ConsumableId ~= "" then
		rawDef = abilityDefs.GetConsumable(fsm.ConsumableId)
		sourceType = "Consumable"
	end

	if not rawDef then
		return nil
	end

	local castDef = table.clone(rawDef)
	castDef.SourceType = sourceType
	castDef.CastTime = tonumber(rawDef.CastTime or rawDef.UseTime or 0) or 0
	castDef.Cooldown = tonumber(rawDef.Cooldown or 0) or 0
	castDef.StaminaCost = tonumber(rawDef.StaminaCost or 0) or 0
	castDef.ManaCost = tonumber(rawDef.ManaCost or 0) or 0
	fsm.Context._castDef = castDef
	return castDef
end

--[=[
	@description Resolves target entity from the current FSM context and available runtime data.
	@param orchestrator any -- Input consumed by `resolveTargetEntity`.
	@param charEntity any -- Input consumed by `resolveTargetEntity`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function resolveTargetEntity(orchestrator: any, charEntity: any): any?
	local targetEntityId = charEntity.TargetEntityId
	if typeof(targetEntityId) ~= "string" or targetEntityId == "" then
		return nil
	end
	return orchestrator.GetEntity(targetEntityId)
end

--[=[
	@description Resolves target position from the current FSM context and available runtime data.
	@param orchestrator any -- Input consumed by `resolveTargetPosition`.
	@param charEntity any -- Input consumed by `resolveTargetPosition`.
	@param fallbackRoot any -- Input consumed by `resolveTargetPosition`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function resolveTargetPosition(orchestrator: any, charEntity: any, fallbackRoot: BasePart): Vector3
	local targetEntity = resolveTargetEntity(orchestrator, charEntity)
	if targetEntity and targetEntity.Instance and targetEntity.Instance:IsA("Model") then
		local _, targetRoot = EntityHelpers.getHumanoidAndRoot(targetEntity.Instance)
		if targetRoot then
			return targetRoot.Position
		end
	end
	return fallbackRoot.Position + fallbackRoot.CFrame.LookVector * 10
end

--[=[
	@description Helper for the clamp resource step used by this state machine.
	@param value any -- Input consumed by `clampResource`.
	@param maximum any -- Input consumed by `clampResource`.
	@return number -- Numeric value derived for downstream logic.
]=]

local function clampResource(value: number, maximum: number): number
	return math.clamp(value, 0, maximum)
end

--[=[
	@description Applies the health change work needed by the surrounding state flow.
	@param charEntity any -- Input consumed by `applyHealthChange`.
	@param humanoid any -- Input consumed by `applyHealthChange`.
	@param amount any -- Input consumed by `applyHealthChange`.
	@param lockId any -- Input consumed by `applyHealthChange`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function applyHealthChange(charEntity: any, humanoid: Humanoid, amount: number, lockId: string?)
	local maxHealth = tonumber(charEntity.MaxHealth) or humanoid.MaxHealth
	local nextHealth = ResourceHelpers.restoreResource(charEntity,"Health", amount,"MaxHealth")
	humanoid.Health = math.clamp(nextHealth, 0, humanoid.MaxHealth)
	charEntity:UpdateEntity(lockId)
end

--[=[
	@description Applies the resource restore work needed by the surrounding state flow.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function applyResourceRestore(
	charEntity: any,
	fieldName: string,
	maxFieldName: string,
	amount: number,
	lockId: string?
)
	local current = tonumber(charEntity[fieldName]) or 0
	local maximum = tonumber(charEntity[maxFieldName]) or current
	ResourceHelpers.restoreResource(charEntity, fieldName, amount, maxFieldName)
	charEntity:UpdateEntity(lockId)
end

--[=[
	@description Helper for the container has item step used by this state machine.
	@param container any -- Input consumed by `containerHasItem`.
	@param itemId any -- Input consumed by `containerHasItem`.
	@return boolean -- Whether the helper completed successfully.
]=]

local function containerHasItem(container: any, itemId: string): boolean
	if typeof(container) ~= "table" then
		return false
	end

	local arrayLength = #container
	for _, value in ipairs(container) do
		if value == itemId then
			return true
		end
		if typeof(value) == "table" and (value.Id == itemId or value.ItemId == itemId) then
			local count = tonumber(value.Count or value.Quantity or value.Amount or 1) or 1
			if count > 0 then
				return true
			end
		end
	end

	for key, value in pairs(container) do
		if typeof(key) == "number" and key >= 1 and key <= arrayLength and key % 1 == 0 then
			continue
		end
		if key == itemId then
			if typeof(value) == "number" then
				return value > 0
			end
			return value ~= nil
		end
		if value == itemId then
			return true
		end
		if typeof(value) == "table" and (value.Id == itemId or value.ItemId == itemId) then
			local count = tonumber(value.Count or value.Quantity or value.Amount or 1) or 1
			if count > 0 then
				return true
			end
		end
	end

	return false
end

--[=[
	@description Helper for the consume one in container step used by this state machine.
	@param container any -- Input consumed by `consumeOneInContainer`.
	@param itemId any -- Input consumed by `consumeOneInContainer`.
	@param any any -- Input consumed by `consumeOneInContainer`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function consumeOneInContainer(container: any, itemId: string): (boolean, any)
	if typeof(container) ~= "table" then
		return false, container
	end

	local clone = table.clone(container)
	for index, value in ipairs(clone) do
		if value == itemId then
			table.remove(clone, index)
			return true, clone
		end
		if typeof(value) == "table" and (value.Id == itemId or value.ItemId == itemId) then
			local itemClone = table.clone(value)
			local countField = if itemClone.Count ~= nil
				then"Count"
				elseif itemClone.Quantity ~= nil then"Quantity"
				elseif itemClone.Amount ~= nil then"Amount"
				else nil
			if countField then
				local nextCount = (tonumber(itemClone[countField]) or 1) - 1
				if nextCount > 0 then
					itemClone[countField] = nextCount
					clone[index] = itemClone
				else
					table.remove(clone, index)
				end
			else
				table.remove(clone, index)
			end
			return true, clone
		end
	end

	for key, value in pairs(clone) do
		if key == itemId then
			if typeof(value) == "number" then
				if value > 1 then
					clone[key] = value - 1
				else
					clone[key] = nil
				end
			else
				clone[key] = nil
			end
			return true, clone
		end
		if value == itemId then
			clone[key] = nil
			return true, clone
		end
		if typeof(value) == "table" and (value.Id == itemId or value.ItemId == itemId) then
			local itemClone = table.clone(value)
			local countField = if itemClone.Count ~= nil
				then"Count"
				elseif itemClone.Quantity ~= nil then"Quantity"
				elseif itemClone.Amount ~= nil then"Amount"
				else nil
			if countField then
				local nextCount = (tonumber(itemClone[countField]) or 1) - 1
				if nextCount > 0 then
					itemClone[countField] = nextCount
					clone[key] = itemClone
				else
					clone[key] = nil
				end
			else
				clone[key] = nil
			end
			return true, clone
		end
	end

	return false, container
end

--[=[
	@description Helper for the consume player item step used by this state machine.
	@param playerEntity any -- Input consumed by `consumePlayerItem`.
	@param itemId any -- Input consumed by `consumePlayerItem`.
	@param slotIndex any -- Input consumed by `consumePlayerItem`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function consumePlayerItem(playerEntity: any, itemId: string, slotIndex: number?)
	if not playerEntity then
		return false
	end

	local consumed = false
	local nextInventory = playerEntity.Inventory
	local nextBag = playerEntity.BagContents

	consumed, nextInventory = consumeOneInContainer(playerEntity.Inventory, itemId)
	if not consumed then
		consumed, nextBag = consumeOneInContainer(playerEntity.BagContents, itemId)
	end

	if not consumed then
		return false
	end

	playerEntity.Inventory = nextInventory
	playerEntity.BagContents = nextBag

	local hasRemaining = containerHasItem(nextInventory, itemId) or containerHasItem(nextBag, itemId)
	if not hasRemaining and typeof(playerEntity.QuickItemSlots) == "table" then
		local nextSlots = table.clone(playerEntity.QuickItemSlots)
		for index, value in pairs(nextSlots) do
			if value == itemId and (slotIndex == nil or index == slotIndex or value == itemId) then
				nextSlots[index] = ""
			end
		end
		playerEntity.QuickItemSlots = nextSlots
	end

	playerEntity:UpdateEntity()
	return true
end

--[=[
	@description Helper for the spawn projectile step used by this state machine.
	@param orchestrator any -- Input consumed by `spawnProjectile`.
	@param fsm any -- Input consumed by `spawnProjectile`.
	@param castDef any -- Input consumed by `spawnProjectile`.
	@param charEntity any -- Input consumed by `spawnProjectile`.
	@param rootPart any -- Input consumed by `spawnProjectile`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function spawnProjectile(orchestrator: any, fsm: any, castDef: any, charEntity: any, rootPart: BasePart)
	local targetPosition = resolveTargetPosition(orchestrator, charEntity, rootPart)
	local direction = targetPosition - rootPart.Position
	if direction.Magnitude <= 0.01 then
		direction = rootPart.CFrame.LookVector
	else
		direction = direction.Unit
	end

	local projectile = Instance.new("Part")
	projectile.Name = string.format("CastProjectile_%s_%s", castDef.Id, tostring(os.clock()))
	projectile.Shape = Enum.PartType.Ball
	projectile.Size = Vector3.new(1.2, 1.2, 1.2)
	projectile.Material = Enum.Material.Neon
	projectile.Color = if castDef.Id == "Fireball" then Color3.fromRGB(255, 120, 32) else Color3.fromRGB(120, 180, 255)
	projectile.CanCollide = false
	projectile.CanQuery = false
	projectile.CanTouch = true
	projectile.Anchored = false
	projectile.CFrame = rootPart.CFrame * CFrame.new(0, 0, -3)
	projectile.AssemblyLinearVelocity = direction * (tonumber(castDef.ProjectileSpeed) or DEFAULT_PROJECTILE_SPEED)
	projectile.Parent = workspace
	Debris:AddItem(projectile, DEFAULT_PROJECTILE_LIFETIME)

	local hitConnection: RBXScriptConnection?
	hitConnection = projectile.Touched:Connect(function(hit)
		local targetModel = hit and hit:FindFirstAncestorOfClass("Model")
		if not targetModel or targetModel == charEntity.Instance then
			return
		end

		local victimEntity = nil
		local entities = if typeof(orchestrator.GetEntities) == "function" then orchestrator.GetEntities() else {}
		for _, entity in pairs(entities) do
			if entity and entity.Instance == targetModel then
				victimEntity = entity
				break
			end
		end

		if victimEntity then
			CombatHelpers.createDamageJob(
				orchestrator,
				fsm.CharacterEntityId,
				victimEntity,
				castDef.Id,
				tonumber(castDef.Damage) or 0
			)
		end

		if hitConnection then
			hitConnection:Disconnect()
			hitConnection = nil
		end
		projectile:Destroy()
	end)
end

local EFFECT_STATE_BY_TYPE = {
	MeleeSingle = "ExecuteMeleeSingle",
	MeleeAoE = "ExecuteMeleeAoE",
	Projectile = "ExecuteProjectile",
	SelfHeal = "ExecuteSelfHeal",
	InstantHeal = "ExecuteInstantHeal",
	InstantStamina = "ExecuteInstantStamina",
	InstantMana = "ExecuteInstantMana",
	Dash = "ExecuteDash",
	TargetedAoE = "ExecuteTargetedAoE",
}

--[=[
	@description Returns the cast attack name used by this state machine when it can be resolved.
	@param castDef any -- Input consumed by `getCastAttackName`.
	@return string -- Resolved string value used by the FSM.
]=]

local function getCastAttackName(castDef: any): string
	return castDef.Id or castDef.Name or "Cast"
end

--[=[
	@description Resolves execute context from the current FSM context and available runtime data.
	@param fsm any -- Input consumed by `resolveExecuteContext`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function resolveExecuteContext(fsm: any)
	local orchestrator = fsm:GetOrchestrator()
	local castDef = fsm.Context._castDef
	local charEntity = fsm.Context._charEntity
	local playerEntity = fsm.Context._playerEntity
	local humanoid = fsm.Context._humanoid
	local rootPart = fsm.Context._rootPart
	if not orchestrator or not castDef or not charEntity or not humanoid or not rootPart then
		fsm.Context._releaseReason = "Execute context missing"
		fsm.State = "ReleaseLock"
		return nil
	end

	return {
		Orchestrator = orchestrator,
		CastDef = castDef,
		CharEntity = charEntity,
		PlayerEntity = playerEntity,
		Humanoid = humanoid,
		RootPart = rootPart,
		AttackName = getCastAttackName(castDef),
	}
end


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `CastFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function CastFSM:RegisterStates()


	--[=[
		@state Idle
		@description Runs the `idle` stage of `CastFSM`.
			Transitions:
			Writes: none.
	]=]

	self:AddState("Idle", function() end, {"ValidateAbility" })


	--[=[
		@state ValidateAbility
		@description Validates the required runtime context and prerequisites.
			Transitions:
			- `ValidateResources` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context._charEntity`, stores `Context._playerEntity`, stores `Context._character`, stores `Context._humanoid`, stores `Context._rootPart`.
	]=]

	self:AddState("ValidateAbility", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntityId = fsm.CharacterEntityId
			if typeof(charEntityId) ~= "string" or charEntityId == "" then
				fsm:Fail("CharacterEntityId is required")
				return
			end

			local charEntity = fsm:GetEntity(charEntityId)
			if not charEntity then
				fsm:Fail("Character entity not found")
				return
			end

			local playerEntity = nil
			if typeof(fsm.PlayerEntityId) == "string" and fsm.PlayerEntityId ~= "" then
				playerEntity = fsm:GetEntity(fsm.PlayerEntityId)
			elseif typeof(charEntity.PlayerEntityId) == "string" and charEntity.PlayerEntityId ~= "" then
				playerEntity = fsm:GetEntity(charEntity.PlayerEntityId)
			end

			local castDef = resolveCastDef(fsm, orchestrator)
			if not castDef then
				fsm:Fail("Cast definition not found")
				return
			end
			if not playerEntity then
				fsm:Fail("Player entity not found")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				fsm:Fail("Character model not found")
				return
			end

			local humanoid, rootPart = EntityHelpers.getHumanoidAndRoot(character)
			if not humanoid or humanoid.Health <= 0 or not rootPart then
				fsm:Fail("Character cannot cast")
				return
			end

			if charEntity.IsStunned == true or charEntity.IsKnocked == true then
				fsm:Fail("Character is crowd-controlled")
				return
			end

			if not isAbilityUnlocked(orchestrator, playerEntity, castDef) then
				fsm:Fail("Ability is not unlocked")
				return
			end

			local blocked, reason = areAbilitiesBlocked(orchestrator, charEntity)
			if blocked and castDef.SourceType ~= "Consumable" then
				fsm:Fail(reason or "Abilities are blocked")
				return
			end

			if
				castDef.SourceType == "Ability"
				and typeof(castDef.WeaponType) == "string"
				and castDef.WeaponType ~= ""
			then
				local equippedWeaponType = resolveWeaponType(charEntity)
				if equippedWeaponType ~= castDef.WeaponType then
					fsm:Fail("Incorrect weapon type")
					return
				end
			end

			local cooldowns = if typeof(charEntity.AbilityCooldowns) == "table" then charEntity.AbilityCooldowns else {}
			local cooldownEnd = tonumber(cooldowns[castDef.Id]) or 0
			if castDef.SourceType == "Ability" and cooldownEnd > os.clock() then
				fsm:Fail("Ability is on cooldown")
				return
			end

			if castDef.SourceType == "Consumable" then
				if
					not (
						containerHasItem(playerEntity.Inventory, castDef.Id)
						or containerHasItem(playerEntity.BagContents, castDef.Id)
					)
				then
					fsm:Fail("Consumable not found")
					return
				end
			end

			fsm.Context._charEntity = charEntity
			fsm.Context._playerEntity = playerEntity
			fsm.Context._character = character
			fsm.Context._humanoid = humanoid
			fsm.Context._rootPart = rootPart
			fsm.Context._slotIndex = tonumber(fsm.SlotIndex)
			fsm.State = "ValidateResources"
		end,
	}, {"ValidateResources","Failed" })


	--[=[
		@state ValidateResources
		@description Validates the required runtime context and prerequisites, then captures the lock or blocking state needed for the next step.
			Transitions:
			- `AcquireLock` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

	self:AddState("ValidateResources", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local charEntity = fsm.Context._charEntity
			if not castDef or not charEntity then
				fsm:Fail("Cast context missing")
				return
			end
			if (tonumber(charEntity.Stamina) or 0) < castDef.StaminaCost then
				fsm:Fail("Not enough stamina")
				return
			end
			if (tonumber(charEntity.Mana) or 0) < castDef.ManaCost then
				fsm:Fail("Not enough mana")
				return
			end
			fsm.State = "AcquireLock"
		end,
	}, {"AcquireLock","Failed" })


	--[=[
		@state AcquireLock
		@description Captures the lock or blocking state needed for the next step.
			Transitions:
			- `DeductResources` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context._lockHeld`, sets `_lockHeld`.
	]=]

	self:AddState("AcquireLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			if not charEntity or not charEntity:AcquireLock(fsm.Id) then
				fsm:Fail("Character is already performing another action")
				return
			end
			fsm.Context._lockHeld = true
			fsm.State = "DeductResources"
		end,
	}, {"DeductResources","Failed" })


	--[=[
		@state DeductResources
		@description On enter, stores `Context._releaseReason`, sets `_releaseReason`, replicates entity changes.
			Transitions:
			- `ReleaseLock` when this stage finishes its immediate work or falls through its guard checks.
			- `EmitCastAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._releaseReason`, sets `_releaseReason`, replicates entity changes.
	]=]

	self:AddState("DeductResources", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local charEntity = fsm.Context._charEntity
			if not castDef or not charEntity then
				fsm.Context._releaseReason = "Cast context missing"
				fsm.State = "ReleaseLock"
				return
			end
			if not ResourceHelpers.deductStamina(charEntity, castDef.StaminaCost) then
				fsm.Context._releaseReason = "Not enough stamina"
				fsm.State = "ReleaseLock"
				return
			end
			if not ResourceHelpers.deductMana(charEntity, castDef.ManaCost) then
				fsm.Context._releaseReason = "Not enough mana"
				fsm.State = "ReleaseLock"
				return
			end
			charEntity:UpdateEntity(fsm.Id)
			fsm.State = "EmitCastAnimation"
		end,
	}, {"EmitCastAnimation","ReleaseLock" })


	--[=[
		@state EmitCastAnimation
		@description On enter, stores `Context._releaseReason`, stores `Context._movementLocked`, sets `_releaseReason`.
			Transitions:
			- `ReleaseLock` when this stage finishes its immediate work or falls through its guard checks.
			- `WaitCastDuration` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._releaseReason`, stores `Context._movementLocked`, sets `_releaseReason`, sets `ActiveCastId`, sets `CanMove`.
	]=]

	self:AddState("EmitCastAnimation", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local charEntity = fsm.Context._charEntity
			if not castDef or not charEntity then
				fsm.Context._releaseReason = "Casting context missing"
				fsm.State = "ReleaseLock"
				return
			end

			charEntity.ActiveCastId = castDef.Id
			if castDef.CastTime > 0 then
				charEntity.CanMove = false
				fsm.Context._movementLocked = true
			end
			charEntity:UpdateEntity(fsm.Id)

			if typeof(castDef.Animation) == "string" and castDef.Animation ~= "" then
				IntentHelpers.appendIntent(fsm:GetOrchestrator(), charEntity,"Animation", {
					Name = castDef.Animation,
					Speed = 1,
					FadeTime = 0.1,
				}, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
			end
			fsm.State = "WaitCastDuration"
		end,
	}, {"WaitCastDuration","ReleaseLock" })


	--[=[
		@state WaitCastDuration
		@description Waits until its scheduled completion or transition condition is met.
			Transitions:
			- `ValidateNotInterrupted` when the scheduled transition completes.
			- `ReleaseLock` when this stage finishes its immediate work or falls through its guard checks.
			- `ValidateNotInterrupted` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._releaseReason`, sets `_releaseReason`.
	]=]

	self:AddState("WaitCastDuration", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			if not castDef then
				fsm.Context._releaseReason = "Cast definition missing"
				fsm.State = "ReleaseLock"
				return
			end
			local castTime = tonumber(castDef.CastTime) or 0
			if castTime > 0 then
				fsm:ScheduleTransition(castTime,"ValidateNotInterrupted")
			else
				fsm.State = "ValidateNotInterrupted"
			end
		end,
	}, {"ValidateNotInterrupted","ReleaseLock" })


	--[=[
		@state ValidateNotInterrupted
		@description Validates the required runtime context and prerequisites.
			Transitions:
			- `ReleaseLock` when this stage finishes its immediate work or falls through its guard checks.
			- `Execute` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._releaseReason`, sets `_releaseReason`, sets `IsStunned`, sets `IsKnocked`.
	]=]

	self:AddState("ValidateNotInterrupted", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local humanoid = fsm.Context._humanoid
			local rootPart = fsm.Context._rootPart
			if not charEntity or not humanoid or not rootPart or not rootPart.Parent then
				fsm.Context._releaseReason = "Cast context missing"
				fsm.State = "ReleaseLock"
				return
			end
			if charEntity.IsStunned == true or charEntity.IsKnocked == true or humanoid.Health <= 0 then
				fsm.Context._releaseReason = "Cast interrupted"
				fsm.State = "ReleaseLock"
				return
			end
			fsm.State = "Execute"
		end,
	}, {"Execute","ReleaseLock" })


	--[=[
		@state Execute
		@description On enter, stores `Context._releaseReason`, sets `_releaseReason`.
			Transitions:
			- `ReleaseLock` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._releaseReason`, sets `_releaseReason`.
	]=]

	self:AddState("Execute", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local effectType = castDef and castDef.EffectType
			local nextState = EFFECT_STATE_BY_TYPE[effectType]
			if nextState then
				fsm.State = nextState
			else
				fsm.Context._releaseReason = "Unknown effect type: " .. tostring(effectType)
				fsm.State = "ReleaseLock"
			end
		end,
	}, {
		"ExecuteMeleeSingle",
		"ExecuteMeleeAoE",
		"ExecuteProjectile",
		"ExecuteSelfHeal",
		"ExecuteInstantHeal",
		"ExecuteInstantStamina",
		"ExecuteInstantMana",
		"ExecuteDash",
		"ExecuteTargetedAoE",
		"ReleaseLock",
	})


	--[=[
		@state ExecuteMeleeSingle
		@description Runs the `execute melee single` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteMeleeSingle", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			local radius = tonumber(executeContext.CastDef.EffectRadius) or DEFAULT_MELEE_RADIUS
			local victimEntry = CombatHelpers.scanVictims(
				executeContext.Orchestrator,
				fsm.CharacterEntityId,
				executeContext.RootPart.Position,
				radius
			)[1]
			if victimEntry then
				CombatHelpers.createDamageJob(
					executeContext.Orchestrator,
					fsm.CharacterEntityId,
					victimEntry.Entity,
					executeContext.AttackName,
					tonumber(executeContext.CastDef.Damage) or 0
				)
			end
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state ExecuteMeleeAoE
		@description Runs the `execute melee ao e` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteMeleeAoE", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			local radius = tonumber(executeContext.CastDef.EffectRadius) or DEFAULT_MELEE_RADIUS
			for _, victimEntry in ipairs(
				CombatHelpers.scanVictims(executeContext.Orchestrator, fsm.CharacterEntityId, executeContext.RootPart.Position, radius)
			) do
				CombatHelpers.createDamageJob(
					executeContext.Orchestrator,
					fsm.CharacterEntityId,
					victimEntry.Entity,
					executeContext.AttackName,
					tonumber(executeContext.CastDef.Damage) or 0
				)
			end
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state ExecuteProjectile
		@description Runs the `execute projectile` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteProjectile", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			spawnProjectile(
				executeContext.Orchestrator,
				fsm,
				executeContext.CastDef,
				executeContext.CharEntity,
				executeContext.RootPart
			)
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state ExecuteSelfHeal
		@description Runs the `execute self heal` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteSelfHeal", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			applyHealthChange(
				executeContext.CharEntity,
				executeContext.Humanoid,
				tonumber(executeContext.CastDef.HealAmount) or 0,
				fsm.Id
			)
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state ExecuteInstantHeal
		@description Runs the `execute instant heal` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteInstantHeal", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			applyHealthChange(
				executeContext.CharEntity,
				executeContext.Humanoid,
				tonumber(executeContext.CastDef.HealAmount) or 0,
				fsm.Id
			)
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state ExecuteInstantStamina
		@description Runs the `execute instant stamina` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteInstantStamina", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			applyResourceRestore(
				executeContext.CharEntity,
				"Stamina",
				"MaxStamina",
				tonumber(executeContext.CastDef.RestoreAmount) or 0,
				fsm.Id
			)
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state ExecuteInstantMana
		@description Runs the `execute instant mana` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteInstantMana", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			applyResourceRestore(
				executeContext.CharEntity,
				"Mana",
				"MaxMana",
				tonumber(executeContext.CastDef.RestoreAmount) or 0,
				fsm.Id
			)
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state ExecuteDash
		@description Runs the `execute dash` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteDash", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			local targetEntity = resolveTargetEntity(executeContext.Orchestrator, executeContext.CharEntity)
			local dashDirection = executeContext.RootPart.CFrame.LookVector
			if targetEntity and targetEntity.Instance and targetEntity.Instance:IsA("Model") then
				local _, targetRoot = EntityHelpers.getHumanoidAndRoot(targetEntity.Instance)
				if targetRoot then
					local offset = targetRoot.Position - executeContext.RootPart.Position
					if offset.Magnitude > 0.01 then
						dashDirection = offset.Unit
					end
				end
			end

			local dashDistance = tonumber(executeContext.CastDef.DashDistance) or 20
			local bodyVelocity = Instance.new("BodyVelocity")
			bodyVelocity.MaxForce = Vector3.new(1e5, 0, 1e5)
			bodyVelocity.Velocity = dashDirection * (dashDistance / DEFAULT_DASH_DURATION)
			bodyVelocity.Parent = executeContext.RootPart
			Debris:AddItem(bodyVelocity, DEFAULT_DASH_DURATION)
			if targetEntity then
				CombatHelpers.createDamageJob(
					executeContext.Orchestrator,
					fsm.CharacterEntityId,
					targetEntity,
					executeContext.AttackName,
					tonumber(executeContext.CastDef.Damage) or 0
				)
			end
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state ExecuteTargetedAoE
		@description Runs the `execute targeted ao e` stage of `CastFSM`.
			Transitions:
			- `EmitFinishAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ExecuteTargetedAoE", {
		OnEnter = function(_, fsm)
			local executeContext = resolveExecuteContext(fsm)
			if not executeContext then
				return
			end

			local origin = resolveTargetPosition(
				executeContext.Orchestrator,
				executeContext.CharEntity,
				executeContext.RootPart
			)
			local radius = tonumber(executeContext.CastDef.AoERadius)
				or tonumber(executeContext.CastDef.EffectRadius)
				or DEFAULT_MELEE_RADIUS
			for _, victimEntry in ipairs(CombatHelpers.scanVictims(executeContext.Orchestrator, fsm.CharacterEntityId, origin, radius)) do
				CombatHelpers.createDamageJob(
					executeContext.Orchestrator,
					fsm.CharacterEntityId,
					victimEntry.Entity,
					executeContext.AttackName,
					tonumber(executeContext.CastDef.Damage) or 0
				)
			end
			fsm.State = "EmitFinishAnimation"
		end,
	}, {"EmitFinishAnimation","ReleaseLock" })


	--[=[
		@state EmitFinishAnimation
		@description On enter, stores `Context._releaseReason`, sets `_releaseReason`, emits an intent.
			Transitions:
			- `ReleaseLock` when this stage finishes its immediate work or falls through its guard checks.
			- `SetCooldown` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._releaseReason`, sets `_releaseReason`, emits an intent.
	]=]

	self:AddState("EmitFinishAnimation", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local charEntity = fsm.Context._charEntity
			if not castDef or not charEntity then
				fsm.Context._releaseReason = "Finish animation context missing"
				fsm.State = "ReleaseLock"
				return
			end
			if typeof(castDef.FinishAnimation) == "string" and castDef.FinishAnimation ~= "" then
				IntentHelpers.appendIntent(fsm:GetOrchestrator(), charEntity,"Animation", {
					Name = castDef.FinishAnimation,
					Speed = 1,
					FadeTime = 0.1,
				}, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
			end
			fsm.State = "SetCooldown"
		end,
	}, {"SetCooldown","ReleaseLock" })


	--[=[
		@state SetCooldown
		@description Arms the cooldown window before returning control.
			Transitions:
			- `ReleaseLock` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._releaseReason`, sets `_releaseReason`, sets `SourceType`, sets `AbilityCooldowns`, replicates entity changes.
	]=]

	self:AddState("SetCooldown", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local charEntity = fsm.Context._charEntity
			local playerEntity = fsm.Context._playerEntity
			if not castDef or not charEntity then
				fsm.Context._releaseReason = "Cooldown context missing"
				fsm.State = "ReleaseLock"
				return
			end
			if castDef.SourceType == "Consumable" and playerEntity then
				consumePlayerItem(playerEntity, castDef.Id, tonumber(fsm.Context._slotIndex))
			end
			local cooldowns = if typeof(charEntity.AbilityCooldowns) == "table"
				then table.clone(charEntity.AbilityCooldowns)
				else {}
			cooldowns[castDef.Id] = os.clock() + (tonumber(castDef.Cooldown) or 0)
			charEntity.AbilityCooldowns = cooldowns
			charEntity:SetContext("_abilityCooldowns", cooldowns)
			charEntity:UpdateEntity(fsm.Id)
			fsm.State = "ReleaseLock"
		end,
	}, {"ReleaseLock" })


	--[=[
		@state ReleaseLock
		@description On enter, stores `Context._movementLocked`, stores `Context._lockHeld`, sets `CanMove`.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context._movementLocked`, stores `Context._lockHeld`, sets `CanMove`, sets `_movementLocked`, sets `ActiveCastId`.
	]=]

	self:AddState("ReleaseLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local castDef = fsm.Context._castDef
			if not charEntity then
				fsm:Fail(fsm.Context._releaseReason or "Character entity missing during cleanup")
				return
			end
			if fsm.Context._movementLocked then
				charEntity.CanMove = true
				fsm.Context._movementLocked = false
			end
			if castDef and charEntity.ActiveCastId == castDef.Id then
				charEntity.ActiveCastId = ""
			end
			charEntity:UpdateEntity(fsm.Id)
			if fsm.Context._lockHeld then
				charEntity:ReleaseLock(fsm.Id)
				fsm.Context._lockHeld = false
			end
			if fsm.Context._releaseReason then
				fsm:Fail(tostring(fsm.Context._releaseReason))
				return
			end
			fsm.State = "Completed"
		end,
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success sink reached after `ReleaseLock` restores movement, clears `ActiveCastId`, updates the entity, and releases the cast lock. `OnEnter` is a no-op because release cleanup is already complete.
		Transitions: none.
		Writes: none.
]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink entered when cast validation or release cleanup calls `Fail`, including deferred `_releaseReason` errors. `OnEnter` is a no-op; `OnCleanup` still restores movement, clears `ActiveCastId`, and releases any held lock.
		Transitions: none.
		Writes: none in-state; cleanup writes may still run.
]=]

	self:AddState("Failed", function() end, {})
end


--[=[
	@description Attempts to start the `Cast` path when the FSM is in a compatible state.
	@param fsm any -- Value consumed by `RequestCast`.
	@param abilityDef any -- Value consumed by `RequestCast`.
	@param charEntityId any -- Value consumed by `RequestCast`.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

function CastFSM.RequestCast(fsm: any, abilityDef: any, charEntityId: string)
	fsm.Context._abilityDef = abilityDef
	fsm.Context.CharacterEntityId = charEntityId
	fsm.State = "ValidateAbility"
end


--[=[
	@description Restores any mutable runtime state that still needs cleanup if the FSM stops before its normal completion path.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

function CastFSM:OnCleanup()
	local charEntity = self.Context._charEntity
	if not charEntity then
		return
	end

	local shouldUpdate = false
	if self.Context._movementLocked then
		charEntity.CanMove = true
		self.Context._movementLocked = false
		shouldUpdate = true
	end
	if charEntity.ActiveCastId == ((self.Context._castDef and self.Context._castDef.Id) or "") then
		charEntity.ActiveCastId = ""
		shouldUpdate = true
	end
	if self.Context._lockHeld then
		charEntity:ReleaseLock(self.Id)
		self.Context._lockHeld = false
	end
	if shouldUpdate then
		charEntity:UpdateEntity()
	end
end

return CastFSM
