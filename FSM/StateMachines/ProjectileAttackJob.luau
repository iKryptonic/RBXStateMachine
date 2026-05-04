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
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

--[=[
	@module ProjectileAttackJob
	@description Validates a ranged attack, spends mana, emits charge and fire intents, spawns a projectile, handles impact, then cleans up and releases the lock.
]=]

local ProjectileAttackJob = {
	Name = "ProjectileAttackJob",
	className = "ProjectileAttackJob",
	validStates = {
		"Validate",
		"AcquireLock",
		"ValidateMana",
		"DeductMana",
		"EmitChargeAnimation",
		"WaitCharge",
		"ValidateForFire",
		"EmitFireAnimation",
		"SpawnProjectile",
		"ConfigurePhysics",
		"RegisterHitDetection",
		"WaitForImpact",
		"ProcessHit",
		"ApplyProjectileKnockback",
		"DestroyProjectile",
		"ReleaseLock",
		"Completed",
		"Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Validate",
}

local DEFAULT_PROJECTILE_SPEED = 150
local DEFAULT_PROJECTILE_LIFETIME = 3
local DEFAULT_PROJECTILE_DAMAGE = 20
local DEFAULT_CHARGE_TIME = 0.3
local DEFAULT_GRAVITY = Vector3.new(0, -30, 0)

--[=[
	@description Resolves get item data from the FSM context or entity state.
]=]
local function getItemData(weaponId: string): any?
	local RS = game:GetService("ReplicatedStorage")
	local assets = RS:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local item = assets:FindFirstChild(weaponId, true)
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
	@description Resolves get projectile template from the FSM context or entity state.
]=]
local function getProjectileTemplate(weaponId: string): BasePart?
	local RS = game:GetService("ReplicatedStorage")
	local assets = RS:FindFirstChild("Assets")
	if not assets then
		return nil
	end
	local names = {"Arrow", weaponId .."Projectile","UnleashArrow","ZephyrProjectile" }
	for _, name in ipairs(names) do
		local template = assets:FindFirstChild(name)
		if template and template:IsA("BasePart") then
			return template
		end
	end
	return nil
end

--[=[
	@description Disconnects projectile hit detection, destroys the projectile instance, and clears cached hit data.
	@param fsm any  -- ProjectileAttackJob instance carrying projectile state, hit data, and lock cleanup.
	@return nil -- Removes cached projectile runtime state in place.
]=]

local function cleanupProjectile(fsm: any)
	local hitConn = fsm.Context._hitConn
	if hitConn then
		pcall(function()
			hitConn:Disconnect()
		end)
		fsm.Context._hitConn = nil
	end

	local projectile = fsm.Context._projectile
	if projectile and projectile.Parent then
		projectile:Destroy()
	end
	fsm.Context._projectile = nil
	fsm.Context._hitData = nil
	fsm.Context._impactResolved = false
end

--[=[
	@description Scans for valid damage targets within the attack radius using CombatHelpers, filtering by line-of-sight and alive state.
]=]
local function getVictimEntity(orchestrator: any, targetModel: Model): any?
	local entities = orchestrator.GetEntities and orchestrator.GetEntities() or {}
	for _, entity in pairs(entities) do
		if entity.Instance == targetModel then
			return entity
		end
	end
	return nil
end

--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `ProjectileAttackJob`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function ProjectileAttackJob:RegisterStates()

	--[=[
	@state Validate
	@description Resolves the ranged attacker, validates weapon type and crowd-control state, then caches mana cost, projectile stats, and runtime parts.
	Transitions:
	- `AcquireLock` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: stores `Context._manaCost`, stores `Context._charEntity`, stores `Context._character`, stores `Context._humanoid`, stores `Context._rootPart`.

]=]

	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntityId = fsm.CharacterEntityId
			if typeof(charEntityId) ~= "string" or charEntityId == "" then
				fsm:Fail("CharacterEntityId required")
				return
			end

			local charEntity = fsm:GetEntity(charEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				fsm:Fail("Character model not found")
				return
			end

			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local rootPart = character:FindFirstChild("HumanoidRootPart")
			if not humanoid or humanoid.Health <= 0 or not rootPart then
				fsm:Fail("Character cannot attack")
				return
			end

			if EntityHelpers.isCrowdControlled(charEntity) then
				fsm:Fail("Character is crowd-controlled")
				return
			end

			local weaponId = charEntity.EquippedRight
			if typeof(weaponId) ~= "string" or weaponId == "" then
				weaponId = charEntity.EquippedLeft
			end
			if typeof(weaponId) ~= "string" or weaponId == "" then
				fsm:Fail("No ranged weapon equipped")
				return
			end

			local itemData = getItemData(weaponId)
			if not itemData then
				fsm:Fail("Weapon data not found: " .. weaponId)
				return
			end

			local weaponType = itemData.WeaponType
			if weaponType ~= "Bow" and weaponType ~= "Staff" and weaponType ~= "Ranged" then
				fsm:Fail("Weapon is not ranged: " .. tostring(weaponType))
				return
			end

			fsm.Context._manaCost = itemData.ManaCost or 10
			fsm.Context._charEntity = charEntity
			fsm.Context._character = character
			fsm.Context._humanoid = humanoid
			fsm.Context._rootPart = rootPart
			fsm.Context._weaponId = weaponId
			fsm.Context._itemData = itemData
			fsm.Context._damage = (itemData.WeaponStats and itemData.WeaponStats.Attack) or DEFAULT_PROJECTILE_DAMAGE
			fsm.Context._speed = itemData.ProjectileSpeed or DEFAULT_PROJECTILE_SPEED
			fsm.Context._lifetime = itemData.ProjectileLifetime or DEFAULT_PROJECTILE_LIFETIME
			fsm.Context._chargeTime = itemData.ChargeTime or DEFAULT_CHARGE_TIME
			fsm.State = "AcquireLock"
		end,
	}, {"AcquireLock","Failed" })

	--[=[
	@state AcquireLock
	@description Acquires the character action lock so the ranged attack owns its cast and projectile lifetime.
	Transitions:
	- `ValidateMana` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: stores `Context._lockHeld`, sets `_lockHeld`.

]=]

	self:AddState("AcquireLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			if not charEntity:AcquireLock(fsm.Id) then
				fsm:Fail("Character is already performing another action")
				return
			end
			fsm.Context._lockHeld = true
			fsm.State = "ValidateMana"
		end,
	}, {"ValidateMana","Failed" })

	--[=[
	@state ValidateMana
	@description Checks the cached mana cost before the projectile attack spends anything.
	Transitions:
	- `DeductMana` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("ValidateMana", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local manaCost = fsm.Context._manaCost or 0
			if (charEntity.Mana or 0) < manaCost then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Not enough mana")
				return
			end
			fsm.State = "DeductMana"
		end,
	}, {"DeductMana","ReleaseLock" })

	--[=[
	@state DeductMana
	@description Deducts mana, replicates the spend, and queues lock release when the cost can no longer be paid.
	Transitions:
	- `EmitChargeAnimation` when OnEnter finishes or falls through its guard checks.
	Writes: replicates entity changes.

]=]

	self:AddState("DeductMana", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local manaCost = fsm.Context._manaCost or 0
			if not ResourceHelpers.deductMana(charEntity, manaCost) then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Not enough mana")
				return
			end
			charEntity:UpdateEntity(fsm.Id)
			fsm.State = "EmitChargeAnimation"
		end,
	}, {"EmitChargeAnimation" })

	--[=[
	@state EmitChargeAnimation
	@description Appends the charge-up animation intent before the bow or staff waits out its charge time.
	Transitions:
	- `WaitCharge` when OnEnter finishes or falls through its guard checks.
	Writes: emits an intent.

]=]

	self:AddState("EmitChargeAnimation", {
		OnEnter = function(_, fsm)
			IntentHelpers.appendIntent(fsm:GetOrchestrator(), fsm.Context._charEntity,"Animation", { Name = "Charge1", Speed = 0.25, FadeTime = 0.1 }, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
			fsm.State = "WaitCharge"
		end,
	}, {"WaitCharge" })

	--[=[
	@state WaitCharge
	@description Waits out the configured charge time, scheduling `ValidateForFire` or skipping there immediately for instant shots.
	Transitions:
	- `ValidateForFire` when the scheduled transition completes.
	- `ValidateForFire` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("WaitCharge", {
		OnEnter = function(_, fsm)
			local chargeTime = fsm.Context._chargeTime or DEFAULT_CHARGE_TIME
			if chargeTime > 0 then
				fsm:ScheduleTransition(chargeTime,"ValidateForFire")
			else
				fsm.State = "ValidateForFire"
			end
		end,
	}, {"ValidateForFire","Failed" })

	--[=[
	@state ValidateForFire
	@description Re-checks that the attacker root still exists before the projectile is fired.
	Transitions:
	- `EmitFireAnimation` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("ValidateForFire", {
		OnEnter = function(_, fsm)
			local rootPart = fsm.Context._rootPart
			if not rootPart or not rootPart.Parent then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Character root lost before firing")
				return
			end
			fsm.State = "EmitFireAnimation"
		end,
	}, {"EmitFireAnimation","ReleaseLock" })

	--[=[
	@state EmitFireAnimation
	@description Appends the release animation intent immediately before projectile spawn.
	Transitions:
	- `SpawnProjectile` when OnEnter finishes or falls through its guard checks.
	Writes: emits an intent.

]=]

	self:AddState("EmitFireAnimation", {
		OnEnter = function(_, fsm)
			IntentHelpers.appendIntent(fsm:GetOrchestrator(), fsm.Context._charEntity,"Animation", { Name = "Charge2", Speed = 0.5, FadeTime = 0.1 }, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
			fsm.State = "SpawnProjectile"
		end,
	}, {"SpawnProjectile" })

	--[=[
	@state SpawnProjectile
	@description Clones the configured projectile template when available, otherwise builds a default neon orb, and caches the new projectile instance.
	Transitions:
	- `ConfigurePhysics` when OnEnter finishes or falls through its guard checks.
	Writes: stores `Context._projectile`, sets `Shape`, sets `Size`, sets `Color`, sets `Material`.

]=]

	self:AddState("SpawnProjectile", {
		OnEnter = function(_, fsm)
			local template = getProjectileTemplate(fsm.Context._weaponId)
			local projectile: BasePart
			if template then
				projectile = template:Clone()
			else
				projectile = Instance.new("Part")
				projectile.Shape = Enum.PartType.Ball
				projectile.Size = Vector3.new(1, 1, 1)
				projectile.Color = Color3.fromRGB(255, 200, 50)
				projectile.Material = Enum.Material.Neon
			end
			projectile.Name = "Projectile_" .. fsm.Id
			fsm.Context._projectile = projectile
			fsm.State = "ConfigurePhysics"
		end,
	}, {"ConfigurePhysics" })

	--[=[
	@state ConfigurePhysics
	@description Positions the projectile in front of the attacker, enables touch-only physics, assigns launch velocity, and parents it to workspace.
	Transitions:
	- `RegisterHitDetection` when OnEnter finishes or falls through its guard checks.
	Writes: sets `CFrame`, sets `Anchored`, sets `CanCollide`, sets `CanQuery`, sets `CanTouch`.

]=]

	self:AddState("ConfigurePhysics", {
		OnEnter = function(_, fsm)
			local projectile = fsm.Context._projectile
			local rootPart = fsm.Context._rootPart
			if not projectile or not rootPart or not rootPart.Parent then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Projectile configuration context missing")
				return
			end
			projectile.CFrame = rootPart.CFrame * CFrame.new(0, 0, -3)
			projectile.Anchored = false
			projectile.CanCollide = false
			projectile.CanQuery = false
			projectile.CanTouch = true
			projectile.AssemblyLinearVelocity = rootPart.CFrame.LookVector
				* (fsm.Context._speed or DEFAULT_PROJECTILE_SPEED)
			projectile.Parent = workspace
			Debris:AddItem(projectile, fsm.Context._lifetime or DEFAULT_PROJECTILE_LIFETIME)
			fsm.State = "RegisterHitDetection"
		end,
	}, {"RegisterHitDetection","ReleaseLock" })

	--[=[
	@state RegisterHitDetection
	@description Starts the projectile touch listener, ignores self-hits and dead targets, and caches impact data when a valid victim is found.
	Transitions:
	- `ProcessHit` when OnEnter finishes or falls through its guard checks.
	- `WaitForImpact` when OnEnter finishes or falls through its guard checks.
	Writes: stores `Context._impactResolved`, stores `Context._hitData`, stores `Context._hitConn`, sets `_impactResolved`, sets `_hitData`.

]=]

	self:AddState("RegisterHitDetection", {
		OnEnter = function(_, fsm)
			local projectile = fsm.Context._projectile
			if not projectile then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Projectile missing")
				return
			end

			local hitConn
			hitConn = projectile.Touched:Connect(function(hit)
				if not fsm.IsActive or fsm.State ~= "WaitForImpact" or fsm.Context._impactResolved then
					return
				end
				if hit:IsDescendantOf(fsm.Context._character) then
					return
				end

				local targetModel = hit and hit:FindFirstAncestorOfClass("Model")
				if not targetModel or targetModel == fsm.Context._character then
					return
				end

				local hitHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
				if not hitHumanoid or hitHumanoid.Health <= 0 then
					return
				end

				local orchestrator = fsm:GetOrchestrator()
				fsm.Context._impactResolved = true
				fsm.Context._hitData = {
					Hit = hit,
					TargetModel = targetModel,
					VictimEntity = getVictimEntity(orchestrator, targetModel),
				}
				fsm.State = "ProcessHit"
			end)
			fsm.Context._hitConn = hitConn
			fsm.State = "WaitForImpact"
		end,
	}, {"WaitForImpact","ReleaseLock","ProcessHit" })

	--[=[
	@state WaitForImpact
	@description Waits for either a projectile hit or the projectile lifetime timer to route into cleanup.
	Transitions:
	- `DestroyProjectile` when the scheduled transition completes.
	Writes: none.

]=]

	self:AddState("WaitForImpact", {
		OnEnter = function(_, fsm)
			fsm:ScheduleTransition(fsm.Context._lifetime or DEFAULT_PROJECTILE_LIFETIME,"DestroyProjectile")
		end,
	}, {"DestroyProjectile","ProcessHit" })

	--[=[
	@state ProcessHit
	@description Starts a `DamageJob` for the cached victim entity, then advances into projectile knockback.
	Transitions:
	- `ApplyProjectileKnockback` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("ProcessHit", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local hitData = fsm.Context._hitData
			local victimEntity = hitData and hitData.VictimEntity
			if victimEntity and typeof(victimEntity.UserId) == "number" then
				CombatHelpers.createDamageJob(
					orchestrator,
					fsm.CharacterEntityId,
					victimEntity,
					"Ranged_" .. tostring(fsm.Context._weaponId),
					fsm.Context._damage
				)
			end
			fsm.State = "ApplyProjectileKnockback"
		end,
	}, {"ApplyProjectileKnockback" })

	--[=[
	@state ApplyProjectileKnockback
	@description Pushes the victim root along the projectile flight direction before the projectile is destroyed.
	Transitions:
	- `DestroyProjectile` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("ApplyProjectileKnockback", {
		OnEnter = function(_, fsm)
			local hitData = fsm.Context._hitData
			local targetModel = hitData and hitData.TargetModel
			local victimRoot = targetModel and targetModel:FindFirstChild("HumanoidRootPart")
			local projectile = fsm.Context._projectile
			if victimRoot then
				local knockDir = Vector3.zero
				if projectile and projectile.AssemblyLinearVelocity.Magnitude > 0.01 then
					knockDir = projectile.AssemblyLinearVelocity.Unit
				else
					local rootPart = fsm.Context._rootPart
					if rootPart then
						knockDir = rootPart.CFrame.LookVector
					end
				end
				victimRoot.AssemblyLinearVelocity += knockDir * 30 + Vector3.new(0, 10, 0)
			end
			fsm.State = "DestroyProjectile"
		end,
	}, {"DestroyProjectile" })

	--[=[
	@state DestroyProjectile
	@description Disconnects hit detection and destroys the projectile before lock release.
	Transitions:
	- `ReleaseLock` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("DestroyProjectile", {
		OnEnter = function(_, fsm)
			cleanupProjectile(fsm)
			fsm.State = "ReleaseLock"
		end,
	}, {"ReleaseLock" })

	--[=[
	@state ReleaseLock
	@description Cleans up projectile state, releases the character lock, and routes to `Completed` or `Failed` based on queued release state.
	Transitions:
	- `Completed` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: stores `Context._lockHeld`, stores `Context._releaseTargetState`, sets `_lockHeld`, sets `_releaseTargetState`.

]=]

	self:AddState("ReleaseLock", {
		OnEnter = function(_, fsm)
			cleanupProjectile(fsm)
			local charEntity = fsm.Context._charEntity
			if charEntity and fsm.Context._lockHeld then
				charEntity:ReleaseLock(fsm.Id)
				fsm.Context._lockHeld = false
			end
			if fsm.Context._releaseTargetState == "Failed" then
				fsm:Fail(fsm.Context._releaseReason or "Projectile attack failed")
				return
			end
			fsm.State = "Completed"
		end,
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success sink reached after the projectile lifecycle finishes and any held attack lock has already been released. `OnEnter` is a no-op because all projectile cleanup happens before entry or in `OnCleanup`.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink for projectile spawn, travel, or hit-processing errors. `OnEnter` is a no-op; `OnCleanup` destroys the projectile instance and releases any remaining held lock.
	Transitions: none.
	Writes: none in-state; cleanup writes may still run.

]=]

	self:AddState("Failed", function() end, {})
end

--[=[
	@description Restores any mutable runtime state that still needs cleanup if the FSM stops before its normal completion path.
	@return nil -- Updates FSM state as a side effect.
]=]

function ProjectileAttackJob:OnCleanup()
	cleanupProjectile(self)
	local charEntity = self.Context._charEntity
	if charEntity and self.Context._lockHeld then
		charEntity:ReleaseLock(self.Id)
		self.Context._lockHeld = false
	end
end

return ProjectileAttackJob
