--!strict
-- @Name MeleeAttackJob
-- @Author Copilot
-- @Description Server-authoritative unarmed melee attack FSM.
--   Validates combat state, acquires lock, emits animation intents,
--   and processes damage — parallel to AttackJob for weapons.

local HttpService = game:GetService("HttpService")

local MeleeAttackJob = {
	Name = "MeleeAttackJob",
	className = "MeleeAttackJob",
	validStates = { "Validate", "AcquireLock", "Execute", "ReleaseLock", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local DEFAULT_MELEE_RADIUS = 5
local DEFAULT_MELEE_DAMAGE = {
	[1] = 5,   -- Punch
	[2] = 12,  -- Knee
	[3] = 15,  -- Uppercut
	[4] = 9,   -- Kick
}
local MELEE_DURATIONS = {
	[1] = 0.43,  -- Punch
	[2] = 0.72,  -- Knee (0.22 + 0.5)
	[3] = 0.72,  -- Uppercut (0.22 + 0.5)
	[4] = 0.75,  -- Kick (0.25 + 0.5)
}
local MELEE_ANIMATION_NAMES = {
	[1] = { "RightPunch", "LeftPunch" },
	[2] = { "LeftKnee1", "LeftKnee2" },
	[3] = { "Uppercut1", "Uppercut2" },
	[4] = { "RightKick1", "LeftKick" },
}

local function getSharedModule(name: string)
	local RS = game:GetService("ReplicatedStorage")
	local mod = RS:FindFirstChild(name, true)
	if mod and mod:IsA("ModuleScript") then
		return require(mod)
	end
	return nil
end

local function getOrchestrator()
	local lower = (shared :: any).fsm
	if lower ~= nil then return lower.Orchestrator or lower end
	error("Orchestrator not found")
end

local function scanMeleeRange(orchestrator: any, attackerCharEntityId: string, attackerRoot: BasePart, radius: number): { any }
	local victims = {}
	local entities = if type(orchestrator.GetEntities) == "function" then orchestrator.GetEntities() else {}
	for entityId, entity in pairs(entities) do
		if entityId == attackerCharEntityId then continue end
		local character = entity and entity.Instance
		if not character or not character:IsA("Model") then continue end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or humanoid.Health <= 0 or not root then continue end
		local offset = root.Position - attackerRoot.Position
		if offset.Magnitude <= 0 or offset.Magnitude >= radius then continue end
		if attackerRoot.CFrame.LookVector:Dot(offset.Unit) > 0 then
			table.insert(victims, entity)
		end
	end
	return victims
end

function MeleeAttackJob:RegisterStates()
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
			local root = character:FindFirstChild("HumanoidRootPart")
			if not humanoid or humanoid.Health <= 0 or not root then
				fsm:Fail("Character cannot attack")
				return
			end

			if charEntity.IsStunned == true or charEntity.IsKnocked == true then
				fsm:Fail("Character is crowd-controlled")
				return
			end

			-- Weapon must NOT be drawn for melee
			local equippedRight = charEntity.EquippedRight
			local equippedLeft = charEntity.EquippedLeft
			if (typeof(equippedRight) == "string" and equippedRight ~= "") or (typeof(equippedLeft) == "string" and equippedLeft ~= "") then
				fsm:Fail("Weapon is drawn — use AttackJob instead")
				return
			end

			local comboSlot = math.clamp(tonumber(fsm.ComboSlot) or 1, 1, 4)
			fsm.Context._charEntity = charEntity
			fsm.Context._character = character
			fsm.Context._humanoid = humanoid
			fsm.Context._root = root
			fsm.Context._comboSlot = comboSlot
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
			fsm.State = "Execute"
		end,
	}, { "Execute", "Failed" })

	self:AddState("Execute", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local comboSlot = fsm.Context._comboSlot
			local root = fsm.Context._root
			local duration = MELEE_DURATIONS[comboSlot] or 0.5
			local damage = DEFAULT_MELEE_DAMAGE[comboSlot] or 5
			local animNames = MELEE_ANIMATION_NAMES[comboSlot]

			-- Emit ONE animation intent (cycle through combo pointer)
			local IntentSchema = getSharedModule("IntentSchema")
			if IntentSchema and animNames and #animNames > 0 then
				-- Track combo pointer per slot on the entity
				local pointers = charEntity._MeleePointers
				if typeof(pointers) ~= "table" then
					pointers = {}
				end
				local pointer = (pointers[comboSlot] or 0) + 1
				if pointer > #animNames then pointer = 1 end
				pointers[comboSlot] = pointer
				charEntity:SetContext("_MeleePointers", pointers)

				local animName = animNames[pointer]
				IntentSchema.AppendIntent(charEntity, {
					Kind = "Animation",
					Payload = { Name = animName, Speed = 0.25, FadeTime = 0.1 },
					SourceCharId = fsm.CharacterEntityId,
				}, fsm.Id)
			end

			-- Scan for victims and deal damage at mid-point
			task.delay(duration * 0.5, function()
				if not fsm.IsActive then return end
				local orchestrator = getOrchestrator()
				local victims = scanMeleeRange(orchestrator, fsm.CharacterEntityId, root, DEFAULT_MELEE_RADIUS)
				for _, victim in ipairs(victims) do
					local victimHumanoid = victim.Instance and victim.Instance:FindFirstChildOfClass("Humanoid")
					if victimHumanoid and victimHumanoid.Health > 0 then
						victimHumanoid:TakeDamage(damage)
					end
				end
			end)

			-- Schedule transition to ReleaseLock after attack duration
			fsm:ScheduleTransition(duration, "ReleaseLock")
		end,
	}, { "ReleaseLock", "Failed" })

	self:AddState("ReleaseLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			if charEntity and fsm.Context._lockHeld then
				charEntity:ReleaseLock(fsm.Id)
				fsm.Context._lockHeld = false
			end
			fsm.State = "Completed"
		end,
	}, { "Completed" })
end

return MeleeAttackJob
