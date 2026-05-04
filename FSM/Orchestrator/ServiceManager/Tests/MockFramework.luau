--!strict


local MockEntity = require(script.Parent.Mocks.MockEntity)
local MockOrchestrator = require(script.Parent.Mocks.MockOrchestrator)
local MockCharacter = require(script.Parent.Mocks.MockCharacter)
local TransitionRecorder = require(script.Parent.Mocks.TransitionRecorder)
local MockHelpers = require(script.Parent.Mocks.MockHelpers)

local MockFramework = {}
MockFramework.__index = MockFramework

MockFramework.MockEntity = MockEntity
MockFramework.MockOrchestrator = MockOrchestrator
MockFramework.MockCharacter = MockCharacter
MockFramework.TransitionRecorder = TransitionRecorder
MockFramework.Helpers = MockHelpers


function MockFramework.new()
	local self = setmetatable({
		entities = {},
		stateMachines = {},
		commands = {},
		events = {},
		_modules = {},
	}, MockFramework)

	self._transitionRecorder = TransitionRecorder.new()
	self.transitions = self._transitionRecorder.records
	self._orchestrator = MockOrchestrator.compose(self)

	return self
end


function MockFramework:CreateEntity(entityClass: any, entityId: string?, initialData: any?)
	local resolvedEntityId = entityId or MockHelpers.generateEntityId()
	local entity = MockEntity.new(entityClass, resolvedEntityId, initialData)
	self.entities[resolvedEntityId] = entity
	return entity
end


function MockFramework:CreateCharacterEntity(entityId: string, data: any?): any
	return MockHelpers.CreateCharacterEntity(self, entityId, data)
end


function MockFramework:CreatePlayerEntity(entityId: string, data: any?): any
	return MockHelpers.CreatePlayerEntity(self, entityId, data)
end


function MockFramework:CreateFSM(fsmClass: any, context: any?)
	local BaseStateMachine = select(1, MockHelpers.getBaseModules())
	local definition = MockHelpers.resolveStateMachineDefinition(fsmClass)
	local compiledClass = MockHelpers.compileStateMachineClass(BaseStateMachine, definition)
	local ctx = if type(context) == "table" then MockHelpers.shallowClone(context) else {}
	local fsmId = ctx.StateMachineId or ctx.Id or MockHelpers.generateFsmId()

	ctx.StateMachineId = fsmId
	ctx.Id = fsmId
	ctx._Orchestrator = self._orchestrator
	ctx.Orchestrator = self._orchestrator

	local ok, machineOrErr = pcall(compiledClass.new, ctx)
	if not ok then
		error(string.format("[MockFramework] Failed to instantiate FSM '%s': %s", tostring(fsmId), tostring(machineOrErr)))
	end

	local machine = machineOrErr
	machine.Context._Orchestrator = self._orchestrator
	machine.Context.Orchestrator = self._orchestrator
	machine.Context.FSM = machine

	self.stateMachines[fsmId] = machine
	self._orchestrator.StateMachines = self.stateMachines

	if ctx.AutoStart ~= false and type(machine.Start) == "function" then
		local startArgs = if ctx.InitialState ~= nil then { State = ctx.InitialState } else nil
		local didStart, err = pcall(function()
			if startArgs then
				machine:Start(startArgs)
			else
				machine:Start()
			end
		end)
		if not didStart then
			error(string.format("[MockFramework] Failed to start FSM '%s': %s", tostring(fsmId), tostring(err)))
		end
	end

	self._transitionRecorder:SyncMachine(machine)
	return machine
end


function MockFramework:GetOrchestrator()
	return self._orchestrator
end


function MockFramework:StepFrames(count: number)
	MockHelpers.StepFrames(self, count)
end


function MockFramework:GetTransitions(fsmId: string?)
	self._transitionRecorder:SyncAll(self.stateMachines)
	return self._transitionRecorder:GetTransitions(fsmId)
end


function MockFramework:GetCommands()
	return self.commands
end


function MockFramework:Reset()
	self._transitionRecorder:SyncAll(self.stateMachines)
	for _, machine in pairs(self.stateMachines) do
		pcall(function()
			if type(machine.Destroy) == "function" then
				machine:Destroy()
			elseif type(machine.Cancel) == "function" then
				machine:Cancel()
			end
		end)
	end

	table.clear(self.entities)
	table.clear(self.stateMachines)
	table.clear(self.commands)
	table.clear(self.events)
	table.clear(self._modules)
	self._transitionRecorder:Reset()
	table.clear(self._orchestrator.CreatedMachines)
	table.clear(self._orchestrator.EntityCommandCallbacks)
	self._orchestrator.Scheduler.Frame = 0
end

return MockFramework
