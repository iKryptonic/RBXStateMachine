--!strict
-- @Name PlayerTeardownFSM
-- @Author Copilot
-- @Description Server-side teardown FSM for observable player cleanup.

local PlayerTeardownFSM = {
	Name = "PlayerTeardownFSM",
	className = "PlayerTeardownFSM",
	validStates = { "CancelSMs", "FlushEntities", "DeleteEntities", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "CancelSMs",
}

local sharedAny = shared :: any

-- TODO: Prefer fsm:GetOrchestrator() / fsm:GetEntity() now that Orchestrator injects itself into Context.
local function getOrchestrator()
	local lower = sharedAny.fsm
	if lower ~= nil then
		return lower.Orchestrator or lower
	end

	local upper = sharedAny.FSM
	if upper ~= nil and upper.Orchestrator then
		return upper.Orchestrator
	end

	error("Orchestrator not found. Check RegisterComponents.")
end

local function getStateMachines(orchestrator: any): { [string]: any }
	if type(orchestrator.GetStateMachines) == "function" then
		local ok, result = pcall(function()
			return orchestrator.GetStateMachines()
		end)
		if ok and type(result) == "table" then
			return result
		end
	end

	if type(sharedAny.fsm) == "table" and type(sharedAny.fsm.StateMachines) == "table" then
		return sharedAny.fsm.StateMachines
	end
	if type(sharedAny.FSM) == "table" and type(sharedAny.FSM.StateMachines) == "table" then
		return sharedAny.FSM.StateMachines
	end

	return {}
end

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

	if getStateMachineField(stateMachine, "Player") == player then
		return true
	end
	if getStateMachineField(stateMachine, "UserId") == userId then
		return true
	end
	if getStateMachineField(stateMachine, "PlayerEntityId") == playerEntityId then
		return true
	end
	if getStateMachineField(stateMachine, "CharacterEntityId") == charEntityId then
		return true
	end
	if getStateMachineField(stateMachine, "AttackerCharEntityId") == charEntityId then
		return true
	end
	if getStateMachineField(stateMachine, "VictimUserId") == userId then
		return true
	end

	local stateMachineId = getStateMachineField(stateMachine, "StateMachineId")
	if type(stateMachineId) == "string" then
		if string.find(stateMachineId, playerEntityId, 1, true) or string.find(stateMachineId, charEntityId, 1, true) then
			return true
		end
	end

	return false
end

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

function PlayerTeardownFSM:RegisterStates()
	self:AddState("CancelSMs", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
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
				Message = string.format("PlayerTeardownFSM cancelled %d state machines for userId %s", cancelled, tostring(fsm.UserId)),
				Data = { CancelledIds = cancelledIds },
			})
			fsm.State = "FlushEntities"
		end,
	}, { "FlushEntities", "Failed" })

	self:AddState("FlushEntities", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
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
				Message = string.format("PlayerTeardownFSM flushed %d persistent entities for userId %s", flushedCount, tostring(fsm.UserId)),
			})
			fsm.State = "DeleteEntities"
		end,
	}, { "DeleteEntities", "Failed" })

	self:AddState("DeleteEntities", {
		OnEnter = function(_, fsm)
			local orchestrator = getOrchestrator()
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
				Message = string.format("PlayerTeardownFSM deleted %d entities for userId %s", #deletedIds, tostring(fsm.UserId)),
				Data = { DeletedIds = deletedIds },
			})
			fsm.State = "Completed"
		end,
	}, { "Completed", "Failed" })

	self:AddState("Completed", {
		OnEnter = function(_, fsm)
			fsm:Log({ Level = "INFO", Message = string.format("PlayerTeardownFSM completed for userId %s", tostring(fsm.UserId)) })
		end,
	}, {})

	self:AddState("Failed", {
		OnEnter = function(_, fsm, reason)
			fsm:Log({ Level = "ERROR", Message = string.format("PlayerTeardownFSM failed for userId %s: %s", tostring(fsm.UserId), tostring(reason or "unknown error")) })
		end,
	}, {})
end

return PlayerTeardownFSM
