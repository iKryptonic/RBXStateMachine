--!strict
-- @Name DamageJob
-- @Author iKrypto

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageJob = {
	Name = "DamageJob",
	className = "DamageJob",
	validStates = { "Validate", "CheckHitNonce", "ResolveVictim", "ComputeDamage", "ApplyDamage", "EmitHitReact", "EmitDamageText", "FireEventBus", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local ProcessedNonces: { [number]: { [string]: number } } = {}
local NONCE_EXPIRY = 3
local MAX_NONCES_PER_ATTACKER = 64

local function getSharedModule(name: string)
	local sharedFolder = game:GetService("ReplicatedStorage"):FindFirstChild("shared")
	if sharedFolder then
		local mod = sharedFolder:FindFirstChild(name)
		if mod then
			return require(mod)
		end
	end

	local replicatedMod = ReplicatedStorage:FindFirstChild(name, true)
	if replicatedMod then
		return require(replicatedMod)
	end

	error("Shared module not found: " .. name)
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

local function resolveVictimEntity(orchestrator: any, victimUserId: number): any?
	if type(orchestrator.GetEntities) ~= "function" then
		return nil
	end

	for _, entity in pairs(orchestrator.GetEntities()) do
		local instance = entity and entity.Instance
		if entity and entity.UserId == victimUserId and instance and instance:IsA("Model") then
			local humanoid = instance:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return entity
			end
		end
	end

	return nil
end

local function resolveWeaponBaseDamage(orchestrator: any, attackerEntity: any): number
	local DamageCalculator = getSharedModule("DamageCalculator")
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

	local dataModule = item:FindFirstChild("Data")
	if not dataModule or not dataModule:IsA("ModuleScript") then
		return baseDamage
	end

	local ok, itemData = pcall(require, dataModule)
	if ok then
		baseDamage = DamageCalculator.GetWeaponBaseDamage(itemData)
	end

	return baseDamage
end

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

function DamageJob:RegisterStates()
	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local orchestrator = shared.fsm
			if not orchestrator then
				fsm:Fail("Orchestrator unavailable")
				return
			end

			local attackerEntityId = fsm.AttackerCharEntityId
			if typeof(attackerEntityId) ~= "string" or attackerEntityId == "" then
				fsm:Fail("AttackerCharEntityId is required")
				return
			end

			local attackerEntity = orchestrator.GetEntity(attackerEntityId)
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

			local attackName = if typeof(fsm.AttackName) == "string" and fsm.AttackName ~= "" then fsm.AttackName else "BasicAttack"
			fsm.Context.AttackName = attackName
			fsm.Context._attackerEntity = attackerEntity
			fsm.Context._attackerUserId = attackerUserId
			fsm.Context._nonce = string.format("%d:%s:%.6f", attackerUserId, attackName, os.clock())
			fsm.State = "CheckHitNonce"
		end,
	}, { "CheckHitNonce", "Failed" })

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

	self:AddState("ResolveVictim", {
		OnEnter = function(_, fsm)
			local orchestrator = shared.fsm
			if not orchestrator then
				fsm:Fail("Orchestrator unavailable")
				return
			end

			local victimEntity = resolveVictimEntity(orchestrator, fsm.VictimUserId)
			if not victimEntity then
				fsm:Fail("Victim character entity not found")
				return
			end

			local character = victimEntity.Instance
			if not character or not character:IsA("Model") then
				fsm:Fail("Victim character model missing")
				return
			end

			local humanoid, root = getHumanoidAndRoot(character)
			if not humanoid or humanoid.Health <= 0 then
				fsm:Fail("Victim humanoid unavailable or dead")
				return
			end

			fsm.Context._victimEntity = victimEntity
			fsm.Context._victimCharacter = character
			fsm.Context._victimHumanoid = humanoid
			fsm.Context._victimRoot = root
			fsm.Context._isVictimBlocking = victimEntity.IsBlocking == true
			fsm.State = "ComputeDamage"
		end,
	}, { "ComputeDamage", "Failed" })

	self:AddState("ComputeDamage", {
		OnEnter = function(_, fsm)
			local DamageCalculator = getSharedModule("DamageCalculator")
			local orchestrator = shared.fsm
			local attackerEntity = fsm.Context._attackerEntity
			if not orchestrator or not attackerEntity then
				fsm:Fail("Attacker context missing")
				return
			end

			local baseDamage = resolveWeaponBaseDamage(orchestrator, attackerEntity)
			local computedDamage = DamageCalculator.Compute(baseDamage, fsm.Context._isVictimBlocking == true)
			fsm.Context._computedDamage = computedDamage
			fsm.State = "ApplyDamage"
		end,
	}, { "ApplyDamage", "Failed" })

	self:AddState("ApplyDamage", {
		OnEnter = function(_, fsm)
			local victimHumanoid = fsm.Context._victimHumanoid
			local computedDamage = fsm.Context._computedDamage
			if not victimHumanoid or typeof(computedDamage) ~= "number" then
				fsm:Fail("Damage application context missing")
				return
			end

			if victimHumanoid.Health > 0 then
				victimHumanoid:TakeDamage(computedDamage)
			end
			fsm.State = "EmitHitReact"
		end,
	}, { "EmitHitReact", "Failed" })

	self:AddState("EmitHitReact", {
		OnEnter = function(_, fsm)
			local IntentSchema = getSharedModule("IntentSchema")
			local victimEntity = fsm.Context._victimEntity
			local computedDamage = fsm.Context._computedDamage
			if not victimEntity or typeof(computedDamage) ~= "number" then
				fsm:Fail("Hit react context missing")
				return
			end

			local victimCharId = if typeof(victimEntity.EntityId) == "string" then victimEntity.EntityId else tostring(fsm.VictimUserId)
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

	self:AddState("FireEventBus", {
		OnEnter = function(_, fsm)
			local orchestrator = shared.fsm
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
			local victimCharId = if typeof(victimEntity.EntityId) == "string" then victimEntity.EntityId else tostring(fsm.VictimUserId)
			orchestrator.FireEventBus("Damage/Applied", {
				AttackerCharId = fsm.AttackerCharEntityId,
				VictimCharId = victimCharId,
				VictimUserId = victimEntity.UserId,
				Damage = computedDamage,
				AttackName = fsm.Context.AttackName,
				Nonce = fsm.Context._nonce,
			})
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })

	self:AddState("Completed", function() end, {})
	self:AddState("Failed", function() end, {})
end

function DamageJob:OnCleanup()
end

return DamageJob
