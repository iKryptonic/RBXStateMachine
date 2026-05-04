--!strict


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

--[=[
	@module MovementConstraintJob
	@description Applies a temporary movement patch to a character entity and restores the prior values when the duration expires or cleanup runs.
]=]

local MovementConstraintJob = {
	Name = "MovementConstraintJob",
	className = "MovementConstraintJob",
	validStates = {"Validate","SnapshotPrior","ApplyPatch","WaitDuration","RevertPatch","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Validate",
}


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `MovementConstraintJob`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function MovementConstraintJob:RegisterStates()


	--[=[
		@state Validate
		@description Validates the required runtime context and prerequisites.
			Transitions:
			- `SnapshotPrior` when this stage finishes its immediate work or falls through its guard checks.
			- `Failed` when validation or downstream work reports an unrecoverable problem.
			Writes: none.
	]=]

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
	}, {"SnapshotPrior","Failed" })


	--[=[
		@state SnapshotPrior
		@description Runs the `snapshot prior` stage of `MovementConstraintJob`.
			Transitions:
			- `ApplyPatch` when this stage finishes its immediate work or falls through its guard checks.
			Writes: none.
	]=]

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
	}, {"ApplyPatch","Failed" })


	--[=[
		@state ApplyPatch
		@description On enter, sets `CanMove`, sets `MoveSpeedCap`, sets `MouseLocked`.
			Transitions:
			- `WaitDuration` when this stage finishes its immediate work or falls through its guard checks.
			Writes: sets `CanMove`, sets `MoveSpeedCap`, sets `MouseLocked`, replicates entity changes, writes to the log.
	]=]

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
			if appliedPatch and charEntity:UpdateEntity() == false and type(fsm.Log) == "function" then
				fsm:Log({ Level = "WARN", Message = "No pending changes during movement constraint apply" })
			end

			fsm.State = "WaitDuration"
		end,
	}, {"WaitDuration","Failed" })


	--[=[
		@state WaitDuration
		@description Waits until its scheduled completion or transition condition is met.
			Transitions:
			- External transitions allow: `RevertPatch`, `Failed`.
			Writes: none.
	]=]

	self:AddState("WaitDuration", {
		OnEnter = function(_, fsm)
			StateTransitionHelpers.scheduleTransitionCompat(fsm, fsm.Duration,"RevertPatch","WaitDuration")
		end,
	}, {"RevertPatch","Failed" })


	--[=[
		@state RevertPatch
		@description On enter, sets `CanMove`, sets `MoveSpeedCap`, sets `MouseLocked`.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
			Writes: sets `CanMove`, sets `MoveSpeedCap`, sets `MouseLocked`, replicates entity changes.
	]=]

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
			charEntity:UpdateEntity()

			fsm._patchApplied = false
			fsm.State = "Completed"
		end,
	}, {"Completed","Failed" })
end


--[=[
	@description Restores any mutable runtime state that still needs cleanup if the FSM stops before its normal completion path.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

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
