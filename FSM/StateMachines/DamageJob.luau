--!strict
--[=[
    @Name DamageJob
    @Author iKrypto
    @Description Applies validated combat damage from an attacker to a victim, emits the replicated hit reaction payload, shows floating damage text, raises the damage event bus, and applies any passive on-hit status effects before ending in the terminal `Completed` state. Historical integrations must target `Completed`; the deprecated `Complete` spelling is intentionally not part of this FSM.

    State flow diagram:
    Validate → CheckHitNonce → ResolveVictim → ComputeDamage → ApplyDamage → EmitHitReact → EmitDamageText → FireEventBus → ApplyOnHitEffects → Completed
             ↘ Failed

    Context fields:
    - AttackName: string -- normalized attack name used in emitted events.
    - _attackerEntity: any -- resolved attacker character entity.
    - _attackerUserId: number -- user id used for nonce bucketing.
    - _nonce: string -- per-hit dedupe token stored in the processed nonce cache.
    - _victimEntity: any -- resolved victim character entity.
    - _victimEntityId: string -- resolved victim entity id used for status effect application.
    - _victimCharacter: Model -- victim character model.
    - _victimHumanoid: Humanoid -- victim humanoid used for damage application.
    - _victimRoot: BasePart? -- root part used for floating damage text placement.
    - _isVictimBlocking: boolean -- whether damage should be reduced by block logic.
    - _computedDamage: number -- final rounded damage applied to the victim.

    Required params:
    - AttackerCharEntityId: string -- attacker character entity id.
    - VictimUserId: number -- victim player user id.
    - AttackName: string? -- optional attack label; defaults to `BasicAttack`.
    - BaseDamage: number? -- optional explicit base damage override.
]=]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local Shared = ReplicatedStorage:WaitForChild("shared")
local EquipHelpers = require(Shared:WaitForChild("EquipHelpers"))
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local EntityHelpers = require(Helpers:WaitForChild("EntityHelpers"))

local DamageJob = {
	Name = "DamageJob",
	className = "DamageJob",
	validStates = {
		"Validate",
		"CheckHitNonce",
		"ResolveVictim",
		"ComputeDamage",
		"ApplyDamage",
		"EmitHitReact",
		"EmitDamageText",
		"FireEventBus",
		"ApplyOnHitEffects",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local ProcessedNonces: { [number]: { [string]: number } } = {}
local NONCE_EXPIRY = 3
local MAX_NONCES_PER_ATTACKER = 64

--[=[
    @description Removes expired hit nonces from the process-wide cache so duplicate-hit suppression stays bounded.
    @return nil -- Mutates `ProcessedNonces` in place and returns nothing.
]=]
local function cleanExpiredNonces()
	local now = os.clock()
	for attackerUserId, nonceMap in pairs(ProcessedNonces) do
		for nonce, expiry in pairs(nonceMap) do
			if now >= expiry then
				nonceMap[nonce] = nil
			end
		end
		if next(nonceMap) == nil then
			ProcessedNonces[attackerUserId] = nil
		end
	end
end

--[=[
    @description Returns the nonce bucket for one attacker and evicts the oldest nonce when the per-attacker cap has been reached.
    @param attackerUserId number -- Numeric user id for the attacking character.
    @return table -- Mutable nonce-to-expiry map for the attacker.
]=]
local function boundNonceMap(attackerUserId: number)
	local nonceMap = ProcessedNonces[attackerUserId]
	if not nonceMap then
		nonceMap = {}
		ProcessedNonces[attackerUserId] = nonceMap
		return nonceMap
	end

	local count = 0
	local oldestNonce: string? = nil
	local oldestExpiry = math.huge
	for nonce, expiry in pairs(nonceMap) do
		count += 1
		if expiry < oldestExpiry then
			oldestExpiry = expiry
			oldestNonce = nonce
		end
	end

	if count >= MAX_NONCES_PER_ATTACKER and oldestNonce then
		nonceMap[oldestNonce] = nil
	end

	return nonceMap
end

--[=[
    @description Scans orchestrator entities for the victim character entity whose instance is a live humanoid model.
    @param orchestrator any -- Orchestrator that exposes `GetEntities()`.
    @param victimUserId number -- User id of the player being hit.
    @return any? -- Matching victim entity when found.
    @return string? -- Matching victim entity id when found.
]=]
local function resolveVictimEntity(orchestrator: any, victimUserId: number): (any?, string?)
	if type(orchestrator.GetEntities) ~= "function" then
		return nil, nil
	end

	for entityId, entity in pairs(orchestrator.GetEntities()) do
		local instance = entity and entity.Instance
		if entity and entity.UserId == victimUserId and instance and instance:IsA("Model") then
			local humanoid = instance:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return entity, entityId
			end
		end
	end

	return nil, nil
end

--[=[
    @description Normalizes an entity's `ActiveStatusEffects` field to a safe array for downstream calculations.
    @param entity any -- Entity that may contain status effect entries.
    @return table -- Array of active status effect entries, or an empty table.
]=]
local function getActiveStatusEffects(entity: any): { any }
	local activeStatusEffects = entity and entity.ActiveStatusEffects
	if typeof(activeStatusEffects) == "table" then
		return activeStatusEffects
	end
	return {}
end

--[=[
    @description Multiplies outgoing damage by every active status effect modifier on the attacker, including stack counts.
    @param orchestrator any -- Orchestrator used to resolve `StatusEffectDefs`.
    @param entity any -- Attacker entity whose active effects are inspected.
    @return number -- Final multiplicative damage bonus, defaulting to `1`.
]=]
local function getDamageMultiplier(orchestrator: any, entity: any): number
	local defs = ModuleLoader.requireSharedModule(orchestrator, "StatusEffectDefs")
	local multiplier = 1
	for _, entry in ipairs(getActiveStatusEffects(entity)) do
		if typeof(entry) ~= "table" then
			continue
		end
		local def = defs.Get(entry.EffectId)
		local effectMultiplier = tonumber(def and def.DamageMultiplier)
		local stacks = math.max(tonumber(entry.Stacks) or 1, 1)
		if effectMultiplier and effectMultiplier > 0 then
			for _ = 1, stacks do
				multiplier *= effectMultiplier
			end
		end
	end
	return multiplier
end

--[=[
    @description Accumulates additive incoming damage reduction from victim status effects and clamps the total to 90 percent.
    @param orchestrator any -- Orchestrator used to resolve `StatusEffectDefs`.
    @param entity any -- Victim entity whose active effects are inspected.
    @return number -- Damage reduction ratio in the inclusive range `[0, 0.9]`.
]=]
local function getDamageReduction(orchestrator: any, entity: any): number
	local defs = ModuleLoader.requireSharedModule(orchestrator, "StatusEffectDefs")
	local reduction = 0
	for _, entry in ipairs(getActiveStatusEffects(entity)) do
		if typeof(entry) ~= "table" then
			continue
		end
		local def = defs.Get(entry.EffectId)
		local effectReduction = tonumber(def and def.DamageReduction)
		local stacks = math.max(tonumber(entry.Stacks) or 1, 1)
		if effectReduction and effectReduction > 0 then
			reduction += effectReduction * stacks
		end
	end
	return math.clamp(reduction, 0, 0.9)
end

--[=[
    @description Resolves the equipped weapon data for the attacker and asks `DamageCalculator` for its base damage, falling back to 10 when weapon metadata is unavailable.
    @param orchestrator any -- Orchestrator used to resolve player entities and shared modules.
    @param attackerEntity any -- Character entity that owns the attacking player entity id.
    @return number -- Base damage value used before block and status-effect adjustments.
]=]
local function resolveWeaponBaseDamage(orchestrator: any, attackerEntity: any): number
	local DamageCalculator = ModuleLoader.requireSharedModule(orchestrator, "DamageCalculator")
	local baseDamage = 10
	local playerEntityId = attackerEntity and attackerEntity.PlayerEntityId
	if typeof(playerEntityId) ~= "string" or playerEntityId == "" then
		return baseDamage
	end

	local playerEntity = orchestrator.GetEntity(playerEntityId)
	if not playerEntity then
		return baseDamage
	end

	local weaponId = playerEntity.WeaponEqp
	if typeof(weaponId) ~= "string" or weaponId == "" then
		return baseDamage
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return baseDamage
	end

	local item = assets:FindFirstChild(weaponId, true)
	if not item then
		return baseDamage
	end

	local dataModule = EquipHelpers.ResolveDataModule(item)
	if not dataModule then
		return baseDamage
	end

	local ok, itemData = pcall(require, dataModule)
	if ok then
		baseDamage = DamageCalculator.GetWeaponBaseDamage(itemData)
	end

	return baseDamage
end

--[=[
    @description Spawns a transient floating billboard at the victim position and animates the rounded damage amount upward before cleanup.
    @param position Vector3 -- World-space anchor position for the billboard.
    @param damage number -- Final damage value to display.
    @return nil -- Creates temporary instances and schedules their destruction.
]=]
local function showDamageText(position: Vector3, damage: number)
	local lifetime = 1.5
	local stepRate = 1 / 30
	local part = Instance.new("Part")
	part.Name = "DamageTextAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Locked = true
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Transparency = 1
	part.CFrame = CFrame.new(position)
	part.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.new(0, 120, 0, 60)
	billboard.StudsOffset = Vector3.new(0, 1, 0)
	billboard.Adornee = part
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = tostring(math.floor(damage + 0.5))
	label.TextColor3 = Color3.fromRGB(220, 48, 48)
	label.TextScaled = true
	label.TextStrokeTransparency = 0.3
	label.Parent = billboard

	Debris:AddItem(part, lifetime + 0.25)
	task.spawn(function()
		local frames = math.max(1, math.floor(lifetime / stepRate))
		for frame = 1, frames do
			if not part.Parent then
				return
			end
			task.wait(stepRate)
			local alpha = frame / frames
			part.CFrame = CFrame.new(position + Vector3.new(0, alpha * 2.5, 0))
			label.TextTransparency = alpha
			label.TextStrokeTransparency = 0.3 + alpha * 0.7
		end
		if part.Parent then
			part:Destroy()
		end
	end)
end
--[=[
	@description Handles `RegisterStates` for `DamageJob`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function DamageJob:RegisterStates()
--[=[
	@state Validate
	@description Handles the `Validate` state for `DamageJob`.
]=]

self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				fsm:Fail("Orchestrator unavailable")
				return
			end

			local attackerEntityId = fsm.AttackerCharEntityId
			if typeof(attackerEntityId) ~= "string" or attackerEntityId == "" then
				fsm:Fail("AttackerCharEntityId is required")
				return
			end

			local attackerEntity = fsm:GetEntity(attackerEntityId)
			if not attackerEntity then
				fsm:Fail("Attacker entity not found")
				return
			end

			local attackerUserId = attackerEntity.UserId
			if typeof(attackerUserId) ~= "number" then
				fsm:Fail("Attacker entity missing UserId")
				return
			end

			if typeof(fsm.VictimUserId) ~= "number" then
				fsm:Fail("VictimUserId is required")
				return
			end

			local attackName = if typeof(fsm.AttackName) == "string" and fsm.AttackName ~= ""
				then fsm.AttackName
				else "BasicAttack"
			fsm.Context.AttackName = attackName
			fsm.Context._attackerEntity = attackerEntity
			fsm.Context._attackerUserId = attackerUserId
			fsm.Context._nonce = string.format("%d:%s:%.6f", attackerUserId, attackName, os.clock())
			fsm.State = "CheckHitNonce"
		end,
	}, { "CheckHitNonce", "Failed" })
--[=[
	@state CheckHitNonce
	@description Handles the `CheckHitNonce` state for `DamageJob`.
]=]

self:AddState("CheckHitNonce", {
		OnEnter = function(_, fsm)
			cleanExpiredNonces()
			local attackerUserId = fsm.Context._attackerUserId
			local nonce = fsm.Context._nonce
			if typeof(attackerUserId) ~= "number" or typeof(nonce) ~= "string" then
				fsm:Fail("Missing nonce context")
				return
			end

			local nonceMap = boundNonceMap(attackerUserId)
			if nonceMap[nonce] ~= nil then
				fsm:Fail("Duplicate hit nonce")
				return
			end

			nonceMap[nonce] = os.clock() + NONCE_EXPIRY
			fsm.State = "ResolveVictim"
		end,
	}, { "ResolveVictim", "Failed" })
--[=[
	@state ResolveVictim
	@description Handles the `ResolveVictim` state for `DamageJob`.
]=]

self:AddState("ResolveVictim", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				fsm:Fail("Orchestrator unavailable")
				return
			end

			local victimEntity, victimEntityId = resolveVictimEntity(orchestrator, fsm.VictimUserId)
			if not victimEntity then
				fsm:Fail("Victim character entity not found")
				return
			end

			local character = victimEntity.Instance
			if not character or not character:IsA("Model") then
				fsm:Fail("Victim character model missing")
				return
			end

			local humanoid, root = EntityHelpers.getHumanoidAndRoot(character)
			if not humanoid or humanoid.Health <= 0 then
				fsm:Fail("Victim humanoid unavailable or dead")
				return
			end

			fsm.Context._victimEntity = victimEntity
			fsm.Context._victimEntityId = victimEntityId
			fsm.Context._victimCharacter = character
			fsm.Context._victimHumanoid = humanoid
			fsm.Context._victimRoot = root
			fsm.Context._isVictimBlocking = victimEntity.IsBlocking == true
			fsm.State = "ComputeDamage"
		end,
	}, { "ComputeDamage", "Failed" })
--[=[
	@state ComputeDamage
	@description Handles the `ComputeDamage` state for `DamageJob`.
]=]

self:AddState("ComputeDamage", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local DamageCalculator = ModuleLoader.requireSharedModule(orchestrator, "DamageCalculator")
			local attackerEntity = fsm.Context._attackerEntity
			if not orchestrator or not attackerEntity then
				fsm:Fail("Attacker context missing")
				return
			end

			local explicitBaseDamage = tonumber(fsm.BaseDamage)
			local baseDamage = explicitBaseDamage or resolveWeaponBaseDamage(orchestrator, attackerEntity)
			local computedDamage = DamageCalculator.Compute(baseDamage, fsm.Context._isVictimBlocking == true)
			computedDamage *= getDamageMultiplier(orchestrator, attackerEntity)
			computedDamage *= (1 - getDamageReduction(orchestrator, fsm.Context._victimEntity))
			fsm.Context._computedDamage = math.max(0, math.floor(computedDamage + 0.5))
			fsm.State = "ApplyDamage"
		end,
	}, { "ApplyDamage", "Failed" })
--[=[
	@state ApplyDamage
	@description Handles the `ApplyDamage` state for `DamageJob`.
]=]

self:AddState("ApplyDamage", {
		OnEnter = function(_, fsm)
			local victimHumanoid = fsm.Context._victimHumanoid
			local victimEntity = fsm.Context._victimEntity
			local computedDamage = fsm.Context._computedDamage
			if not victimHumanoid or typeof(computedDamage) ~= "number" then
				fsm:Fail("Damage application context missing")
				return
			end

			if victimHumanoid.Health > 0 then
				victimHumanoid:TakeDamage(computedDamage)
			end
			if victimEntity then
				victimEntity.Health = victimHumanoid.Health
				victimEntity:UpdateEntity()
			end
			fsm.State = "EmitHitReact"
		end,
	}, { "EmitHitReact", "Failed" })
--[=[
	@state EmitHitReact
	@description Handles the `EmitHitReact` state for `DamageJob`.
]=]

self:AddState("EmitHitReact", {
		OnEnter = function(_, fsm)
			local IntentSchema = ModuleLoader.requireSharedModule(fsm:GetOrchestrator(), "IntentSchema")
			local victimEntity = fsm.Context._victimEntity
			local computedDamage = fsm.Context._computedDamage
			if not victimEntity or typeof(computedDamage) ~= "number" then
				fsm:Fail("Hit react context missing")
				return
			end

			local victimCharId = if typeof(victimEntity.EntityId) == "string"
				then victimEntity.EntityId
				else tostring(fsm.VictimUserId)
			IntentSchema.AppendIntent(victimEntity, {
				Kind = "HitReact",
				Payload = {
					Damage = computedDamage,
					AttackerCharId = fsm.AttackerCharEntityId,
				},
				SourceCharId = fsm.AttackerCharEntityId,
				TargetCharId = victimCharId,
			})
			fsm.State = "EmitDamageText"
		end,
	}, { "EmitDamageText", "Failed" })
--[=[
	@state EmitDamageText
	@description Handles the `EmitDamageText` state for `DamageJob`.
]=]

self:AddState("EmitDamageText", {
		OnEnter = function(_, fsm)
			local root = fsm.Context._victimRoot
			local damage = fsm.Context._computedDamage
			if root and typeof(damage) == "number" then
				showDamageText(root.Position + Vector3.new(0, 2.5, 0), damage)
			end
			fsm.State = "FireEventBus"
		end,
	}, { "FireEventBus", "Failed" })
--[=[
	@state FireEventBus
	@description Handles the `FireEventBus` state for `DamageJob`.
]=]

self:AddState("FireEventBus", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				fsm:Fail("Orchestrator unavailable")
				return
			end

			local victimEntity = fsm.Context._victimEntity
			local computedDamage = fsm.Context._computedDamage
			if not victimEntity or typeof(computedDamage) ~= "number" then
				fsm:Fail("Event bus context missing")
				return
			end

			pcall(function()
				orchestrator.RegisterEventBus("Damage/Applied")
			end)
			local victimCharId = if typeof(victimEntity.EntityId) == "string"
				then victimEntity.EntityId
				else tostring(fsm.VictimUserId)
			orchestrator.FireEventBus("Damage/Applied", {
				AttackerCharId = fsm.AttackerCharEntityId,
				VictimCharId = victimCharId,
				VictimUserId = victimEntity.UserId,
				Damage = computedDamage,
				AttackName = fsm.Context.AttackName,
				Nonce = fsm.Context._nonce,
			})
			fsm.State = "ApplyOnHitEffects"
		end,
	}, { "ApplyOnHitEffects", "Failed" })
--[=[
	@state ApplyOnHitEffects
	@description Handles the `ApplyOnHitEffects` state for `DamageJob`.
]=]

self:AddState("ApplyOnHitEffects", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local attackerEntity = fsm.Context._attackerEntity
			local victimEntityId = fsm.Context._victimEntityId
			if orchestrator and attackerEntity and typeof(victimEntityId) == "string" then
				local playerEntityId = attackerEntity.PlayerEntityId
				local playerEntity = if typeof(playerEntityId) == "string" then fsm:GetEntity(playerEntityId) else nil
				if playerEntity then
					local talentTreeDefs = ModuleLoader.requireSharedModule(orchestrator, "TalentTreeDefs")
					local statusEffectHelper = ModuleLoader.requireSharedModule(orchestrator, "StatusEffectHelper")
					local passiveEffects = talentTreeDefs.GetMergedPassiveEffects(playerEntity)
					if typeof(passiveEffects.BuffOnHit) == "string" and passiveEffects.BuffOnHit ~= "" then
						statusEffectHelper.Apply(orchestrator, victimEntityId, passiveEffects.BuffOnHit)
					end
				end
			end
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })
--[=[
	@state Completed
	@description Handles the `Completed` terminal state for `DamageJob`.
]=]

self:AddState("Completed", function() end, {})
--[=[
	@state Failed
	@description Handles the `Failed` terminal state for `DamageJob`.
]=]

self:AddState("Failed", function() end, {})
end
--[=[
	@description Implements `DamageJob.OnCleanup`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function DamageJob:OnCleanup() end

return DamageJob
