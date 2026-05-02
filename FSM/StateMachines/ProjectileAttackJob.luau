--!strict
-- @Name ProjectileAttackJob
-- @Author Copilot
-- @Description Server-authoritative ranged attack FSM for bows, staves, and spell casters.
--   States: Validate → AcquireLock → Charge → Fire → WaitForImpact → ReleaseLock → Completed
--   Spawns a projectile, raycasts or tracks collision, creates DamageJob on hit.

local Debris = game:GetService("Debris")

local ProjectileAttackJob = {
	Name = "ProjectileAttackJob",
	className = "ProjectileAttackJob",
	validStates = { "Validate", "AcquireLock", "Charge", "Fire", "WaitForImpact", "ReleaseLock", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local DEFAULT_PROJECTILE_SPEED = 150
local DEFAULT_PROJECTILE_LIFETIME = 3
local DEFAULT_PROJECTILE_DAMAGE = 20
local DEFAULT_CHARGE_TIME = 0.3
local DEFAULT_GRAVITY = Vector3.new(0, -30, 0)

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
	-- Look for Arrow, UnleashArrow, or [WeaponName]Projectile
	local names = { "Arrow", weaponId .. "Projectile", "UnleashArrow", "ZephyrProjectile" }
	for _, name in ipairs(names) do
		local template = assets:FindFirstChild(name)
		if template and template:IsA("BasePart") then
			return template
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

			-- Resolve weapon
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

			-- Check mana
			local manaCost = (itemData.ManaCost) or 10
			if (charEntity.Mana or 0) < manaCost then
				fsm:Fail("Not enough mana")
				return
			end
			-- Deduct mana
			charEntity.Mana = (charEntity.Mana or 50) - manaCost
			charEntity:UpdateEntity()
			fsm.Context._manaCost = manaCost

			fsm.Context._charEntity = charEntity
			fsm.Context._character = character
			fsm.Context._humanoid = humanoid
			fsm.Context._rootPart = rootPart
			fsm.Context._weaponId = weaponId
			fsm.Context._itemData = itemData
			fsm.Context._damage = (itemData.WeaponStats and itemData.WeaponStats.Attack) or DEFAULT_PROJECTILE_DAMAGE
			fsm.Context._speed = (itemData.ProjectileSpeed) or DEFAULT_PROJECTILE_SPEED
			fsm.Context._lifetime = (itemData.ProjectileLifetime) or DEFAULT_PROJECTILE_LIFETIME
			fsm.Context._chargeTime = (itemData.ChargeTime) or DEFAULT_CHARGE_TIME
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
			fsm.State = "Charge"
		end,
	}, { "Charge", "Failed" })

	self:AddState("Charge", {
		OnEnter = function(_, fsm)
			local IntentSchema = getSharedModule("IntentSchema")
			if IntentSchema then
				IntentSchema.AppendIntent(fsm.Context._charEntity, {
					Kind = "Animation",
					Payload = { Name = "Charge1", Speed = 0.25, FadeTime = 0.1 },
					SourceCharId = fsm.CharacterEntityId,
				}, fsm.Id)
			end
			fsm:ScheduleTransition(fsm.Context._chargeTime or DEFAULT_CHARGE_TIME, "Fire")
		end,
	}, { "Fire", "Failed" })

	self:AddState("Fire", {
		OnEnter = function(_, fsm)
			local rootPart = fsm.Context._rootPart
			local charEntity = fsm.Context._charEntity
			if not rootPart or not rootPart.Parent then
				fsm.State = "ReleaseLock"
				return
			end

			-- Emit fire animation
			local IntentSchema = getSharedModule("IntentSchema")
			if IntentSchema then
				IntentSchema.AppendIntent(charEntity, {
					Kind = "Animation",
					Payload = { Name = "Charge2", Speed = 0.5, FadeTime = 0.1 },
					SourceCharId = fsm.CharacterEntityId,
				}, fsm.Id)
			end

			-- Spawn projectile
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
			projectile.CFrame = rootPart.CFrame * CFrame.new(0, 0, -3)
			projectile.Anchored = false
			projectile.CanCollide = false
			projectile.AssemblyLinearVelocity = rootPart.CFrame.LookVector * fsm.Context._speed
			projectile.Parent = workspace

			Debris:AddItem(projectile, fsm.Context._lifetime)

			-- Track projectile for hit detection
			fsm.Context._projectile = projectile
			fsm.Context._fireTime = os.clock()

			-- Touched connection for hit detection
			local hitConn
			hitConn = projectile.Touched:Connect(function(hit)
				if not fsm.IsActive or fsm.State ~= "WaitForImpact" then return end
				local hitChar = hit.Parent
				if not hitChar or hitChar == fsm.Context._character then return end
				local hitHumanoid = hitChar:FindFirstChildOfClass("Humanoid")
				if not hitHumanoid or hitHumanoid.Health <= 0 then return end

				-- Find victim entity
				local orchestrator = getOrchestrator()
				local entities = orchestrator.GetEntities and orchestrator.GetEntities() or {}
				local victimEntity = nil
				for _, entity in pairs(entities) do
					if entity.Instance == hitChar then
						victimEntity = entity
						break
					end
				end

				if victimEntity and typeof(victimEntity.UserId) == "number" then
					-- Create DamageJob
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

					-- Knockback from projectile direction
					local victimRoot = hitChar:FindFirstChild("HumanoidRootPart")
					if victimRoot then
						local knockDir = projectile.AssemblyLinearVelocity.Unit
						victimRoot.AssemblyLinearVelocity += knockDir * 30 + Vector3.new(0, 10, 0)
					end
				end

				-- Destroy projectile on hit
				hitConn:Disconnect()
				projectile:Destroy()
				fsm.Context._projectile = nil
				fsm.State = "ReleaseLock"
			end)

			fsm.Context._hitConn = hitConn
			fsm.State = "WaitForImpact"
		end,
	}, { "WaitForImpact", "ReleaseLock", "Failed" })

	self:AddState("WaitForImpact", {
		OnEnter = function(_, fsm)
			fsm:ScheduleTransition(fsm.Context._lifetime or DEFAULT_PROJECTILE_LIFETIME, "ReleaseLock")
		end,
	}, { "ReleaseLock" })

	self:AddState("ReleaseLock", {
		OnEnter = function(_, fsm)
			-- Cleanup
			local hitConn = fsm.Context._hitConn
			if hitConn then
				pcall(function() hitConn:Disconnect() end)
				fsm.Context._hitConn = nil
			end

			local charEntity = fsm.Context._charEntity
			if charEntity and fsm.Context._lockHeld then
				charEntity:ReleaseLock(fsm.Id)
				fsm.Context._lockHeld = false
			end
			fsm.State = "Completed"
		end,
	}, { "Completed" })
end

return ProjectileAttackJob
