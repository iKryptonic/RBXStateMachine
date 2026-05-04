--!strict
--[=[
	@Name BlockJob
	@Author iKrypto
	@Description Starts and maintains a blocking stance on a character by validating the entity, marking `IsBlocking`, applying movement restriction, broadcasting the replicated entity update, emitting the blocking animation intent, waiting for the entity to be released, then restoring movement and broadcasting the unblock update before ending in `Completed`. If the FSM dies mid-block, `OnCleanup` restores the blocking flags. Historical integrations must target `Completed`; the deprecated `Complete` spelling is intentionally not used.

	State flow diagram:
	Validate → AcquireBlockState → ApplyMovementRestriction → BroadcastBlockUpdate → EmitBlockIntent → WaitForRelease → ReleaseBlockState → RestoreMovement → BroadcastUnblockUpdate → Completed
				↘ OnCleanup restore → Failed

	Context fields:
	- CharacterEntity: any -- resolved character entity being blocked/unblocked.
	- _startedBlocking: boolean -- whether the block state was broadcast and therefore needs cleanup on failure.

	Required params:
	- CharacterEntityId: string -- character entity id that should enter the blocking stance.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))

--[=[
	@module BlockJob
	@description Enters and maintains a blocking stance, replicates the state change, and restores movement when blocking is released.
]=]

local BlockJob = {
	Name = "BlockJob",
	className = "BlockJob",
	validStates = {
		"Validate",
		"AcquireBlockState",
		"ApplyMovementRestriction",
		"BroadcastBlockUpdate",
		"EmitBlockIntent",
		"WaitForRelease",
		"ReleaseBlockState",
		"RestoreMovement",
		"BroadcastUnblockUpdate",
		"Completed",
		"Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Validate",
}


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `BlockJob`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function BlockJob:RegisterStates()


	--[=[
	@state Validate
	@description Validates the required runtime context and prerequisites.
		Transitions:
		- `AcquireBlockState` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: none.
	]=]

	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			if type(fsm.CharacterEntityId) ~= "string" or fsm.CharacterEntityId == "" then
				fsm:Fail("Missing CharacterEntityId")
				return
			end

			local charEntity = fsm:GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			fsm.CharacterEntity = charEntity
			fsm.State = "AcquireBlockState"
		end,
	}, {"AcquireBlockState","Failed" })


	--[=[
	@state AcquireBlockState
	@description Captures the lock or blocking state needed for the next step.
		Transitions:
		- `ApplyMovementRestriction` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: sets `IsBlocking`.
	]=]

	self:AddState("AcquireBlockState", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			charEntity.IsBlocking = true
			fsm.State = "ApplyMovementRestriction"
		end,
	}, {"ApplyMovementRestriction","Failed" })


	--[=[
	@state ApplyMovementRestriction
	@description On enter, sets `MoveSpeedCap`.
		Transitions:
		- `BroadcastBlockUpdate` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: sets `MoveSpeedCap`.
	]=]

	self:AddState("ApplyMovementRestriction", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			charEntity.MoveSpeedCap = 0
			fsm.State = "BroadcastBlockUpdate"
		end,
	}, {"BroadcastBlockUpdate","Failed" })


	--[=[
	@state BroadcastBlockUpdate
	@description On enter, replicates entity changes, writes to the log.
		Transitions:
		- `EmitBlockIntent` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: replicates entity changes, writes to the log.
	]=]

	self:AddState("BroadcastBlockUpdate", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			if charEntity:UpdateEntity() == false then
				-- UpdateEntity returns false for "no pending changes" which is not a real failure
				fsm:Log({ Level = "WARN", Message = "No pending changes during block broadcast" })
			end
			fsm._startedBlocking = true
			fsm.State = "EmitBlockIntent"
		end,
	}, {"EmitBlockIntent","Failed" })


	--[=[
	@state EmitBlockIntent
	@description On enter, emits an intent.
		Transitions:
		- `WaitForRelease` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: emits an intent.
	]=]

	self:AddState("EmitBlockIntent", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			local ok, err = pcall(function()
				IntentHelpers.appendIntent(fsm:GetOrchestrator(), charEntity,"Animation", { Name = "Blocking" }, fsm.CharacterEntityId, fsm.CharacterEntityId)
			end)
			if not ok then
				fsm:Fail("Failed to emit blocking intent: " .. tostring(err))
				return
			end
			fsm.State = "WaitForRelease"
		end,
	}, {"WaitForRelease","Failed" })


	--[=[
	@state WaitForRelease
	@description Waits until its scheduled completion or transition condition is met.
		Transitions:
		- `ReleaseBlockState` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: sets `IsBlocking`.
	]=]

	self:AddState("WaitForRelease", {
		OnHeartbeat = function(_, fsm, _dt)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing while blocking")
				return
			end
			if charEntity.IsBlocking == false then
				fsm.State = "ReleaseBlockState"
			end
		end,
	}, {"ReleaseBlockState","Failed" })


	--[=[
	@state ReleaseBlockState
	@description On enter, sets `IsBlocking`.
		Transitions:
		- `RestoreMovement` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: sets `IsBlocking`.
	]=]

	self:AddState("ReleaseBlockState", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			charEntity.IsBlocking = false
			fsm.State = "RestoreMovement"
		end,
	}, {"RestoreMovement","Failed" })


	--[=[
	@state RestoreMovement
	@description On enter, sets `MoveSpeedCap`.
		Transitions:
		- `BroadcastUnblockUpdate` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: sets `MoveSpeedCap`.
	]=]

	self:AddState("RestoreMovement", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			charEntity.MoveSpeedCap = 16
			fsm.State = "BroadcastUnblockUpdate"
		end,
	}, {"BroadcastUnblockUpdate","Failed" })


	--[=[
	@state BroadcastUnblockUpdate
	@description On enter, replicates entity changes, writes to the log.
		Transitions:
		- `Completed` when this stage finishes its immediate work or falls through its guard checks.
		- `Failed` when validation or downstream work reports an unrecoverable problem.
		Writes: replicates entity changes, writes to the log.
	]=]

	self:AddState("BroadcastUnblockUpdate", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			if not charEntity then
				fsm:Fail("CharacterEntity missing")
				return
			end
			if charEntity:UpdateEntity() == false then
				-- UpdateEntity returns false for "no pending changes" which is not a real failure
				fsm:Log({ Level = "WARN", Message = "No pending changes during unblock broadcast" })
			end
			fsm._startedBlocking = false
			fsm.State = "Completed"
		end,
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success sink reached after `BroadcastUnblockUpdate` replicates the restored movement state and cleared block flag. `OnEnter` is a no-op because the character writes already happened earlier.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink for validation, replication, or intent errors during block setup and release. `OnEnter` is a no-op; `OnCleanup` clears `IsBlocking`, restores `MoveSpeedCap`, and updates the entity when blocking had started.
		Transitions: none.
		Writes: none in-state; rollback writes happen in `OnCleanup`.
	]=]

	self:AddState("Failed", function() end, {})
end


--[=[
	@description Restores any mutable runtime state that still needs cleanup if the FSM stops before its normal completion path.

]=]

function BlockJob:OnCleanup()
	if not self._startedBlocking then
		return
	end

	local charEntity = self.CharacterEntity
	if not charEntity then
		return
	end

	charEntity.IsBlocking = false
	charEntity.MoveSpeedCap = 16
	self._startedBlocking = false
	charEntity:UpdateEntity()
end

return BlockJob
