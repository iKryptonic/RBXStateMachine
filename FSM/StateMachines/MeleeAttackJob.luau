--!strict


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local EntityHelpers = require(Helpers:WaitForChild("EntityHelpers"))
local CombatHelpers = require(Helpers:WaitForChild("CombatHelpers"))
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))
local ResourceHelpers = require(Helpers:WaitForChild("ResourceHelpers"))
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

--[=[
	@module MeleeAttackJob
	@description Executes unarmed combo attacks by spending stamina, playing attack phases, scanning victims, and spawning per-target damage jobs.
]=]

local MeleeAttackJob = {
	Name = "MeleeAttackJob",
	className = "MeleeAttackJob",
	validStates = {
		"Validate",
		"AcquireLock",
		"ValidateStamina",
		"DeductStamina",
		"ResolveSequence",
		"EmitPhaseAnimation",
		"ScheduleDamageWindow",
		"WaitForDamageWindow",
		"ScanVictims",
		"ProcessVictim",
		"ApplyKnockback",
		"WaitForRecovery",
		"ReleaseLock",
		"Completed",
		"Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Validate",
}

local DEFAULT_MELEE_RADIUS = 5
local DEFAULT_MELEE_DAMAGE = {
	[1] = 5,
	[2] = 12,
	[3] = 15,
	[4] = 9,
}

local MELEE_SEQUENCES = {
	[1] = {
		Type = "Alternate",
		Moves = {
			{ { Name = "RightPunch", Speed = 0.5, Duration = 0.43 } },
			{ { Name = "LeftPunch", Speed = 0.5, Duration = 0.43 } },
		},
	},
	[2] = {
		Type = "Sequence",
		Moves = {
			{
				{ Name = "LeftKnee1", Speed = 0.25, Duration = 0.22 },
				{ Name = "LeftKnee2", Speed = 0.5, Duration = 0.5 },
			},
		},
	},
	[3] = {
		Type = "Sequence",
		Moves = {
			{
				{ Name = "Uppercut1", Speed = 0.25, Duration = 0.22 },
				{ Name = "Uppercut2", Speed = 0.5, Duration = 0.5 },
			},
		},
	},
	[4] = {
		Type = "Alternate",
		Moves = {
			{
				{ Name = "RightKick1", Speed = 0.25, Duration = 0.25 },
				{ Name = "RightKick2", Speed = 0.5, Duration = 0.5 },
			},
			{ { Name = "LeftKick", Speed = 0.25, Duration = 0.22 } },
		},
	},
}

--[=[
	@description Helper for the append animation intent step used by this state machine.
	@param orchestrator any -- Input consumed by `appendAnimationIntent`.
	@param charEntity any -- Input consumed by `appendAnimationIntent`.
	@param fsm any -- Input consumed by `appendAnimationIntent`.
	@param phase any -- Input consumed by `appendAnimationIntent`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function appendAnimationIntent(orchestrator: any, charEntity: any, fsm: any, phase: any)
	IntentHelpers.appendIntent(orchestrator, charEntity,"Animation", { Name = phase.Name, Speed = phase.Speed, FadeTime = 0.1 }, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
end

--[=[
	@description Helper for the emit due animation phases step used by this state machine.
	@param fsm any -- Input consumed by `emitDueAnimationPhases`.
	@param elapsed any -- Input consumed by `emitDueAnimationPhases`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

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
			appendAnimationIntent(fsm:GetOrchestrator(), charEntity, fsm, phase)
		end
		nextPhaseIndex += 1
	end

	fsm.Context._nextPhaseIndex = nextPhaseIndex
end


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `MeleeAttackJob`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function MeleeAttackJob:RegisterStates()


	--[=[
		@state Validate
		@description Validates the required runtime context and prerequisites, then captures the lock or blocking state needed for the next step.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
			- `AcquireLock` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context._charEntity`, stores `Context._staminaCost`, stores `Context._character`, stores `Context._humanoid`, stores `Context._root`.
	]=]

	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				fsm:Fail("Orchestrator not found")
				return
			end
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

			local humanoid, root = EntityHelpers.getHumanoidAndRoot(character)
			if not humanoid or humanoid.Health <= 0 or not root then
				fsm:Fail("Character cannot attack")
				return
			end

			if EntityHelpers.isCrowdControlled(charEntity) then
				fsm:Fail("Character is crowd-controlled")
				return
			end

			local comboSlot = math.clamp(tonumber(fsm.ComboSlot) or 1, 1, 4)
			local equippedRight = charEntity.EquippedRight
			local equippedLeft = charEntity.EquippedLeft
			if
				(typeof(equippedRight) == "string" and equippedRight ~= "")
				or (typeof(equippedLeft) == "string" and equippedLeft ~= "")
			then
				-- Weapon drawn: silently complete — client may be slightly out of sync
				fsm.State = "Completed"
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
	}, {"AcquireLock","Completed","Failed" })


	--[=[
		@state AcquireLock
		@description Captures the lock or blocking state needed for the next step.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
			- `ValidateStamina` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._lockHeld`, sets `_lockHeld`.
	]=]

	self:AddState("AcquireLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			if not charEntity:AcquireLock(fsm.Id) then
				fsm.State = "Completed"
				return
			end
			fsm.Context._lockHeld = true
			fsm.State = "ValidateStamina"
		end,
	}, {"ValidateStamina","Completed","Failed" })


	--[=[
		@state ValidateStamina
		@description Validates the required runtime context and prerequisites.
			Transitions:
			- `DeductStamina` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ValidateStamina", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local staminaCost = fsm.Context._staminaCost or 0
			if (charEntity.Stamina or 0) < staminaCost then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Not enough stamina")
				return
			end
			fsm.State = "DeductStamina"
		end,
	}, {"DeductStamina","ReleaseLock" })


	--[=[
		@state DeductStamina
		@description On enter, replicates entity changes.
			Transitions:
			- `ResolveSequence` when this stage finishes its immediate work or falls through its guard checks.
			Writes: replicates entity changes.
	]=]

	self:AddState("DeductStamina", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local staminaCost = fsm.Context._staminaCost or 0
			if not ResourceHelpers.deductStamina(charEntity, staminaCost) then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Not enough stamina")
				return
			end
			charEntity:UpdateEntity(fsm.Id)
			fsm.State = "ResolveSequence"
		end,
	}, {"ResolveSequence" })


	--[=[
		@state ResolveSequence
		@description Resolves the data needed for the `ResolveSequence` step.
			Transitions:
			- `EmitPhaseAnimation` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._damage`, stores `Context._phases`, stores `Context._phaseStartTimes`, stores `Context._nextPhaseIndex`, stores `Context._attackDuration`.
	]=]

	self:AddState("ResolveSequence", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local comboSlot = fsm.Context._comboSlot
			local damage = DEFAULT_MELEE_DAMAGE[comboSlot] or 5
			local seqDef = MELEE_SEQUENCES[comboSlot]
			if not seqDef then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Melee sequence not found")
				return
			end

			local pointers = charEntity._MeleePointers
			if typeof(pointers) ~= "table" then
				pointers = {}
			end
			local pointer = (pointers[comboSlot] or 0) + 1
			if pointer > #seqDef.Moves then
				pointer = 1
			end
			pointers[comboSlot] = pointer
			charEntity:SetContext("_MeleePointers", pointers)

			local phases = seqDef.Moves[pointer]
			if typeof(phases) ~= "table" or #phases == 0 then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Melee phases not found")
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
			fsm.State = "EmitPhaseAnimation"
		end,
	}, {"EmitPhaseAnimation","ReleaseLock" })


	--[=[
		@state EmitPhaseAnimation
		@description On enter, stores `Context._nextPhaseIndex`, sets `_nextPhaseIndex`.
			Transitions:
			- `ScheduleDamageWindow` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._nextPhaseIndex`, sets `_nextPhaseIndex`.
	]=]

	self:AddState("EmitPhaseAnimation", {
		OnEnter = function(_, fsm)
			local phases = fsm.Context._phases
			local charEntity = fsm.Context._charEntity
			local firstPhase = typeof(phases) == "table" and phases[1] or nil
			if not charEntity or typeof(firstPhase) ~= "table" then
				StateTransitionHelpers.queueRelease(fsm,"Failed","Initial melee phase missing")
				return
			end
			appendAnimationIntent(fsm:GetOrchestrator(), charEntity, fsm, firstPhase)
			fsm.Context._nextPhaseIndex = 2
			fsm.State = "ScheduleDamageWindow"
		end,
	}, {"ScheduleDamageWindow","ReleaseLock" })


	--[=[
		@state ScheduleDamageWindow
		@description Runs the `schedule damage window` stage of `MeleeAttackJob`.
			Transitions:
			- `ScanVictims` when the scheduled transition completes.
			- `WaitForDamageWindow` when this stage finishes its immediate work or falls through its guard checks.
			- `ScanVictims` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("ScheduleDamageWindow", {
		OnEnter = function(_, fsm)
			local damageScanOffset = fsm.Context._damageScanOffset or 0
			if damageScanOffset > 0 then
				fsm:ScheduleTransition(damageScanOffset,"ScanVictims")
				fsm.State = "WaitForDamageWindow"
			else
				fsm.State = "ScanVictims"
			end
		end,
	}, {"WaitForDamageWindow","ScanVictims" })


	--[=[
		@state WaitForDamageWindow
		@description Waits until its scheduled completion or transition condition is met.
			Transitions:
			- External transitions allow: `ScanVictims`, `Failed`.
			Writes: none.
	]=]

	self:AddState("WaitForDamageWindow", {
		OnHeartbeat = function(_, fsm)
			emitDueAnimationPhases(fsm, fsm.StateDuration)
		end,
	}, {"ScanVictims","Failed" })


	--[=[
		@state ScanVictims
		@description On enter, clears `Context._currentVictim`, stores `Context._knockbackDirection`, stores `Context._victims`.
			Transitions:
			- `ProcessVictim` when this stage finishes its immediate work or falls through its guard checks.
			- `WaitForRecovery` when this stage finishes its immediate work or falls through its guard checks.
			Writes: clears `Context._currentVictim`, stores `Context._knockbackDirection`, stores `Context._victims`, stores `Context._victimIndex`, stores `Context._currentVictim`.
	]=]

	self:AddState("ScanVictims", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local attackerRoot = fsm.Context._root
			local victims = {}
			if attackerRoot and attackerRoot.Parent then
				victims = CombatHelpers.scanForwardVictims(orchestrator, fsm.CharacterEntityId, attackerRoot, DEFAULT_MELEE_RADIUS)
				fsm.Context._knockbackDirection = attackerRoot.CFrame.LookVector
			end
			fsm.Context._victims = victims
			fsm.Context._victimIndex = 1
			fsm.Context._currentVictim = nil
			if #victims > 0 then
				fsm.State = "ProcessVictim"
			else
				fsm.State = "WaitForRecovery"
			end
		end,
	}, {"ProcessVictim","WaitForRecovery" })


	--[=[
		@state ProcessVictim
		@description On enter, stores `Context._currentVictim`, stores `Context._victimIndex`, sets `_currentVictim`.
			Transitions:
			- `WaitForRecovery` when this stage finishes its immediate work or falls through its guard checks.
			- `ApplyKnockback` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._currentVictim`, stores `Context._victimIndex`, sets `_currentVictim`, sets `_victimIndex`.
	]=]

	self:AddState("ProcessVictim", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local victims = fsm.Context._victims
			local victimIndex = fsm.Context._victimIndex or 1
			local victim = typeof(victims) == "table" and victims[victimIndex] or nil
			if not victim then
				fsm.State = "WaitForRecovery"
				return
			end

			fsm.Context._currentVictim = victim
			fsm.Context._victimIndex = victimIndex + 1

			local victimHumanoid = victim.Instance and victim.Instance:FindFirstChildOfClass("Humanoid")
			local victimUserId = victim.UserId
			if victimHumanoid and victimHumanoid.Health > 0 and typeof(victimUserId) == "number" then
				local comboSlot = fsm.Context._comboSlot
				local damage = fsm.Context._damage or (DEFAULT_MELEE_DAMAGE[comboSlot] or 5)
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
			end

			fsm.State = "ApplyKnockback"
		end,
	}, {"ApplyKnockback","WaitForRecovery" })


	--[=[
		@state ApplyKnockback
		@description On enter, sets `AssemblyLinearVelocity`.
			Transitions:
			- `ProcessVictim` when this stage finishes its immediate work or falls through its guard checks.
			- `WaitForRecovery` when this stage finishes its immediate work or falls through its guard checks.
			Writes: sets `AssemblyLinearVelocity`.
	]=]

	self:AddState("ApplyKnockback", {
		OnEnter = function(_, fsm)
			local victim = fsm.Context._currentVictim
			local knockbackDirection = fsm.Context._knockbackDirection
			local victimRoot = victim and victim.Instance and victim.Instance:FindFirstChild("HumanoidRootPart")
			if victimRoot and typeof(knockbackDirection) == "Vector3" then
				local knockForce = knockbackDirection * 25 + Vector3.new(0, 10, 0)
				victimRoot.AssemblyLinearVelocity = victimRoot.AssemblyLinearVelocity + knockForce
			end

			local victims = fsm.Context._victims
			local nextIndex = fsm.Context._victimIndex or 1
			if typeof(victims) == "table" and nextIndex <= #victims then
				fsm.State = "ProcessVictim"
			else
				fsm.State = "WaitForRecovery"
			end
		end,
	}, {"ProcessVictim","WaitForRecovery" })


	--[=[
		@state WaitForRecovery
		@description Waits until its scheduled completion or transition condition is met.
			Transitions:
			- `ReleaseLock` when the scheduled transition completes.
			- `ReleaseLock` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

	self:AddState("WaitForRecovery", {
		OnEnter = function(_, fsm)
			local totalDuration = fsm.Context._attackDuration or 0
			local damageScanOffset = fsm.Context._damageScanOffset or 0
			local remainingDuration = math.max(totalDuration - damageScanOffset, 0)
			if remainingDuration > 0 then
				fsm:ScheduleTransition(remainingDuration,"ReleaseLock")
			else
				fsm.State = "ReleaseLock"
			end
		end,
		OnHeartbeat = function(_, fsm)
			local damageScanOffset = fsm.Context._damageScanOffset or 0
			emitDueAnimationPhases(fsm, damageScanOffset + fsm.StateDuration)
		end,
	}, {"ReleaseLock","Failed" })


	--[=[
		@state ReleaseLock
		@description On enter, stores `Context._lockHeld`, stores `Context._releaseTargetState`, sets `_lockHeld`.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: stores `Context._lockHeld`, stores `Context._releaseTargetState`, sets `_lockHeld`, sets `_releaseTargetState`.
	]=]

	self:AddState("ReleaseLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			if charEntity and fsm.Context._lockHeld then
				charEntity:ReleaseLock(fsm.Id)
				fsm.Context._lockHeld = false
			end

			if fsm.Context._releaseTargetState == "Failed" then
				fsm:Fail(fsm.Context._releaseReason or "Melee attack failed")
				return
			end
			fsm.State = "Completed"
		end,
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success sink reached after `ReleaseLock` drops the held character lock at the end of the melee timeline. `OnEnter` is a no-op because the job has already finished its work.
		Transitions: none.
		Writes: none.
]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink entered when `ReleaseLock` forwards `_releaseReason` into `Fail`. `OnEnter` is a no-op because lock cleanup and failure bookkeeping happen before entry.
		Transitions: none.
		Writes: none.
]=]

	self:AddState("Failed", function() end, {})
end

return MeleeAttackJob
