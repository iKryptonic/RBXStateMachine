--!strict

local KnockdownJob = {
	Name = "KnockdownJob",
	className = "KnockdownJob",
	validStates = { "Validate", "AcquireCCLock", "ApplyFlags", "EmitKnockdownIntent", "WaitDuration", "ClearFlags", "ReleaseCCLock", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local function getSharedModule(orchestrator: any, name)
	local getModule = orchestrator and orchestrator.GetModule
	if type(getModule) == "function" then
		local module = getModule(name)
		if module ~= nil then
			return module
		end
	end

	local sharedFolder = game:GetService("ReplicatedStorage"):FindFirstChild("shared")
	if sharedFolder then
			local mod = sharedFolder:FindFirstChild(name)
			if mod then return require(mod) end
	end
	error("Shared module not found: " .. name)
end

local function getIntentSchema(orchestrator: any)
	return getSharedModule(orchestrator, "IntentSchema")
end

local function scheduleTransitionCompat(fsm: any, seconds: number, targetState: string, expectedState: string)
	if type(fsm.ScheduleTransition) == "function" then
		fsm:ScheduleTransition(seconds, targetState)
		return
	end

	task.delay(seconds, function()
		if fsm.IsActive and fsm.State == expectedState then
			fsm.State = targetState
		end
	end)
end

local function failOrRelease(fsm: any, reason: string)
	if fsm._ccLockHeld then
		fsm._failureReason = reason
		fsm.State = "ReleaseCCLock"
	else
		fsm:Fail(reason)
	end
end

function KnockdownJob:RegisterStates()
	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			if type(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("Missing CharacterEntityId")
				return
			end
			if type(fsm.Duration) ~= "number" or fsm.Duration < 0 then
				fsm:Fail("Invalid knockdown duration")
				return
			end

			local charEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			fsm.CharacterEntity = charEntity
			fsm.State = "AcquireCCLock"
		end,
	}, { "AcquireCCLock", "Failed" })

	self:AddState("AcquireCCLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if charEntity.CCLock then
				fsm:Fail("CCLock already held")
				return
			end

			fsm._ccLockHeld = true
			charEntity.CCLock = true
			if charEntity:UpdateEntity() == false then
				fsm._failureReason = "Failed to acquire CCLock"
				fsm.State = "ReleaseCCLock"
				return
			end

			fsm.State = "ApplyFlags"
		end,
	}, { "ApplyFlags", "ReleaseCCLock", "Failed" })

	self:AddState("ApplyFlags", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			charEntity.IsKnocked = true
			charEntity.CanMove = false
			charEntity.MoveSpeedCap = 0
			if charEntity:UpdateEntity() == false then
				failOrRelease(fsm, "Failed to apply knockdown flags")
				return
			end

			fsm._flagsApplied = true
			fsm.State = "EmitKnockdownIntent"
		end,
	}, { "EmitKnockdownIntent", "ReleaseCCLock", "Failed" })

	self:AddState("EmitKnockdownIntent", {
		OnEnter = function(_, fsm)
			local IntentSchema = getIntentSchema(fsm:GetOrchestrator())
			local ok, err = pcall(function()
				IntentSchema.AppendIntent(fsm.CharacterEntity, {
					Kind = "Animation",
					Payload = { Name = "Knocked" },
				})
			end)
			if not ok then
				failOrRelease(fsm, "Failed to emit knockdown intent: " .. tostring(err))
				return
			end

			fsm.State = "WaitDuration"
		end,
	}, { "WaitDuration", "ReleaseCCLock", "Failed" })

	self:AddState("WaitDuration", {
		OnEnter = function(_, fsm)
			scheduleTransitionCompat(fsm, fsm.Duration, "ClearFlags", "WaitDuration")
		end,
	}, { "ClearFlags", "ReleaseCCLock", "Failed" })

	self:AddState("ClearFlags", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			charEntity.IsKnocked = false
			charEntity.CanMove = true
			charEntity.MoveSpeedCap = 16
			if charEntity:UpdateEntity() == false then
				failOrRelease(fsm, "Failed to clear knockdown flags")
				return
			end

			fsm._flagsApplied = false
			fsm.State = "ReleaseCCLock"
		end,
	}, { "ReleaseCCLock", "Failed" })

	self:AddState("ReleaseCCLock", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if charEntity and fsm._ccLockHeld then
				charEntity.CCLock = false
				if charEntity:UpdateEntity() == false and not fsm._failureReason then
					fsm._failureReason = "Failed to release CCLock"
				end
			end

			fsm._ccLockHeld = false
			if fsm._failureReason then
				fsm:Fail(fsm._failureReason)
			else
				fsm.State = "Completed"
			end
		end,
	}, { "Completed", "Failed" })
end

function KnockdownJob:OnCleanup()
	local charEntity = self.CharacterEntity
	if not charEntity then
		return
	end

	local shouldUpdate = false
	if self._flagsApplied then
		charEntity.IsKnocked = false
		charEntity.CanMove = true
		charEntity.MoveSpeedCap = 16
		self._flagsApplied = false
		shouldUpdate = true
	end
	if self._ccLockHeld then
		charEntity.CCLock = false
		self._ccLockHeld = false
		shouldUpdate = true
	end
	if shouldUpdate then
		charEntity:UpdateEntity()
	end
end

return KnockdownJob
