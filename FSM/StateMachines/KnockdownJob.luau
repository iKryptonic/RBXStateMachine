--!strict
-- @Name KnockdownJob
-- @Description FSM state machine module.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local CrowdControlHelpers = require(Helpers:WaitForChild("CrowdControlHelpers"))
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

local KnockdownJob = {
	Name = "KnockdownJob",
	className = "KnockdownJob",
	validStates = {
		"Validate",
		"AcquireCCLock",
		"ApplyFlags",
		"EmitKnockdownIntent",
		"WaitDuration",
		"ClearFlags",
		"ReleaseCCLock",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

local function getIntentSchema(orchestrator: any)
	return ModuleLoader.requireSharedModule(orchestrator, "IntentSchema")
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
			local ok, reason = CrowdControlHelpers.acquireCCLock(charEntity)
			if not ok then
				if reason == "CCLock already held" then
					fsm:Fail(reason)
				else
					fsm._failureReason = reason
					fsm.State = "ReleaseCCLock"
				end
				return
			end

			fsm._ccLockHeld = true
			fsm.State = "ApplyFlags"
		end,
	}, { "ApplyFlags", "ReleaseCCLock", "Failed" })

	self:AddState("ApplyFlags", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not CrowdControlHelpers.applyFlags(charEntity, { IsKnocked = true, CanMove = false, MoveSpeedCap = 0 }) then
				StateTransitionHelpers.failOrRelease(fsm, "Failed to apply knockdown flags")
				return
			end

			fsm._flagsApplied = true
			fsm.State = "EmitKnockdownIntent"
		end,
	}, { "EmitKnockdownIntent", "ReleaseCCLock", "Failed" })

	self:AddState("EmitKnockdownIntent", {
		OnEnter = function(_, fsm)
			local ok, err = pcall(function()
				IntentHelpers.appendIntent(fsm:GetOrchestrator(), fsm.CharacterEntity, "Animation", { Name = "Knocked" }, fsm.CharacterEntityId, fsm.CharacterEntityId)
			end)
			if not ok then
				StateTransitionHelpers.failOrRelease(fsm, "Failed to emit knockdown intent: " .. tostring(err))
				return
			end

			fsm.State = "WaitDuration"
		end,
	}, { "WaitDuration", "ReleaseCCLock", "Failed" })

	self:AddState("WaitDuration", {
		OnEnter = function(_, fsm)
			StateTransitionHelpers.scheduleTransitionCompat(fsm, fsm.Duration, "ClearFlags", "WaitDuration")
		end,
	}, { "ClearFlags", "ReleaseCCLock", "Failed" })

	self:AddState("ClearFlags", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not CrowdControlHelpers.applyFlags(charEntity, { IsKnocked = false, CanMove = true, MoveSpeedCap = 16 }) then
				StateTransitionHelpers.failOrRelease(fsm, "Failed to clear knockdown flags")
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
				if not CrowdControlHelpers.releaseCCLock(charEntity) and not fsm._failureReason then
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
