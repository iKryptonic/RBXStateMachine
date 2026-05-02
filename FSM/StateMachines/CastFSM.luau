--!strict
-- @Name CastFSM
-- @Description FSM state machine module.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
		"ExecuteEffect",
		"EmitFinishAnimation",
		"SetCooldown",
		"ReleaseLock",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "Idle",
}

local DEFAULT_MELEE_RADIUS = 6
local DEFAULT_PROJECTILE_SPEED = 120
local DEFAULT_PROJECTILE_LIFETIME = 3
local DEFAULT_DASH_DURATION = 0.2

local function getSharedModule(orchestrator: any, name: string)
	local getModule = orchestrator and orchestrator.GetModule
	if type(getModule) == "function" then
		local module = getModule(name)
		if module ~= nil then
			return module
		end
	end

	local sharedFolder = ReplicatedStorage:FindFirstChild("shared")
	if sharedFolder then
		local mod = sharedFolder:FindFirstChild(name)
		if mod and mod:IsA("ModuleScript") then
			return require(mod)
		end
	end

	local replicatedMod = ReplicatedStorage:FindFirstChild(name, true)
	if replicatedMod and replicatedMod:IsA("ModuleScript") then
		return require(replicatedMod)
	end

	error("Shared module not found: " .. name)
end

local function getAbilityDefs(orchestrator: any)
	return getSharedModule(orchestrator, "AbilityDefs")
end

local function getTalentTreeDefs(orchestrator: any)
	return getSharedModule(orchestrator, "TalentTreeDefs")
end

local function getStatusEffectDefs(orchestrator: any)
	return getSharedModule(orchestrator, "StatusEffectDefs")
end

local function getHumanoidAndRoot(character: Model): (Humanoid?, BasePart?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		root = character.PrimaryPart
	end
	if root and not root:IsA("BasePart") then
		root = nil
	end
	return humanoid, root :: BasePart?
end

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

	local dataModule = item:FindFirstChild("Data")
	if not dataModule or not dataModule:IsA("ModuleScript") then
		return nil
	end

	local ok, data = pcall(require, dataModule)
	return if ok then data else nil
end

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
				return true, tostring(def.Name or entry.EffectId) .. " prevents ability usage"
			end
			local flags = def.ApplyFlags
			if typeof(flags) == "table" and flags.IsStunned == true then
				return true, tostring(def.Name or entry.EffectId) .. " prevents ability usage"
			end
		end
	end

	return false, nil
end

local function resolveCastDef(fsm: any, orchestrator: any): any?
	local cached = fsm.Context._castDef
	if cached then
		return cached
	end

	local abilityDefs = getAbilityDefs(orchestrator)
	local rawDef = fsm.Context._abilityDef
	local sourceType = if rawDef and typeof(rawDef.SourceType) == "string" then rawDef.SourceType else "Ability"
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

local function appendIntent(
	orchestrator: any,
	characterEntity: any,
	kind: string,
	payload: { [string]: any },
	sourceCharId: string,
	targetCharId: string?,
	lockId: string?
)
	local intentSchema = getSharedModule(orchestrator, "IntentSchema")
	intentSchema.AppendIntent(characterEntity, {
		Kind = kind,
		Payload = payload,
		SourceCharId = sourceCharId,
		TargetCharId = targetCharId or sourceCharId,
	}, lockId)
end

local function resolveTargetEntity(orchestrator: any, charEntity: any): any?
	local targetEntityId = charEntity.TargetEntityId
	if typeof(targetEntityId) ~= "string" or targetEntityId == "" then
		return nil
	end
	return orchestrator.GetEntity(targetEntityId)
end

local function resolveTargetPosition(orchestrator: any, charEntity: any, fallbackRoot: BasePart): Vector3
	local targetEntity = resolveTargetEntity(orchestrator, charEntity)
	if targetEntity and targetEntity.Instance and targetEntity.Instance:IsA("Model") then
		local _, targetRoot = getHumanoidAndRoot(targetEntity.Instance)
		if targetRoot then
			return targetRoot.Position
		end
	end
	return fallbackRoot.Position + fallbackRoot.CFrame.LookVector * 10
end

local function scanVictims(orchestrator: any, sourceCharId: string, origin: Vector3, radius: number): { any }
	local candidates = {} :: { { Entity: any, Distance: number } }
	local entities = if typeof(orchestrator.GetEntities) == "function" then orchestrator.GetEntities() else {}
	for entityId, entity in pairs(entities) do
		if entityId == sourceCharId then
			continue
		end

		local character = entity and entity.Instance
		if not character or not character:IsA("Model") then
			continue
		end

		local humanoid, root = getHumanoidAndRoot(character)
		if not humanoid or humanoid.Health <= 0 or not root then
			continue
		end

		local distance = (root.Position - origin).Magnitude
		if distance <= radius then
			table.insert(candidates, {
				Entity = entity,
				Distance = distance,
			})
		end
	end

	table.sort(candidates, function(a, b)
		return a.Distance < b.Distance
	end)

	local victims = {}
	for _, entry in ipairs(candidates) do
		table.insert(victims, entry.Entity)
	end
	return victims
end

local function createDamageJob(
	orchestrator: any,
	attackerCharEntityId: string,
	victimEntity: any,
	attackName: string,
	baseDamage: number
)
	local victimUserId = victimEntity and victimEntity.UserId
	if typeof(victimUserId) ~= "number" then
		return
	end

	local job = orchestrator.CreateStateMachine({
		StateMachineClass = "DamageJob",
		StateMachineId = string.format("CastDamage_%s_%s_%s", attackerCharEntityId, attackName, tostring(os.clock())),
		Context = {
			AttackerCharEntityId = attackerCharEntityId,
			VictimUserId = victimUserId,
			AttackName = attackName,
			BaseDamage = baseDamage,
		},
	})
	if job then
		job:Start({ State = "Validate" })
	end
end

local function clampResource(value: number, maximum: number): number
	return math.clamp(value, 0, maximum)
end

local function applyHealthChange(charEntity: any, humanoid: Humanoid, amount: number, lockId: string?)
	local maxHealth = tonumber(charEntity.MaxHealth) or humanoid.MaxHealth
	local nextHealth = clampResource((tonumber(charEntity.Health) or humanoid.Health) + amount, maxHealth)
	charEntity.Health = nextHealth
	humanoid.Health = math.clamp(nextHealth, 0, humanoid.MaxHealth)
	charEntity:UpdateEntity(lockId)
end

local function applyResourceRestore(
	charEntity: any,
	fieldName: string,
	maxFieldName: string,
	amount: number,
	lockId: string?
)
	local current = tonumber(charEntity[fieldName]) or 0
	local maximum = tonumber(charEntity[maxFieldName]) or current
	charEntity[fieldName] = clampResource(current + amount, maximum)
	charEntity:UpdateEntity(lockId)
end

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
				then "Count"
				elseif itemClone.Quantity ~= nil then "Quantity"
				elseif itemClone.Amount ~= nil then "Amount"
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
				then "Count"
				elseif itemClone.Quantity ~= nil then "Quantity"
				elseif itemClone.Amount ~= nil then "Amount"
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
			createDamageJob(
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

local function executeCastEffect(
	orchestrator: any,
	fsm: any,
	castDef: any,
	charEntity: any,
	playerEntity: any,
	humanoid: Humanoid,
	rootPart: BasePart
)
	local effectType = castDef.EffectType
	local attackName = castDef.Id or castDef.Name or "Cast"

	if effectType == "MeleeSingle" then
		local radius = tonumber(castDef.EffectRadius) or DEFAULT_MELEE_RADIUS
		local victims = scanVictims(orchestrator, fsm.CharacterEntityId, rootPart.Position, radius)
		local victim = victims[1]
		if victim then
			createDamageJob(orchestrator, fsm.CharacterEntityId, victim, attackName, tonumber(castDef.Damage) or 0)
		end
	elseif effectType == "MeleeAoE" then
		local radius = tonumber(castDef.EffectRadius) or DEFAULT_MELEE_RADIUS
		for _, victim in ipairs(scanVictims(orchestrator, fsm.CharacterEntityId, rootPart.Position, radius)) do
			createDamageJob(orchestrator, fsm.CharacterEntityId, victim, attackName, tonumber(castDef.Damage) or 0)
		end
	elseif effectType == "Projectile" then
		spawnProjectile(orchestrator, fsm, castDef, charEntity, rootPart)
	elseif effectType == "SelfHeal" then
		applyHealthChange(charEntity, humanoid, tonumber(castDef.HealAmount) or 0, fsm.Id)
	elseif effectType == "InstantHeal" then
		applyHealthChange(charEntity, humanoid, tonumber(castDef.HealAmount) or 0, fsm.Id)
	elseif effectType == "InstantStamina" then
		applyResourceRestore(charEntity, "Stamina", "MaxStamina", tonumber(castDef.RestoreAmount) or 0, fsm.Id)
	elseif effectType == "InstantMana" then
		applyResourceRestore(charEntity, "Mana", "MaxMana", tonumber(castDef.RestoreAmount) or 0, fsm.Id)
	elseif effectType == "Dash" then
		local targetEntity = resolveTargetEntity(orchestrator, charEntity)
		local dashDirection = rootPart.CFrame.LookVector
		if targetEntity and targetEntity.Instance and targetEntity.Instance:IsA("Model") then
			local _, targetRoot = getHumanoidAndRoot(targetEntity.Instance)
			if targetRoot then
				local offset = targetRoot.Position - rootPart.Position
				if offset.Magnitude > 0.01 then
					dashDirection = offset.Unit
				end
			end
		end
		local dashDistance = tonumber(castDef.DashDistance) or 20
		local dashDuration = DEFAULT_DASH_DURATION
		local bodyVelocity = Instance.new("BodyVelocity")
		bodyVelocity.MaxForce = Vector3.new(1e5, 0, 1e5)
		bodyVelocity.Velocity = dashDirection * (dashDistance / dashDuration)
		bodyVelocity.Parent = rootPart
		Debris:AddItem(bodyVelocity, dashDuration)
		if targetEntity then
			createDamageJob(
				orchestrator,
				fsm.CharacterEntityId,
				targetEntity,
				attackName,
				tonumber(castDef.Damage) or 0
			)
		end
	elseif effectType == "TargetedAoE" then
		local origin = resolveTargetPosition(orchestrator, charEntity, rootPart)
		local radius = tonumber(castDef.AoERadius) or tonumber(castDef.EffectRadius) or DEFAULT_MELEE_RADIUS
		for _, victim in ipairs(scanVictims(orchestrator, fsm.CharacterEntityId, origin, radius)) do
			createDamageJob(orchestrator, fsm.CharacterEntityId, victim, attackName, tonumber(castDef.Damage) or 0)
		end
	end

	if castDef.SourceType == "Consumable" then
		consumePlayerItem(playerEntity, castDef.Id, tonumber(fsm.Context._slotIndex))
	end
end

function CastFSM:RegisterStates()
	self:AddState("Idle", function() end, { "ValidateAbility" })

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

			local humanoid, rootPart = getHumanoidAndRoot(character)
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
	}, { "ValidateResources", "Failed" })

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
	}, { "AcquireLock", "Failed" })

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
	}, { "DeductResources", "Failed" })

	self:AddState("DeductResources", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local charEntity = fsm.Context._charEntity
			if not castDef or not charEntity then
				fsm.Context._releaseReason = "Cast context missing"
				fsm.State = "ReleaseLock"
				return
			end
			charEntity.Stamina = math.max(0, (tonumber(charEntity.Stamina) or 0) - castDef.StaminaCost)
			charEntity.Mana = math.max(0, (tonumber(charEntity.Mana) or 0) - castDef.ManaCost)
			charEntity:UpdateEntity(fsm.Id)
			fsm.State = "EmitCastAnimation"
		end,
	}, { "EmitCastAnimation", "ReleaseLock" })

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
				appendIntent(fsm:GetOrchestrator(), charEntity, "Animation", {
					Name = castDef.Animation,
					Speed = 1,
					FadeTime = 0.1,
				}, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
			end
			fsm.State = "WaitCastDuration"
		end,
	}, { "WaitCastDuration", "ReleaseLock" })

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
				fsm:ScheduleTransition(castTime, "ValidateNotInterrupted")
			else
				fsm.State = "ValidateNotInterrupted"
			end
		end,
	}, { "ValidateNotInterrupted", "ReleaseLock" })

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
			fsm.State = "ExecuteEffect"
		end,
	}, { "ExecuteEffect", "ReleaseLock" })

	self:AddState("ExecuteEffect", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local charEntity = fsm.Context._charEntity
			local playerEntity = fsm.Context._playerEntity
			local humanoid = fsm.Context._humanoid
			local rootPart = fsm.Context._rootPart
			if not castDef or not charEntity or not humanoid or not rootPart then
				fsm.Context._releaseReason = "Execute context missing"
				fsm.State = "ReleaseLock"
				return
			end
			executeCastEffect(fsm:GetOrchestrator(), fsm, castDef, charEntity, playerEntity, humanoid, rootPart)
			fsm.State = "EmitFinishAnimation"
		end,
	}, { "EmitFinishAnimation", "ReleaseLock" })

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
				appendIntent(fsm:GetOrchestrator(), charEntity, "Animation", {
					Name = castDef.FinishAnimation,
					Speed = 1,
					FadeTime = 0.1,
				}, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
			end
			fsm.State = "SetCooldown"
		end,
	}, { "SetCooldown", "ReleaseLock" })

	self:AddState("SetCooldown", {
		OnEnter = function(_, fsm)
			local castDef = fsm.Context._castDef
			local charEntity = fsm.Context._charEntity
			if not castDef or not charEntity then
				fsm.Context._releaseReason = "Cooldown context missing"
				fsm.State = "ReleaseLock"
				return
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
	}, { "ReleaseLock" })

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
	}, { "Completed", "Failed" })

	self:AddState("Completed", function() end, {})
	self:AddState("Failed", function() end, {})
end

function CastFSM.RequestCast(fsm: any, abilityDef: any, charEntityId: string)
	fsm.Context._abilityDef = abilityDef
	fsm.Context.CharacterEntityId = charEntityId
	fsm.State = "ValidateAbility"
end

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
