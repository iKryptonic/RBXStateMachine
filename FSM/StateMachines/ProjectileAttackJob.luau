--!strict
-- @Name ProjectileAttackJob
-- @Author iKrypto
-- @Description Server-authoritative ranged attack FSM for bows, staves, and spell casters.
--   Spawns a projectile, tracks collision, and creates DamageJob on hit.

local Debris = game:GetService("Debris")

local ProjectileAttackJob = {
	Name = "ProjectileAttackJob",
	className = "ProjectileAttackJob",
	validStates = { "Validate", "AcquireLock", "ValidateMana", "DeductMana", "EmitChargeAnimation", "WaitCharge", "ValidateForFire", "EmitFireAnimation", "SpawnProjectile", "ConfigurePhysics", "RegisterHitDetection", "WaitForImpact", "ProcessHit", "ApplyProjectileKnockback", "DestroyProjectile", "ReleaseLock", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local DEFAULT_PROJECTILE_SPEED = 150
local DEFAULT_PROJECTILE_LIFETIME = 3
local DEFAULT_PROJECTILE_DAMAGE = 20
local DEFAULT_CHARGE_TIME = 0.3
local DEFAULT_GRAVITY = Vector3.new(0, -30, 0)

-- TODO: Prefer fsm:GetOrchestrator() / fsm:GetEntity() now that Orchestrator injects itself into Context.
local function getOrchestrator()
	local lower = (shared :: any).fsm
	if lower ~= nil then return lower.Orchestrator or lower end
	error("Orchestrator not found")
end

local function getSharedModule(name: string)
	local RS = game:GetService("ReplicatedStorage")
	local mod = RS:FindFirstChild(name, true)
	if mod and mod:IsA("ModuleScript") then return require(mod) end
	return nil
end

local function getItemData(weaponId: string): any?
	local RS = game:GetService("ReplicatedStorage")
	local assets = RS:FindFirstChild("Assets")
	if not assets then return nil end
	local item = assets:FindFirstChild(weaponId, true)
	if not item then return nil end
	local dataModule = item:FindFirstChild("Data")
	if not dataModule or not dataModule:IsA("ModuleScript") then return nil end
	local ok, data = pcall(require, dataModule)
	return if ok then data else nil
end

local function getProjectileTemplate(weaponId: string): BasePart?
	local RS = game:GetService("ReplicatedStorage")
	local assets = RS:FindFirstChild("Assets")
	if not assets then return nil end
	local names = { "Arrow", weaponId .. "Projectile", "UnleashArrow", "ZephyrProjectile" }
	for _, name in ipairs(names) do
		local template = assets:FindFirstChild(name)
		if template and template:IsA("BasePart") then
			return template
		end
	end
	return nil
end

local function queueRelease(fsm: any, nextState: string, reason: string?)
	fsm.Context._releaseTargetState = nextState
	fsm.Context._releaseReason = reason
	fsm.State = "ReleaseLock"
end

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

local function getVictimEntity(orchestrator: any, targetModel: Model): any?
	local entities = orchestrator.GetEntities and orchestrator.GetEntities() or {}
	for _, entity in pairs(entities) do
		if entity.Instance == targetModel then
			return entity
		end
	end
	return nil
end

function ProjectileAttackJob:RegisterStates()
	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
			local charEntityId = fsm.CharacterEntityId
			if typeof(charEntityId) ~= "string" or charEntityId == "" then
				fsm:Fail("CharacterEntityId required")
				return
			end

			local charEntity = orchestrator.GetEntity(charEntityId)
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

			if charEntity.IsStunned == true or charEntity.IsKnocked == true then
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
	}, { "AcquireLock", "Failed" })

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
	}, { "ValidateMana", "Failed" })

	self:AddState("ValidateMana", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local manaCost = fsm.Context._manaCost or 0
			if (charEntity.Mana or 0) < manaCost then
				queueRelease(fsm, "Failed", "Not enough mana")
				return
			end
			fsm.State = "DeductMana"
		end,
	}, { "DeductMana", "ReleaseLock" })

	self:AddState("DeductMana", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local manaCost = fsm.Context._manaCost or 0
			charEntity.Mana = (charEntity.Mana or 50) - manaCost
			charEntity:UpdateEntity(fsm.Id)
			fsm.State = "EmitChargeAnimation"
		end,
	}, { "EmitChargeAnimation" })

	self:AddState("EmitChargeAnimation", {
		OnEnter = function(_, fsm)
			local IntentSchema = getSharedModule("IntentSchema")
			if IntentSchema then
				IntentSchema.AppendIntent(fsm.Context._charEntity, {
					Kind = "Animation",
					Payload = { Name = "Charge1", Speed = 0.25, FadeTime = 0.1 },
					SourceCharId = fsm.CharacterEntityId,
				}, fsm.Id)
			end
			fsm.State = "WaitCharge"
		end,
	}, { "WaitCharge" })

	self:AddState("WaitCharge", {
		OnEnter = function(_, fsm)
			local chargeTime = fsm.Context._chargeTime or DEFAULT_CHARGE_TIME
			if chargeTime > 0 then
				fsm:ScheduleTransition(chargeTime, "ValidateForFire")
			else
				fsm.State = "ValidateForFire"
			end
		end,
	}, { "ValidateForFire", "Failed" })

	self:AddState("ValidateForFire", {
		OnEnter = function(_, fsm)
			local rootPart = fsm.Context._rootPart
			if not rootPart or not rootPart.Parent then
				queueRelease(fsm, "Failed", "Character root lost before firing")
				return
			end
			fsm.State = "EmitFireAnimation"
		end,
	}, { "EmitFireAnimation", "ReleaseLock" })

	self:AddState("EmitFireAnimation", {
		OnEnter = function(_, fsm)
			local IntentSchema = getSharedModule("IntentSchema")
			if IntentSchema then
				IntentSchema.AppendIntent(fsm.Context._charEntity, {
					Kind = "Animation",
					Payload = { Name = "Charge2", Speed = 0.5, FadeTime = 0.1 },
					SourceCharId = fsm.CharacterEntityId,
				}, fsm.Id)
			end
			fsm.State = "SpawnProjectile"
		end,
	}, { "SpawnProjectile" })

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
	}, { "ConfigurePhysics" })

	self:AddState("ConfigurePhysics", {
		OnEnter = function(_, fsm)
			local projectile = fsm.Context._projectile
			local rootPart = fsm.Context._rootPart
			if not projectile or not rootPart or not rootPart.Parent then
				queueRelease(fsm, "Failed", "Projectile configuration context missing")
				return
			end
			projectile.CFrame = rootPart.CFrame * CFrame.new(0, 0, -3)
			projectile.Anchored = false
			projectile.CanCollide = false
			projectile.CanQuery = false
			projectile.CanTouch = true
			projectile.AssemblyLinearVelocity = rootPart.CFrame.LookVector * (fsm.Context._speed or DEFAULT_PROJECTILE_SPEED)
			projectile.Parent = workspace
			Debris:AddItem(projectile, fsm.Context._lifetime or DEFAULT_PROJECTILE_LIFETIME)
			fsm.State = "RegisterHitDetection"
		end,
	}, { "RegisterHitDetection", "ReleaseLock" })

	self:AddState("RegisterHitDetection", {
		OnEnter = function(_, fsm)
			local projectile = fsm.Context._projectile
			if not projectile then
				queueRelease(fsm, "Failed", "Projectile missing")
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

				local orchestrator = getOrchestrator()
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
	}, { "WaitForImpact", "ReleaseLock", "ProcessHit" })

	self:AddState("WaitForImpact", {
		OnEnter = function(_, fsm)
			fsm:ScheduleTransition(fsm.Context._lifetime or DEFAULT_PROJECTILE_LIFETIME, "DestroyProjectile")
		end,
	}, { "DestroyProjectile", "ProcessHit" })

	self:AddState("ProcessHit", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
			local hitData = fsm.Context._hitData
			local victimEntity = hitData and hitData.VictimEntity
			if victimEntity and typeof(victimEntity.UserId) == "number" then
				local damageJob = orchestrator.CreateStateMachine({
					StateMachineClass = "DamageJob",
					StateMachineId = string.format("ProjDmg_%s_%s", fsm.Id, tostring(victimEntity.UserId)),
					Context = {
						AttackerCharEntityId = fsm.CharacterEntityId,
						VictimUserId = victimEntity.UserId,
						AttackName = "Ranged_" .. tostring(fsm.Context._weaponId),
						BaseDamage = fsm.Context._damage,
					},
				})
				if damageJob then
					damageJob:Start({ State = "Validate" })
				end
			end
			fsm.State = "ApplyProjectileKnockback"
		end,
	}, { "ApplyProjectileKnockback" })

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
	}, { "DestroyProjectile" })

	self:AddState("DestroyProjectile", {
		OnEnter = function(_, fsm)
			cleanupProjectile(fsm)
			fsm.State = "ReleaseLock"
		end,
	}, { "ReleaseLock" })

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
	}, { "Completed", "Failed" })

	self:AddState("Completed", function() end, {})
	self:AddState("Failed", function() end, {})
end

function ProjectileAttackJob:OnCleanup()
	cleanupProjectile(self)
	local charEntity = self.Context._charEntity
	if charEntity and self.Context._lockHeld then
		charEntity:ReleaseLock(self.Id)
		self.Context._lockHeld = false
	end
end

return ProjectileAttackJob
