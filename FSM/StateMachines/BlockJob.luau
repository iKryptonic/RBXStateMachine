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
    @description Registers every BlockJob state, heartbeat wait, and terminal no-op with the FSM base class.
    @return nil -- Mutates the module definition by adding states.
]=]
function BlockJob:RegisterStates()
	--[=[
    @state Validate
    @description Validates the incoming character entity id, resolves the character entity, caches it, and begins the blocking pipeline.
    @transitions Transitions to `AcquireBlockState` when the entity exists; otherwise transitions to `Failed`.
    @failure Fails immediately when `CharacterEntityId` is blank or the character entity cannot be found.
    @reads `fsm.CharacterEntityId`, resolved character entity lookup.
    @writes `fsm.CharacterEntity`.
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
    @description Marks the cached character entity as blocking before movement and replication changes are applied.
    @transitions Transitions to `ApplyMovementRestriction` when the entity is cached; otherwise transitions to `Failed`.
    @failure Fails if the cached character entity disappeared before block state could be set.
    @reads `fsm.CharacterEntity`.
    @writes characterEntity.`IsBlocking`.
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
    @description Hard-caps movement speed at zero while the block is active.
    @transitions Transitions to `BroadcastBlockUpdate` when the entity exists; otherwise transitions to `Failed`.
    @failure Fails if the cached character entity disappeared before movement restriction could be applied.
    @reads `fsm.CharacterEntity`.
    @writes characterEntity.`MoveSpeedCap`.
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
    @description Pushes the blocking entity update to replication, tolerates the `no pending changes` false return from `UpdateEntity`, and marks the block as having started for cleanup tracking.
    @transitions Transitions to `EmitBlockIntent` after the broadcast attempt; otherwise transitions to `Failed` if the entity is missing.
    @failure Missing entity context fails immediately. A false return from `UpdateEntity()` only logs a warning and does not stop the FSM.
    @reads `fsm.CharacterEntity`, `characterEntity:UpdateEntity()` result.
    @writes `fsm._startedBlocking`; replicated block state side effect on the character entity.
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
    @description Appends the looping `Blocking` animation intent so clients can visually enter the block stance.
    @transitions Transitions to `WaitForRelease` when the intent append succeeds; otherwise transitions to `Failed`.
    @failure Fails when `IntentHelpers.appendIntent(...)` raises an error.
    @reads `fsm.CharacterEntity`, `fsm.CharacterEntityId`, orchestrator from `fsm:GetOrchestrator()`.
    @writes Character entity intent queue through `IntentHelpers.appendIntent(...)`.
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
    @description Idles on heartbeat until some external system clears `charEntity.IsBlocking`, at which point the FSM begins the unblock sequence.
    @transitions Transitions to `ReleaseBlockState` when `charEntity.IsBlocking == false`; otherwise remains in `WaitForRelease`. Missing entity context transitions to `Failed`.
    @failure Fails if the cached character entity disappears while waiting for release.
    @reads `fsm.CharacterEntity`, `charEntity.IsBlocking`.
    @writes No fields are written while waiting; only state control changes when release is detected.
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
    @description Clears the logical blocking flag so replicated state and animation can unwind.
    @transitions Transitions to `RestoreMovement` when the entity exists; otherwise transitions to `Failed`.
    @failure Fails if the cached character entity disappeared before the logical block flag could be cleared.
    @reads `fsm.CharacterEntity`.
    @writes characterEntity.`IsBlocking`.
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
    @description Restores the default movement cap after blocking ends.
    @transitions Transitions to `BroadcastUnblockUpdate` when the entity exists; otherwise transitions to `Failed`.
    @failure Fails if the cached character entity disappeared before movement could be restored.
    @reads `fsm.CharacterEntity`.
    @writes characterEntity.`MoveSpeedCap`.
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
    @description Replicates the unblocked entity state, tolerates the `no pending changes` false return from `UpdateEntity`, clears the cleanup flag, and completes the job.
    @transitions Transitions to `Completed` after the broadcast attempt; otherwise transitions to `Failed` if the entity is missing.
    @failure Missing entity context fails immediately. A false return from `UpdateEntity()` only logs a warning and does not stop the FSM.
    @reads `fsm.CharacterEntity`, `characterEntity:UpdateEntity()` result, `fsm._startedBlocking`.
    @writes `fsm._startedBlocking`; replicated unblocked state side effect on the character entity.
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
    @description Terminal success state for the block pipeline. No additional work runs here.
    @transitions No outbound transitions; the job stops here.
    @failure Normal unblock cleanup already finished, so `OnCleanup` will no-op because `_startedBlocking` was cleared.
    @reads No additional fields are read.
    @writes No additional fields are written.
]=]
self:AddState("Completed", function() end, {})
	--[=[
    @state Failed
    @description Terminal failure state for the block pipeline.
    @transitions No outbound transitions; the job stops here.
    @failure If blocking had already started, `OnCleanup` restores `IsBlocking`, `MoveSpeedCap`, and pushes an entity update as the rollback path.
    @reads Any previously cached entity and `_startedBlocking` flag.
    @writes No additional fields are written by the state itself.
]=]
self:AddState("Failed", function() end, {})
end

--[=[
    @description Restores `IsBlocking`, `MoveSpeedCap`, and the replicated entity update when the FSM exits unexpectedly after block start but before normal release completes.
    @return nil -- Performs best-effort cleanup when `_startedBlocking` is true.
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
