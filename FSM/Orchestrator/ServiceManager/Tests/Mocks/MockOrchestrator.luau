--!strict
-- @Name ServiceManager/Tests/Mocks/MockOrchestrator.luau
-- @Author iKrypto
-- @Description Fake Orchestrator helpers for subsystem specs and MockFramework composition.

local MockHelpers = require(script.Parent.MockHelpers)

local MockOrchestrator = {}

local function buildLegacyOrchestrator(opts: {
	tasks: { [string]: any }?,
	fsms: { [string]: any }?,
	entities: { [string]: any }?,
	buses: { [string]: any }?,
	commands: { [string]: any }?,
	entityCommands: { [string]: any }?,
	remoteEvents: { [string]: any }?,
	fps: number?,
	frameBudget: number?,
}?): any
	opts = opts or {}

	local scheduler: any = {
		Tasks = opts.tasks or {},
		PerformanceManager = {
			FPS = opts.fps or 60,
			FrameBudget = opts.frameBudget or 0.0083,
			TasksPerFrame = 4,
		},
		Schedule = function(_self, def)
			(opts and opts.tasks or {})[def.TaskName] = def
		end,
		Unschedule = function(_self, name)
			if opts and opts.tasks then
				opts.tasks[name] = nil
			end
		end,
	}

	local registry: any = {
		Entities = opts.entities or {},
		_entities = opts.entities or {},
		StateMachines = opts.fsms or {},
		StateMachineRegistered = nil,
		EntityRegistered = nil,
		GetAllStateMachines = function()
			return opts.fsms or {}
		end,
	}

	local networkManager: any = {
		EventBuses = opts.buses or {},
		Commands = opts.commands or {},
		EntityCommandCallbacks = opts.entityCommands or {},
		RemoteEvents = opts.remoteEvents or {},
		RemoteFunctions = {},
	}

	local orchestrator: any = {
		Scheduler = scheduler,
		Registry = registry,
		NetworkManager = networkManager,
		Factory = { Registry = registry },
		Entities = opts.entities or {},
		StateMachines = opts.fsms or {},
		History = {},
		Logs = { History = {} },
	}

	function orchestrator.Request(_method, _payload)
		return nil
	end

	return orchestrator
end

function MockOrchestrator.compose(mock: any): any
	local orchestrator: any = {
		Entities = mock.entities,
		StateMachines = mock.stateMachines,
		Modules = mock._modules,
		CreatedMachines = {},
		Events = mock.events,
		Commands = mock.commands,
		EntityCommandCallbacks = {},
	}

	function orchestrator.GetEntity(entityId: string)
		return mock.entities[entityId]
	end

	function orchestrator.GetEntities()
		return mock.entities
	end

	function orchestrator.GetStateMachine(stateMachineId: string)
		return mock.stateMachines[stateMachineId]
	end

	function orchestrator.GetStateMachines()
		return mock.stateMachines
	end

	function orchestrator.CreateEntity(params: any)
		params = params or {}
		local entityId = params.EntityId or params.Id or MockHelpers.generateEntityId()
		local entity = mock:CreateEntity(params.EntityClass or params.Name or "MockEntity", entityId, params.InitialData or params.Data)
		if type(params.Context) == "table" then
			for key, value in pairs(params.Context) do
				entity:SetContext(key, value)
			end
		end
		return entity
	end

	function orchestrator.CreateStateMachine(params: any)
		params = params or {}
		local context = if type(params.Context) == "table" then MockHelpers.shallowClone(params.Context) else {}
		context.StateMachineId = params.StateMachineId or context.StateMachineId or MockHelpers.generateFsmId()
		context.AutoStart = if params.AutoStart ~= nil then params.AutoStart else context.AutoStart
		if params.InitialState ~= nil then
			context.InitialState = params.InitialState
		end
		table.insert(orchestrator.CreatedMachines, params)
		return mock:CreateFSM(params.StateMachineClass, context)
	end

	function orchestrator.RegisterEntityCommandCallback(entityId: string, commandName: string, handler: any)
		local entityCallbacks = orchestrator.EntityCommandCallbacks[entityId]
		if entityCallbacks == nil then
			entityCallbacks = {}
			orchestrator.EntityCommandCallbacks[entityId] = entityCallbacks
		end
		entityCallbacks[commandName] = handler
		return handler
	end

	function orchestrator.ServerCommandEntity(entityId: string, commandName: string, ...: any)
		table.insert(mock.commands, {
			EntityId = entityId,
			Command = commandName,
			Args = MockHelpers.packArgs(...),
			Time = os.clock(),
		})
		return true
	end

	function orchestrator.GetModule(name: string)
		if mock._modules[name] ~= nil then
			return mock._modules[name]
		end

		local replicatedStorage = MockHelpers.getService("ReplicatedStorage")
		if replicatedStorage then
			local ok, sharedFolder = pcall(function()
				return replicatedStorage:FindFirstChild("shared")
			end)
			if ok and sharedFolder then
				local foundOk, moduleScript = pcall(function()
					return sharedFolder:FindFirstChild(name)
				end)
				if foundOk and MockHelpers.isModuleScript(moduleScript) then
					local result = MockHelpers.requireFromModule(moduleScript)
					mock._modules[name] = result
					return result
				end
			end
		end

		return nil
	end

	function orchestrator.RegisterModule(name: string, moduleValue: any)
		mock._modules[name] = moduleValue
		return moduleValue
	end

	function orchestrator.FireEventBus(eventName: string, ...: any)
		table.insert(mock.events, {
			Event = eventName,
			Args = MockHelpers.packArgs(...),
			Time = os.clock(),
		})
		return true
	end

	orchestrator.Scheduler = {
		Frame = 0,
		Step = function(_scheduler, count: number?)
			mock:StepFrames(count or 1)
		end,
	}

	return orchestrator
end

function MockOrchestrator.new(opts: {
	tasks: { [string]: any }?,
	fsms: { [string]: any }?,
	entities: { [string]: any }?,
	buses: { [string]: any }?,
	commands: { [string]: any }?,
	entityCommands: { [string]: any }?,
	remoteEvents: { [string]: any }?,
	fps: number?,
	frameBudget: number?,
}?): any
	return buildLegacyOrchestrator(opts)
end

function MockOrchestrator.makeTask(name: string, opts: {
	status: string?,
	priority: number?,
	executions: number?,
	errors: number?,
	avgMs: number?,
	maxMs: number?,
	recurring: boolean?,
}?): any
	opts = opts or {}
	return {
		TaskName = name,
		Status = opts.status or "scheduled",
		Priority = opts.priority or 5,
		ExecutionCount = opts.executions or 0,
		Errors = opts.errors or 0,
		IsRecurringTask = opts.recurring ~= false,
		Event = "Heartbeat",
		Perf = {
			AvgExecutionTime = (opts.avgMs or 0) / 1000,
			MaxExecutionTime = (opts.maxMs or 0) / 1000,
		},
		TaskAction = function() end,
	}
end

function MockOrchestrator.makeFSM(name: string, opts: {
	state: string?,
	isActive: boolean?,
	priority: number?,
	stateDuration: number?,
	transitionCount: number?,
	hasFailed: boolean?,
	transitions: { { From: string, To: string } }?,
}?): any
	opts = opts or {}
	return {
		Name = name,
		State = opts.state or "Idle",
		IsActive = opts.isActive ~= false,
		Priority = opts.priority or 2,
		StateDuration = opts.stateDuration or 0.5,
		TransitionCount = opts.transitionCount or 0,
		HasFailed = opts.hasFailed or false,
		_transitions = opts.transitions or {},
		TransitionHistory = opts.transitions or {},
		Cancel = function(_) end,
		validStates = { "Idle", "Running", "Done", "Failed" },
	}
end

function MockOrchestrator.makeEntity(id: string, opts: {
	className: string?,
	isValid: boolean?,
	version: number?,
	persist: boolean?,
	hasFSM: boolean?,
	context: { [string]: any }?,
	state: { [string]: any }?,
	data: { [string]: any }?,
	schema: { [string]: any }?,
}?): any
	opts = opts or {}
	return {
		_privateProperties = {
			Name = opts.className or "MockEntity",
			IsValid = opts.isValid ~= false,
			Version = opts.version or 1,
			Schema = opts.schema or {},
		},
		EntityId = id,
		Context = opts.context or {},
		State = opts.state or {},
		Data = opts.data or {},
	}
end

function MockOrchestrator.makeBus(opts: {
	subscribers: number?,
	messages: number?,
	type: string?,
}?): any
	opts = opts or {}
	local handlers = {}
	for _ = 1, (opts.subscribers or 0) do
		table.insert(handlers, function() end)
	end
	return {
		_handlers = handlers,
		Subscribers = opts.subscribers or 0,
		MessageCount = opts.messages or 0,
		Type = opts.type or "Signal",
	}
end

return MockOrchestrator
