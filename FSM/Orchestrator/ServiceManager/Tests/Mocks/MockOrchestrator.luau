--!strict
-- @Name ServiceManager/Tests/Mocks/MockOrchestrator.luau
-- @Author iKrypto
-- @Description Fake Orchestrator with the subset of API consumed by ServiceManager subsystems.

local MockOrchestrator = {}

--[=[
	Build an orchestrator with mock scheduler, network manager, registry,
	and pre-populated entities/state machines.
	@param opts {
		tasks: { [string]: any }?,
		fsms: { [string]: any }?,
		entities: { [string]: any }?,
		buses: { [string]: any }?,
		commands: { [string]: any }?,
		entityCommands: { [string]: any }?,
		remoteEvents: { [string]: any }?,
		fps: number?,
		frameBudget: number?,
	}
]=]
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
	opts = opts or {}

	local scheduler: any = {
		Tasks = opts.tasks or {},
		PerformanceManager = {
			FPS = opts.fps or 60,
			FrameBudget = opts.frameBudget or 0.0083,
			TasksPerFrame = 4,
		},
		Schedule = function(_self, def) (opts and opts.tasks or {})[def.TaskName] = def end,
		Unschedule = function(_self, name) if opts and opts.tasks then opts.tasks[name] = nil end end,
	}

	local registry: any = {
		Entities = opts.entities or {},
		_entities = opts.entities or {},
		StateMachines = opts.fsms or {},
		StateMachineRegistered = nil,
		EntityRegistered = nil,
		GetAllStateMachines = function() return opts.fsms or {} end,
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

	function orchestrator.Request(_method, _payload) return nil end

	return orchestrator
end

--[=[
	Build a fake scheduled task. Mutate properties to test status changes.
]=]
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

--[=[
	Build a fake state machine.
]=]
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

--[=[
	Build a fake entity.
]=]
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

--[=[
	Build a fake event bus with subscribers.
]=]
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
