--!strict


--[=[
	@Name PlayerTeardownFSM
	@Author iKrypto
	@Description Server-side player disconnect cleanup. Cancels all FSMs belonging to the
	player (by scanning StateMachineId for entity ID patterns), flushes persistent entity
	state to DataStore, then deletes both PlayerEntity and CharacterEntity from the registry.

	State flow:
	CancelSMs → FlushEntities → DeleteEntities → Completed

	Context fields:
	- _cancelledStateMachineIds: table — IDs of cancelled FSMs for logging

	Required params:
	- Player: Player — the leaving player
	- UserId: number — player's UserId
	- PlayerEntityId: string — "Player_{userId}"
	- CharacterEntityId: string — "Char_{userId}"
]=]

local PlayerTeardownFSM = {
	Name = "PlayerTeardownFSM",
	className = "PlayerTeardownFSM",
	validStates = {"CancelSMs","FlushEntities","DeleteEntities","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "CancelSMs",
}

--[=[
	@description Returns the state machines used by this state machine when it can be resolved.
	@param orchestrator any -- Input consumed by `getStateMachines`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
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
	@description Returns the state machine field used by this state machine when it can be resolved.
	@param stateMachine any -- Input consumed by `getStateMachineField`.
	@param key any -- Input consumed by `getStateMachineField`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
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
	@description Helper for the state machine matches player step used by this state machine.
	@param fsm any -- Input consumed by `stateMachineMatchesPlayer`.
	@param candidateId any -- Input consumed by `stateMachineMatchesPlayer`.
	@param stateMachine any -- Input consumed by `stateMachineMatchesPlayer`.
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
	@description Helper for the flush persistent entity step used by this state machine.
	@param orchestrator any -- Input consumed by `flushPersistentEntity`.
	@param entity any -- Input consumed by `flushPersistentEntity`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
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
		@description On enter, stores `Context._cancelledStateMachineIds`, sets `_cancelledStateMachineIds`, writes to the log.
			Transitions:
			- `FlushEntities` when this stage finishes its immediate work or falls through its guard checks.
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
		@description On enter, writes to the log.
			Transitions:
			- `DeleteEntities` when this stage finishes its immediate work or falls through its guard checks.
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
		@description On enter, writes to the log.
			Transitions:
			- `Completed` when this stage finishes its immediate work or falls through its guard checks.
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
