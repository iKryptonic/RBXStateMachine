--!strict
-- @Name MovementConstraintJob
-- @Description FSM state machine module.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

local MovementConstraintJob = {
	Name = "MovementConstraintJob",
	className = "MovementConstraintJob",
	validStates = { "Validate", "SnapshotPrior", "ApplyPatch", "WaitDuration", "RevertPatch", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}

function MovementConstraintJob:RegisterStates()
	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			if type(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("Missing CharacterEntityId")
				return
			end
			if type(fsm.Duration) ~= "number" or fsm.Duration < 0 then
				fsm:Fail("Invalid movement constraint duration")
				return
			end

			local charEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			fsm.CharacterEntity = charEntity
			fsm.State = "SnapshotPrior"
		end,
	}, { "SnapshotPrior", "Failed" })

	self:AddState("SnapshotPrior", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			fsm._snapshot = {
				CanMove = charEntity.CanMove,
				MoveSpeedCap = charEntity.MoveSpeedCap,
				MouseLocked = charEntity.MouseLocked,
			}
			fsm.State = "ApplyPatch"
		end,
	}, { "ApplyPatch", "Failed" })

	self:AddState("ApplyPatch", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			local appliedPatch = false
			if fsm.CanMove ~= nil then
				charEntity.CanMove = fsm.CanMove
				appliedPatch = true
			end
			if fsm.MoveSpeedCap ~= nil then
				charEntity.MoveSpeedCap = fsm.MoveSpeedCap
				appliedPatch = true
			end
			if fsm.MouseLocked ~= nil then
				charEntity.MouseLocked = fsm.MouseLocked
				appliedPatch = true
			end

			fsm._patchApplied = appliedPatch
			if appliedPatch and charEntity:UpdateEntity() == false then
				fsm:Fail("Failed to apply movement constraint patch")
				return
			end

			fsm.State = "WaitDuration"
		end,
	}, { "WaitDuration", "Failed" })

	self:AddState("WaitDuration", {
		OnEnter = function(_, fsm)
			StateTransitionHelpers.scheduleTransitionCompat(fsm, fsm.Duration, "RevertPatch", "WaitDuration")
		end,
	}, { "RevertPatch", "Failed" })

	self:AddState("RevertPatch", {
		OnEnter = function(_, fsm)
			if not fsm._patchApplied then
				fsm.State = "Completed"
				return
			end

			local charEntity = fsm.CharacterEntity
			local snapshot = fsm._snapshot or {}
			charEntity.CanMove = snapshot.CanMove
			charEntity.MoveSpeedCap = snapshot.MoveSpeedCap
			charEntity.MouseLocked = snapshot.MouseLocked
			if charEntity:UpdateEntity() == false then
				fsm:Fail("Failed to revert movement constraint patch")
				return
			end

			fsm._patchApplied = false
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })
end

function MovementConstraintJob:OnCleanup()
	if not self._patchApplied then
		return
	end

	local charEntity = self.CharacterEntity
	local snapshot = self._snapshot
	if not charEntity or not snapshot then
		return
	end

	charEntity.CanMove = snapshot.CanMove
	charEntity.MoveSpeedCap = snapshot.MoveSpeedCap
	charEntity.MouseLocked = snapshot.MouseLocked
	self._patchApplied = false
	charEntity:UpdateEntity()
end

return MovementConstraintJob
