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
	validStates = { "Validate", "AcquireLock", "Execute", "DamageScan", "ReleaseLock", "Completed", "Failed" },
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
-- Each slot defines the full sequence of animations with their durations
local MELEE_SEQUENCES = {
	[1] = { -- Punch: alternating single moves
		Type = "Alternate",
		Moves = {
			{{ Name = "RightPunch", Speed = 0.5, Duration = 0.43 }},
			{{ Name = "LeftPunch", Speed = 0.5, Duration = 0.43 }},
		},
	},
	[2] = { -- Knee: 2-phase sequence
		Type = "Sequence",
		Moves = {
			{{ Name = "LeftKnee1", Speed = 0.25, Duration = 0.22 }, { Name = "LeftKnee2", Speed = 0.5, Duration = 0.5 }},
		},
	},
	[3] = { -- Uppercut: 2-phase sequence
		Type = "Sequence",
		Moves = {
			{{ Name = "Uppercut1", Speed = 0.25, Duration = 0.22 }, { Name = "Uppercut2", Speed = 0.5, Duration = 0.5 }},
		},
	},
	[4] = { -- Kick: alternating combos
		Type = "Alternate",
		Moves = {
			{{ Name = "RightKick1", Speed = 0.25, Duration = 0.25 }, { Name = "RightKick2", Speed = 0.5, Duration = 0.5 }},
			{{ Name = "LeftKick", Speed = 0.25, Duration = 0.22 }},
		},
	},
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

local function appendAnimationIntent(charEntity: any, fsm: any, phase: any)
	local IntentSchema = getSharedModule("IntentSchema")
	if not IntentSchema then
		return
	end

	IntentSchema.AppendIntent(charEntity, {
		Kind = "Animation",
		Payload = { Name = phase.Name, Speed = phase.Speed, FadeTime = 0.1 },
		SourceCharId = fsm.CharacterEntityId,
	}, fsm.Id)
end

local function emitDueAnimationPhases(fsm: any, elapsed: number)
	local phases = fsm.Context._phases
	local phaseStartTimes = fsm.Context._phaseStartTimes
	local charEntity = fsm.Context._charEntity
	local nextPhaseIndex = fsm.Context._nextPhaseIndex or 1
	if typeof(phases) ~= "table" or typeof(phaseStartTimes) ~= "table" or not charEntity then
		return
	end

	while nextPhaseIndex <= #phases do
		local phaseStart = phaseStartTimes[nextPhaseIndex]
		if typeof(phaseStart) ~= "number" or elapsed + 0.0001 < phaseStart then
			break
		end

		local phase = phases[nextPhaseIndex]
		if typeof(phase) == "table" then
			appendAnimationIntent(charEntity, fsm, phase)
		end
		nextPhaseIndex += 1
	end

	fsm.Context._nextPhaseIndex = nextPhaseIndex
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

			local comboSlot = math.clamp(tonumber(fsm.ComboSlot) or 1, 1, 4)

			-- Weapon must NOT be drawn for melee
			local equippedRight = charEntity.EquippedRight
			local equippedLeft = charEntity.EquippedLeft
			if (typeof(equippedRight) == "string" and equippedRight ~= "") or (typeof(equippedLeft) == "string" and equippedLeft ~= "") then
				fsm:Fail("Weapon is drawn — use AttackJob instead")
				return
			end

			fsm.Context._charEntity = charEntity
			fsm.Context._staminaCost = DEFAULT_MELEE_DAMAGE[comboSlot] or 5
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
			local damage = DEFAULT_MELEE_DAMAGE[comboSlot] or 5
			local staminaCost = fsm.Context._staminaCost or damage
			if (charEntity.Stamina or 0) < staminaCost then
				fsm.State = "ReleaseLock"
				return
			end
			charEntity.Stamina = (charEntity.Stamina or 100) - staminaCost
			charEntity:UpdateEntity()

			local seqDef = MELEE_SEQUENCES[comboSlot]
			if not seqDef then
				fsm.State = "ReleaseLock"
				return
			end

			-- Resolve which move to play (alternate or fixed sequence)
			local pointers = charEntity._MeleePointers
			if typeof(pointers) ~= "table" then pointers = {} end
			local pointer = (pointers[comboSlot] or 0) + 1
			if pointer > #seqDef.Moves then pointer = 1 end
			pointers[comboSlot] = pointer
			charEntity:SetContext("_MeleePointers", pointers)

			local phases = seqDef.Moves[pointer]
			if typeof(phases) ~= "table" or #phases == 0 then
				fsm.State = "ReleaseLock"
				return
			end

			local phaseStartTimes = {}
			local totalDuration = 0
			for index, phase in ipairs(phases) do
				phaseStartTimes[index] = totalDuration
				totalDuration += phase.Duration
			end

			fsm.Context._damage = damage
			fsm.Context._phases = phases
			fsm.Context._phaseStartTimes = phaseStartTimes
			fsm.Context._nextPhaseIndex = 1
			fsm.Context._attackDuration = totalDuration
			fsm.Context._damageScanOffset = totalDuration * 0.5

			emitDueAnimationPhases(fsm, 0)
			if totalDuration <= 0 then
				fsm.State = "DamageScan"
				return
			end

			fsm:ScheduleTransition(fsm.Context._damageScanOffset, "DamageScan")
		end,
		OnHeartbeat = function(_, fsm)
			emitDueAnimationPhases(fsm, fsm.StateDuration)
		end,
	}, { "DamageScan", "ReleaseLock", "Failed" })

	self:AddState("DamageScan", {
		OnEnter = function(_, fsm)
			local comboSlot = fsm.Context._comboSlot
			local damage = fsm.Context._damage or (DEFAULT_MELEE_DAMAGE[comboSlot] or 5)
			local damageScanOffset = fsm.Context._damageScanOffset or 0
			local totalDuration = fsm.Context._attackDuration or 0
			emitDueAnimationPhases(fsm, damageScanOffset)

			local orchestrator = getOrchestrator()
			local attackerRoot = fsm.Context._root
			if attackerRoot and attackerRoot.Parent then
				local knockbackDir = attackerRoot.CFrame.LookVector
				local victims = scanMeleeRange(orchestrator, fsm.CharacterEntityId, attackerRoot, DEFAULT_MELEE_RADIUS)
				for _, victim in ipairs(victims) do
					local victimHumanoid = victim.Instance and victim.Instance:FindFirstChildOfClass("Humanoid")
					local victimRoot = victim.Instance and victim.Instance:FindFirstChild("HumanoidRootPart")
					local victimUserId = victim.UserId
					if victimHumanoid and victimHumanoid.Health > 0 and typeof(victimUserId) == "number" then
						local damageJob = orchestrator.CreateStateMachine({
							StateMachineClass = "DamageJob",
							StateMachineId = string.format("MeleeDmg_%s_%s", fsm.Id, tostring(victimUserId)),
							Context = {
								AttackerCharEntityId = fsm.CharacterEntityId,
								VictimUserId = victimUserId,
								AttackName = "Melee_" .. tostring(comboSlot),
								BaseDamage = damage,
							},
						})
						if damageJob then
							damageJob:Start({ State = "Validate" })
						end
						if victimRoot then
							local knockForce = knockbackDir * 25 + Vector3.new(0, 10, 0)
							victimRoot.AssemblyLinearVelocity = victimRoot.AssemblyLinearVelocity + knockForce
						end
					end
				end
			end

			local remainingDuration = math.max(totalDuration - damageScanOffset, 0)
			if remainingDuration > 0 then
				fsm:ScheduleTransition(remainingDuration, "ReleaseLock")
			else
				fsm.State = "ReleaseLock"
			end
		end,
		OnHeartbeat = function(_, fsm)
			local damageScanOffset = fsm.Context._damageScanOffset or 0
			emitDueAnimationPhases(fsm, damageScanOffset + fsm.StateDuration)
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
