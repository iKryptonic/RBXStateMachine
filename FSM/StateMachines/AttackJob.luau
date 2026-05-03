--!strict
-- @Name AttackJob
-- @Author iKrypto

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local Shared = ReplicatedStorage:WaitForChild("shared")
local EquipHelpers = require(Shared:WaitForChild("EquipHelpers"))
local EntityHelpers = require(Helpers:WaitForChild("EntityHelpers"))
local CombatHelpers = require(Helpers:WaitForChild("CombatHelpers"))
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))

local AttackJob = {
	Name = "AttackJob",
	className = "AttackJob",
	validStates = {
		"Validate",
		"AcquireCombatLock",
		"ResolveAttackDef",
		"ApplyMovementConstraints",
		"EmitWindupIntent",
		"PlayTimeline",
		"EmitRecoveryIntent",
		"RollbackConstraints",
		"ReleaseCombatLock",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local DEFAULT_RADIUS = 5
local DEFAULT_CONSTRAINTS = {
	CanMove = false,
	MoveSpeedCap = 0,
	MouseLocked = true,
}

local function transitionToFailure(fsm: any, reason: string)
	fsm.Context._failureReason = reason
	if fsm.State == "ReleaseCombatLock" then
		fsm.State = "Failed"
	else
		fsm.State = "RollbackConstraints"
	end
end

local function chooseValue(value: any, defaultValue: any): any
	if typeof(value) == "table" then
		local count = #value
		if count > 0 then
			return value[math.random(1, count)]
		end
		return defaultValue
	end
	if value == nil then
		return defaultValue
	end
	return value
end

local function appendOptionalIntent(
	orchestrator: any,
	characterEntity: any,
	intentDef: any,
	sourceCharId: string,
	lockId: string?
)
	if typeof(intentDef) ~= "table" then
		return
	end

	local kind = intentDef.Kind
	if typeof(kind) ~= "string" then
		return
	end

	local payload = IntentHelpers.buildIntentPayload(kind, intentDef)
	if payload then
		IntentHelpers.appendIntent(orchestrator, characterEntity, kind, payload, sourceCharId, sourceCharId, lockId)
	end
end

local function getItemData(weaponId: string): any?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
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

	local ok, itemData = pcall(require, dataModule)
	if ok then
		return itemData
	end
	return nil
end

local function getSequentialCombo(
	characterEntity: any,
	comboSlot: number,
	weaponId: string,
	comboDef: any
): (any?, number?)
	local comboPointers = characterEntity._ComboPointers
	if typeof(comboPointers) ~= "table" then
		comboPointers = {}
	end

	local comboKey = string.format("%s:%d", weaponId, comboSlot)
	local pointerState = comboPointers[comboKey]
	if typeof(pointerState) ~= "table" then
		pointerState = {
			Pointer = 0,
			LastAt = 0,
		}
	end

	local now = os.clock()
	local sequenceLength = #comboDef
	if sequenceLength <= 0 then
		return nil, nil
	end

	if typeof(pointerState.LastAt) ~= "number" or now - pointerState.LastAt > 1 then
		pointerState.Pointer = 0
	end

	pointerState.Pointer = (if typeof(pointerState.Pointer) == "number" then pointerState.Pointer else 0) + 1
	if pointerState.Pointer > sequenceLength then
		pointerState.Pointer = 1
	end
	pointerState.LastAt = now
	comboPointers[comboKey] = pointerState
	characterEntity:SetContext("_ComboPointers", comboPointers)

	return comboDef[pointerState.Pointer], pointerState.Pointer
end

local function logTimelineStep(fsm: any, message: string)
	fsm:Log({
		Level = "DEBUG",
		Message = message,
	})
end

local function resolveTimelineLength(combo: any): number
	local explicit = combo.t
	if typeof(explicit) == "number" and explicit > 0 then
		return explicit
	end

	local highest = 0
	for _, entry in ipairs(combo) do
		local frameNumber = tonumber(entry[2]) or 0
		if frameNumber > highest then
			highest = frameNumber
		end
	end
	return highest
end

local function applyDamageToVictim(orchestrator: any, fsm: any, victimEntity: any, frameNumber: number): boolean
	local victimId = if typeof(victimEntity.EntityId) == "string" then victimEntity.EntityId else nil
	if typeof(victimId) ~= "string" or victimId == "" then
		logTimelineStep(fsm, "Skipping damage victim without entity id")
		return false
	end

	local victimUserId = victimEntity.UserId
	if typeof(victimUserId) ~= "number" then
		logTimelineStep(fsm, "Skipping damage victim without numeric user id: " .. victimId)
		return false
	end

	logTimelineStep(fsm, string.format("Creating DamageJob for victim %s at frame %d", victimId, frameNumber))
	local damageJob = CombatHelpers.createDamageJob(
		orchestrator,
		fsm.CharacterEntityId,
		victimEntity,
		fsm.Context._attackName,
		nil,
		string.format("%s_%d_%s", fsm.Id, frameNumber, HttpService:GenerateGUID(false))
	)
	if not damageJob then
		error("Failed to create DamageJob")
	end
	return true
end

local function playHitSound(characterEntity: any, entry: { any }, fsm: any)
	local hitSoundId = chooseValue(entry[3], nil)
	if hitSoundId == nil then
		logTimelineStep(fsm, "Skipping hit sound: no sound configured")
		return
	end

	logTimelineStep(fsm, "Emitting hit sound " .. tostring(hitSoundId))
	IntentHelpers.appendIntent(fsm:GetOrchestrator(), characterEntity, "Sound", {
		SoundId = tostring(hitSoundId),
		Volume = tonumber(chooseValue(entry[4], 0.5)) or 0.5,
		Pitch = tonumber(chooseValue(entry[5], 1)) or 1,
	}, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
end

local function processDamageKeyframe(fsm: any, entry: { any }, frameNumber: number)
	local orchestrator = fsm:GetOrchestrator()
	local characterEntity = fsm.Context._characterEntity
	local attackerRoot = fsm.Context._root
	if not orchestrator or not characterEntity or not attackerRoot then
		error("Attack timeline missing damage context")
	end

	logTimelineStep(fsm, string.format("Processing damage keyframe at frame %d", frameNumber))
	local debounceHit = entry[6] == true
	local debounceDelay = tonumber(chooseValue(entry[7], 0.15)) or 0.15
	local radius = tonumber(chooseValue(entry[8], DEFAULT_RADIUS)) or DEFAULT_RADIUS
	local victims = CombatHelpers.scanForwardVictims(orchestrator, fsm.CharacterEntityId, attackerRoot, radius)
	if fsm then
		logTimelineStep(fsm, string.format("Damage scan found %d victims in radius %.2f", #victims, radius))
	end
	local hitOccurred = false

	local hitDebounces = fsm.Context._hitDebounces
	if typeof(hitDebounces) ~= "table" then
		hitDebounces = {}
		fsm.Context._hitDebounces = hitDebounces
	end

	local now = os.clock()
	for victimId, expiry in pairs(hitDebounces) do
		if typeof(expiry) ~= "number" or now >= expiry then
			hitDebounces[victimId] = nil
		end
	end

	for _, victimEntity in ipairs(victims) do
		local victimId = if typeof(victimEntity.EntityId) == "string" then victimEntity.EntityId else nil
		if typeof(victimId) ~= "string" or victimId == "" then
			continue
		end
		if debounceHit and typeof(hitDebounces[victimId]) == "number" and now < hitDebounces[victimId] then
			logTimelineStep(fsm, "Skipping debounced victim " .. victimId)
			continue
		end

		if applyDamageToVictim(orchestrator, fsm, victimEntity, frameNumber) then
			hitOccurred = true
			if debounceHit then
				hitDebounces[victimId] = now + debounceDelay
			end
		end
	end

	if hitOccurred then
		playHitSound(characterEntity, entry, fsm)
	end
end

local function processTimelineEntry(fsm: any, entry: { any })
	local characterEntity = fsm.Context._characterEntity
	if not characterEntity then
		error("Attack timeline missing character entity")
	end

	local orchestrator = fsm:GetOrchestrator()

	local tag = entry[1]
	if typeof(tag) ~= "string" then
		return
	end

	if tag == "Damage" then
		processDamageKeyframe(fsm, entry, tonumber(entry[2]) or 0)
	elseif tag == "Sound" then
		local soundId = chooseValue(entry[3], nil)
		if soundId ~= nil then
			IntentHelpers.appendIntent(orchestrator, characterEntity, "Sound", {
				SoundId = tostring(soundId),
				Volume = tonumber(chooseValue(entry[4], 0.5)) or 0.5,
				Pitch = tonumber(chooseValue(entry[5], 1)) or 1,
			}, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
		end
	elseif tag == "Effect" then
		local effectName = chooseValue(entry[3], nil)
		if typeof(effectName) == "string" and effectName ~= "" then
			IntentHelpers.appendIntent(orchestrator, characterEntity, "Effect", {
				Name = effectName,
			}, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
		end
	else
		IntentHelpers.appendIntent(orchestrator, characterEntity, "Animation", {
			Name = tag,
			Speed = tonumber(chooseValue(entry[3], 1)) or 1,
			FadeTime = 0.1,
		}, fsm.CharacterEntityId, fsm.CharacterEntityId, fsm.Id)
	end
end

function AttackJob:RegisterStates()
	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			if not orchestrator then
				transitionToFailure(fsm, "Orchestrator unavailable")
				return
			end

			if typeof(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				transitionToFailure(fsm, "CharacterEntityId is required")
				return
			end

			local characterEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not characterEntity then
				transitionToFailure(fsm, "Character entity not found")
				return
			end

			local character = characterEntity.Instance
			if not character or not character:IsA("Model") then
				transitionToFailure(fsm, "Character model not found")
				return
			end

			local humanoid, root = EntityHelpers.getHumanoidAndRoot(character)
			if not humanoid or humanoid.Health <= 0 or not root then
				transitionToFailure(fsm, "Character cannot attack without a living humanoid root")
				return
			end

			if characterEntity.IsStunned == true or characterEntity.IsKnocked == true then
				transitionToFailure(fsm, "Character is crowd-controlled")
				return
			end

			local playerEntityId = if typeof(fsm.PlayerEntityId) == "string" and fsm.PlayerEntityId ~= ""
				then fsm.PlayerEntityId
				else characterEntity.PlayerEntityId
			if typeof(playerEntityId) ~= "string" or playerEntityId == "" then
				transitionToFailure(fsm, "PlayerEntityId is required")
				return
			end

			local playerEntity = fsm:GetEntity(playerEntityId)
			if not playerEntity then
				transitionToFailure(fsm, "Player entity not found")
				return
			end

			-- Check drawn weapon first, then fall back to selected weapon for combo data
			local weaponId = characterEntity.EquippedRight
			if typeof(weaponId) ~= "string" or weaponId == "" then
				weaponId = characterEntity.EquippedLeft
			end
			if typeof(weaponId) ~= "string" or weaponId == "" then
				weaponId = playerEntity.WeaponEqp
			end
			if typeof(weaponId) ~= "string" or weaponId == "" then
				transitionToFailure(fsm, "No equipped weapon found")
				return
			end

			fsm.Context._characterEntity = characterEntity
			fsm.Context._character = character
			fsm.Context._humanoid = humanoid
			fsm.Context._root = root
			fsm.Context._playerEntity = playerEntity
			fsm.Context._weaponId = weaponId
			fsm.Context._comboSlot = math.max(1, tonumber(fsm.ComboSlot) or 1)
			fsm.State = "AcquireCombatLock"
		end,
	}, { "AcquireCombatLock", "RollbackConstraints" })

	self:AddState("AcquireCombatLock", {
		OnEnter = function(_, fsm)
			local characterEntity = fsm.Context._characterEntity
			if not characterEntity then
				transitionToFailure(fsm, "Character entity missing during combat lock")
				return
			end

			if not characterEntity:AcquireLock(fsm.Id) then
				transitionToFailure(fsm, "Character is already performing another combat action")
				return
			end
			fsm.Context._entityLockHeld = true

			characterEntity.CombatLock = true
			if not characterEntity:UpdateEntity(fsm.Id) then
				characterEntity:ReleaseLock(fsm.Id)
				fsm.Context._entityLockHeld = false
				transitionToFailure(fsm, "Failed to apply combat lock")
				return
			end

			fsm.Context._combatLockApplied = true
			fsm.State = "ResolveAttackDef"
		end,
	}, { "ResolveAttackDef", "RollbackConstraints" })

	self:AddState("ResolveAttackDef", {
		OnEnter = function(_, fsm)
			local characterEntity = fsm.Context._characterEntity
			local weaponId = fsm.Context._weaponId
			local comboSlot = fsm.Context._comboSlot
			if not characterEntity or typeof(weaponId) ~= "string" or typeof(comboSlot) ~= "number" then
				transitionToFailure(fsm, "Attack definition context missing")
				return
			end

			local itemData = getItemData(weaponId)
			if not itemData then
				transitionToFailure(fsm, "Weapon AssetData not found for " .. weaponId)
				return
			end

			local combos = itemData.Animations and itemData.Animations.Combos
			local comboDef = combos and combos[comboSlot]
			if typeof(comboDef) ~= "table" then
				transitionToFailure(fsm, string.format("Combo slot %d not found", comboSlot))
				return
			end

			local selectedCombo = comboDef
			local comboPointer = 1
			if comboDef.Type == "Sequential" then
				local resolvedCombo, resolvedPointer =
					getSequentialCombo(characterEntity, comboSlot, weaponId, comboDef)
				if typeof(resolvedCombo) ~= "table" or typeof(resolvedPointer) ~= "number" then
					transitionToFailure(fsm, "Sequential combo could not be resolved")
					return
				end
				selectedCombo = resolvedCombo
				comboPointer = resolvedPointer
			end

			local totalFrames = resolveTimelineLength(selectedCombo)
			if totalFrames <= 0 then
				transitionToFailure(fsm, "Resolved combo does not define a valid timeline")
				return
			end

			local attackName = string.format("%s_%d_%d", tostring(itemData.Name or weaponId), comboSlot, comboPointer)
			fsm.Context._itemData = itemData
			fsm.Context._comboDef = comboDef
			fsm.Context._selectedCombo = selectedCombo
			fsm.Context._comboPointer = comboPointer
			fsm.Context._comboTotalFrames = totalFrames
			fsm.Context._attackName = attackName
			fsm.State = "ApplyMovementConstraints"
		end,
	}, { "ApplyMovementConstraints", "RollbackConstraints" })

	self:AddState("ApplyMovementConstraints", {
		OnEnter = function(_, fsm)
			local characterEntity = fsm.Context._characterEntity
			if not characterEntity then
				transitionToFailure(fsm, "Character entity missing during movement constraint application")
				return
			end

			fsm.Context._priorConstraints = {
				CanMove = characterEntity.CanMove == true,
				MoveSpeedCap = if typeof(characterEntity.MoveSpeedCap) == "number"
					then characterEntity.MoveSpeedCap
					else 16,
				MouseLocked = characterEntity.MouseLocked == true,
			}

			local attackDef = fsm.Context._selectedCombo
			local movementPatch = if typeof(attackDef) == "table"
					and typeof(attackDef.MovementConstraints) == "table"
				then attackDef.MovementConstraints
				else DEFAULT_CONSTRAINTS
			characterEntity.CanMove = if typeof(movementPatch.CanMove) == "boolean"
				then movementPatch.CanMove
				else DEFAULT_CONSTRAINTS.CanMove
			characterEntity.MoveSpeedCap = if typeof(movementPatch.MoveSpeedCap) == "number"
				then movementPatch.MoveSpeedCap
				else DEFAULT_CONSTRAINTS.MoveSpeedCap
			characterEntity.MouseLocked = if typeof(movementPatch.MouseLocked) == "boolean"
				then movementPatch.MouseLocked
				else DEFAULT_CONSTRAINTS.MouseLocked
			if not characterEntity:UpdateEntity(fsm.Id) then
				transitionToFailure(fsm, "Failed to apply movement constraints")
				return
			end

			fsm.Context._constraintsApplied = true
			fsm.State = "EmitWindupIntent"
		end,
	}, { "EmitWindupIntent", "RollbackConstraints" })

	self:AddState("EmitWindupIntent", {
		OnEnter = function(_, fsm)
			local characterEntity = fsm.Context._characterEntity
			if characterEntity then
				local attackDef = fsm.Context._selectedCombo
				appendOptionalIntent(
					fsm:GetOrchestrator(),
					characterEntity,
					if typeof(attackDef) == "table" then attackDef.WindupIntent else nil,
					fsm.CharacterEntityId,
					fsm.Id
				)
			end
			fsm.State = "PlayTimeline"
		end,
	}, { "PlayTimeline", "RollbackConstraints" })

	self:AddState("PlayTimeline", {
		OnEnter = function(_, fsm)
			fsm.Context._timelineElapsed = 0
			fsm.Context._timelineFrame = 0
			fsm.Context._timelineFired = {}
			fsm.Context._hitDebounces = {}
		end,
		OnHeartbeat = function(_, fsm, dt)
			local humanoid = fsm.Context._humanoid
			local combo = fsm.Context._selectedCombo
			if not humanoid or humanoid.Health <= 0 then
				transitionToFailure(fsm, "Attacker died during attack timeline")
				return
			end
			if typeof(combo) ~= "table" then
				transitionToFailure(fsm, "Attack timeline missing")
				return
			end

			fsm.Context._timelineElapsed = (
				if typeof(fsm.Context._timelineElapsed) == "number" then fsm.Context._timelineElapsed else 0
			) + dt
			local frame = math.floor(fsm.Context._timelineElapsed * 60 + 0.5)
			if frame < (fsm.Context._timelineFrame or 0) then
				frame = fsm.Context._timelineFrame
			end
			fsm.Context._timelineFrame = frame

			local fired = fsm.Context._timelineFired
			if typeof(fired) ~= "table" then
				fired = {}
				fsm.Context._timelineFired = fired
			end

			for index, entry in ipairs(combo) do
				if not fired[index] then
					local entryFrame = tonumber(entry[2]) or 0
					if frame >= entryFrame then
						local ok, err = pcall(processTimelineEntry, fsm, entry)
						if not ok then
							transitionToFailure(fsm, tostring(err))
							return
						end
						fired[index] = true
					end
				end
			end

			if frame >= (fsm.Context._comboTotalFrames or 0) then
				fsm.State = "EmitRecoveryIntent"
			end
		end,
	}, { "EmitRecoveryIntent", "RollbackConstraints" })

	self:AddState("EmitRecoveryIntent", {
		OnEnter = function(_, fsm)
			local characterEntity = fsm.Context._characterEntity
			if characterEntity then
				local attackDef = fsm.Context._selectedCombo
				appendOptionalIntent(
					fsm:GetOrchestrator(),
					characterEntity,
					if typeof(attackDef) == "table" then attackDef.RecoveryIntent else nil,
					fsm.CharacterEntityId,
					fsm.Id
				)
			end
			fsm.State = "RollbackConstraints"
		end,
	}, { "RollbackConstraints" })

	self:AddState("RollbackConstraints", {
		OnEnter = function(_, fsm)
			local characterEntity = fsm.Context._characterEntity
			if characterEntity and fsm.Context._constraintsApplied == true then
				local prior = fsm.Context._priorConstraints or {}
				characterEntity.CanMove = if typeof(prior.CanMove) == "boolean" then prior.CanMove else true
				characterEntity.MoveSpeedCap = if typeof(prior.MoveSpeedCap) == "number" then prior.MoveSpeedCap else 16
				characterEntity.MouseLocked = if typeof(prior.MouseLocked) == "boolean" then prior.MouseLocked else true
				if characterEntity:UpdateEntity(fsm.Id) == false and type(fsm.Log) == "function" then
					fsm:Log({ Level = "WARN", Message = "No pending changes during attack constraint rollback" })
				end
				fsm.Context._constraintsApplied = false
			end
			fsm.State = "ReleaseCombatLock"
		end,
	}, { "ReleaseCombatLock" })

	self:AddState("ReleaseCombatLock", {
		OnEnter = function(_, fsm)
			local characterEntity = fsm.Context._characterEntity
			if characterEntity and fsm.Context._combatLockApplied == true then
				characterEntity.CombatLock = false
				characterEntity:UpdateEntity(fsm.Id)
				fsm.Context._combatLockApplied = false
			end

			if characterEntity and fsm.Context._entityLockHeld == true then
				characterEntity:ReleaseLock(fsm.Id)
				fsm.Context._entityLockHeld = false
			end

			if fsm.Context._failureReason ~= nil then
				fsm.State = "Failed"
			else
				fsm.State = "Completed"
			end
		end,
	}, { "Completed", "Failed" })

	self:AddState("Completed", function() end, {})
	self:AddState("Failed", function(fsm)
		if typeof(fsm.Context._failureReason) == "string" then
			fsm:Log({
				Level = "ERROR",
				Message = fsm.Context._failureReason,
			})
		end
	end, {})
end

function AttackJob:OnCleanup() end

return AttackJob
