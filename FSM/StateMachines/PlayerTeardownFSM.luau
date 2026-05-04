--!strict

--[=[
	@module PlayerTeardownFSM
	@description Cancels the player-owned FSMs, flushes persistent entities, deletes the player and character entities, and finishes with teardown logging.
]=]

local PlayerTeardownFSM = {
	Name = "PlayerTeardownFSM",
	className = "PlayerTeardownFSM",
	validStates = {"CancelSMs","FlushEntities","DeleteEntities","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "CancelSMs",
}

--[=[
	@description Returns the state machines for this FSM, or `nil` when it cannot be found.
	@param orchestrator any  -- Orchestrator used to resolve entities, modules, or child jobs.
	@return any -- Resolved state machines, or `nil` when unavailable.
]=]

local function getStateMachines(orchestrator: any): { [string]: any }
	if type(orchestrator.GetStateMachines) == "function" then
		local ok, result = pcall(function()
			return orchestrator.GetStateMachines()
		end)
		if ok and type(result) == "table" then
			return result
		end
	end

	return {}
end

--[=[
	@description Returns the state machine field for this FSM, or `nil` when it cannot be found.
	@param stateMachine any  -- State machine being inspected during teardown matching.
	@param key any  -- Field name to read from the state machine or its context.
	@return any -- Resolved state machine field, or `nil` when unavailable.
]=]

local function getStateMachineField(stateMachine: any, key: string): any
	local context = stateMachine and stateMachine.Context
	if type(context) == "table" and context[key] ~= nil then
		return context[key]
	end

	local ok, value = pcall(function()
		return stateMachine[key]
	end)
	if ok then
		return value
	end

	return nil
end

--[=[
	@description Performs the `stateMachineMatchesPlayer` helper work.
	@param fsm any  -- PlayerTeardownFSM instance carrying the user, entity ids, and teardown bookkeeping.
	@param candidateId any  -- Candidate state-machine id from the orchestrator lookup.
	@param stateMachine any  -- State machine being inspected during teardown matching.
	@return boolean -- Whether the helper completed successfully.
]=]

local function stateMachineMatchesPlayer(fsm: any, candidateId: string, stateMachine: any): boolean
	if stateMachine == nil then
		return false
	end
	if candidateId == fsm.StateMachineId then
		return false
	end

	local player = fsm.Player
	local userId = fsm.UserId
	local playerEntityId = fsm.PlayerEntityId
	local charEntityId = fsm.CharacterEntityId

	if getStateMachineField(stateMachine,"Player") == player then
		return true
	end
	if getStateMachineField(stateMachine,"UserId") == userId then
		return true
	end
	if getStateMachineField(stateMachine,"PlayerEntityId") == playerEntityId then
		return true
	end
	if getStateMachineField(stateMachine,"CharacterEntityId") == charEntityId then
		return true
	end
	if getStateMachineField(stateMachine,"AttackerCharEntityId") == charEntityId then
		return true
	end
	if getStateMachineField(stateMachine,"VictimUserId") == userId then
		return true
	end

	local stateMachineId = getStateMachineField(stateMachine,"StateMachineId")
	if type(stateMachineId) == "string" then
		if
			string.find(stateMachineId, playerEntityId, 1, true) or string.find(stateMachineId, charEntityId, 1, true)
		then
			return true
		end
	end

	return false
end

--[=[
	@description Saves a persistent entity through the available persistence API before teardown deletes it.
	@param orchestrator any  -- Orchestrator providing persistence services.
	@param entity any  -- Entity being flushed if it is marked persistent.
	@return boolean -- `true` when a persistence save call succeeds.
]=]

local function flushPersistentEntity(orchestrator: any, entity: any)
	if not entity or not entity._privateProperties then
		return false
	end

	local context = entity._privateProperties.Context or {}
	if not context._IsPersistent then
		return false
	end

	local persistenceManager = orchestrator.Factory and orchestrator.Factory.PersistenceManager
	if persistenceManager and type(persistenceManager.SaveState) == "function" then
		local ok = pcall(function()
			persistenceManager.SaveState(entity)
		end)
		return ok
	end

	local persistence = orchestrator.Persistence
	if persistence and type(persistence.Save) == "function" then
		local key = context._PersistenceKey or context.EntityId
		local ok = pcall(function()
			persistence:Save(entity, key)
		end)
		return ok
	end

	return false
end

--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `PlayerTeardownFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function PlayerTeardownFSM:RegisterStates()

	--[=[
	@state CancelSMs
	@description Cancels every state machine tied to the player, stores the cancelled ids, and logs the teardown fan-out.
	Transitions:
	- `FlushEntities` when OnEnter finishes or falls through its guard checks.
	Writes: stores `Context._cancelledStateMachineIds`, sets `_cancelledStateMachineIds`, writes to the log.

]=]

	self:AddState("CancelSMs", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local cancelled = 0
			local cancelledIds = {}

			for stateMachineId, stateMachine in pairs(getStateMachines(orchestrator)) do
				if stateMachineMatchesPlayer(fsm, stateMachineId, stateMachine) then
					local ok = pcall(function()
						if type(orchestrator.CancelStateMachine) == "function" then
							orchestrator.CancelStateMachine(stateMachineId)
						elseif stateMachine and type(stateMachine.Cancel) == "function" then
							stateMachine:Cancel()
						end
					end)
					if ok then
						cancelled += 1
						table.insert(cancelledIds, stateMachineId)
					end
				end
			end

			fsm.Context._cancelledStateMachineIds = cancelledIds
			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"PlayerTeardownFSM cancelled %d state machines for userId %s",
					cancelled,
					tostring(fsm.UserId)
				),
				Data = { CancelledIds = cancelledIds },
			})
			fsm.State = "FlushEntities"
		end,
	}, {"FlushEntities","Failed" })

	--[=[
	@state FlushEntities
	@description Flushes the persistent player and character entities when present, counts successful flushes, and logs the result.
	Transitions:
	- `DeleteEntities` when OnEnter finishes or falls through its guard checks.
	Writes: writes to the log.

]=]

	self:AddState("FlushEntities", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local flushedCount = 0
			local entityIds = { fsm.PlayerEntityId, fsm.CharacterEntityId }

			for _, entityId in ipairs(entityIds) do
				if typeof(entityId) == "string" and entityId ~= "" then
					local entity = orchestrator.GetEntity(entityId)
					if flushPersistentEntity(orchestrator, entity) then
						flushedCount += 1
					end
				end
			end

			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"PlayerTeardownFSM flushed %d persistent entities for userId %s",
					flushedCount,
					tostring(fsm.UserId)
				),
			})
			fsm.State = "DeleteEntities"
		end,
	}, {"DeleteEntities","Failed" })

	--[=[
	@state DeleteEntities
	@description Deletes the character and player entities from the orchestrator and logs which ids were removed.
	Transitions:
	- `Completed` when OnEnter finishes or falls through its guard checks.
	Writes: writes to the log.

]=]

	self:AddState("DeleteEntities", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local deletedIds = {}

			for _, entityId in ipairs({ fsm.CharacterEntityId, fsm.PlayerEntityId }) do
				if typeof(entityId) == "string" and entityId ~= "" then
					pcall(function()
						orchestrator.DeleteEntity(entityId)
					end)
					table.insert(deletedIds, entityId)
				end
			end

			fsm:Log({
				Level = "INFO",
				Message = string.format(
					"PlayerTeardownFSM deleted %d entities for userId %s",
					#deletedIds,
					tostring(fsm.UserId)
				),
				Data = { DeletedIds = deletedIds },
			})
			fsm.State = "Completed"
		end,
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success state entered after state machines are cancelled, matching entities are deleted, and teardown logging can be finalized. `OnEnter` writes the final info log for `UserId`.
	Transitions: none.
	Writes: info log.

]=]

	self:AddState("Completed", {
		OnEnter = function(_, fsm)
			fsm:Log({
				Level = "INFO",
				Message = string.format("PlayerTeardownFSM completed for userId %s", tostring(fsm.UserId)),
			})
		end,
	}, {})
	--[=[
	@state Failed
	@description Terminal failure state for teardown errors while cancelling machines or deleting entities. `OnEnter` logs the failure reason for `UserId` and performs no additional rollback.
	Transitions: none.
	Writes: error log.

]=]

	self:AddState("Failed", {
		OnEnter = function(_, fsm, reason)
			fsm:Log({
				Level = "ERROR",
				Message = string.format(
					"PlayerTeardownFSM failed for userId %s: %s",
					tostring(fsm.UserId),
					tostring(reason or "unknown error")
				),
			})
		end,
	}, {})
end

return PlayerTeardownFSM
