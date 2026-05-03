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
assert(Helpers, "Helpers folder not found")
local IntentHelpers = require(Helpers:WaitForChild("IntentHelpers"))

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
	terminalStates = { "Completed", "Failed" },
	initialState = "Validate",
}
--[=[
	@description Handles `RegisterStates` for `BlockJob`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function BlockJob:RegisterStates()
--[=[
	@state Validate
	@description Handles the `Validate` state for `BlockJob`.
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
	}, { "AcquireBlockState", "Failed" })
--[=[
	@state AcquireBlockState
	@description Handles the `AcquireBlockState` state for `BlockJob`.
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
	}, { "ApplyMovementRestriction", "Failed" })
--[=[
	@state ApplyMovementRestriction
	@description Handles the `ApplyMovementRestriction` state for `BlockJob`.
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
	}, { "BroadcastBlockUpdate", "Failed" })
--[=[
	@state BroadcastBlockUpdate
	@description Handles the `BroadcastBlockUpdate` state for `BlockJob`.
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
	}, { "EmitBlockIntent", "Failed" })
--[=[
	@state EmitBlockIntent
	@description Handles the `EmitBlockIntent` state for `BlockJob`.
]=]

self:AddState("EmitBlockIntent", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.CharacterEntity
			local ok, err = pcall(function()
				IntentHelpers.appendIntent(fsm:GetOrchestrator(), charEntity, "Animation", { Name = "Blocking" }, fsm.CharacterEntityId, fsm.CharacterEntityId)
			end)
			if not ok then
				fsm:Fail("Failed to emit blocking intent: " .. tostring(err))
				return
			end
			fsm.State = "WaitForRelease"
		end,
	}, { "WaitForRelease", "Failed" })
--[=[
	@state WaitForRelease
	@description Handles the `WaitForRelease` state for `BlockJob`.
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
	}, { "ReleaseBlockState", "Failed" })
--[=[
	@state ReleaseBlockState
	@description Handles the `ReleaseBlockState` state for `BlockJob`.
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
	}, { "RestoreMovement", "Failed" })
--[=[
	@state RestoreMovement
	@description Handles the `RestoreMovement` state for `BlockJob`.
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
	}, { "BroadcastUnblockUpdate", "Failed" })
--[=[
	@state BroadcastUnblockUpdate
	@description Handles the `BroadcastUnblockUpdate` state for `BlockJob`.
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
	}, { "Completed", "Failed" })
--[=[
	@state Completed
	@description Handles the `Completed` terminal state for `BlockJob`.
]=]

self:AddState("Completed", function() end, {})
--[=[
	@state Failed
	@description Handles the `Failed` terminal state for `BlockJob`.
]=]

self:AddState("Failed", function() end, {})
end
--[=[
	@description Implements `BlockJob.OnCleanup`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
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
