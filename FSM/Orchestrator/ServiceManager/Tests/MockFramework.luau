--!strict
-- @Name ServiceManager/Tests/MockFramework.luau
-- @Author iKrypto
-- @Description Lightweight FSM/unit-test harness for creating mock entities,
-- orchestrators, and real BaseStateMachine-backed FSM instances without
-- depending on the live runtime loop.

local MockFramework = {}
MockFramework.__index = MockFramework

local FRAME_DT = 1 / 60
local entityCounter = 0
local fsmCounter = 0

local function shallowClone(source: any): any
	if type(source) ~= "table" then
		return source
	end

	local clone = {}
	for key, value in pairs(source) do
		clone[key] = value
	end
	return clone
end

local function packArgs(...: any): { any }
	return table.pack(...)
end

local function getGame(): any?
	local ok, result = pcall(function()
		return game
	end)
	if ok then
		return result
	end
	return nil
end

local function getService(serviceName: string): any?
	local gameRef = getGame()
	if not gameRef then
		return nil
	end

	local ok, service = pcall(function()
		return gameRef:GetService(serviceName)
	end)
	if ok then
		return service
	end

	return nil
end

local function isModuleScript(value: any): boolean
	if type(value) ~= "userdata" and type(value) ~= "table" then
		return false
	end

	local ok, result = pcall(function()
		return value:IsA("ModuleScript")
	end)
	return ok and result == true
end

local function matchesAncestorPath(instance: any, ancestorNames: { string }): boolean
	local current = instance
	for _, ancestorName in ipairs(ancestorNames) do
		if not current or current.Name ~= ancestorName then
			return false
		end
		current = current.Parent
	end
	return true
end

local function findModule(moduleName: string, ancestorCandidates: { { string } }): any?
	local gameRef = getGame()
	if not gameRef then
		return nil
	end

	local ok, descendants = pcall(function()
		return gameRef:GetDescendants()
	end)
	if not ok or type(descendants) ~= "table" then
		return nil
	end

	for _, descendant in ipairs(descendants) do
		if isModuleScript(descendant) and descendant.Name == moduleName then
			for _, candidate in ipairs(ancestorCandidates) do
				if matchesAncestorPath(descendant.Parent, candidate) then
					return descendant
				end
			end
		end
	end

	return nil
end

local function requireFromModule(moduleScript: any): any
	local ok, result = pcall(require, moduleScript)
	if not ok then
		error(string.format("[MockFramework] Failed to require module '%s': %s", tostring(moduleScript and moduleScript.Name), tostring(result)))
	end
	return result
end

local function buildMinimalUtil(Logger: any, Signal: any): any
	return {
		Logger = Logger,
		Signal = Signal,
		Settings = {
			Logger = {
				DebuggingEnabled = false,
				MinimumLoggingLevel = 4,
			},
			ServiceManager = {
				Enabled = false,
			},
		},
	}
end

local function getBaseModules(): (any, any, any)
	local orchestratorRoot = script.Parent.Parent.Parent
	local Logger = require(orchestratorRoot.Core.Logger)
	local Signal = require(orchestratorRoot.Core.Signal)
	local BaseStateMachine = require(orchestratorRoot.Core.Factory.BaseStateMachine)

	local util = buildMinimalUtil(Logger, Signal)
	pcall(function()
		Logger.Initialize(util)
	end)
	pcall(function()
		BaseStateMachine.Initialize(util)
	end)
	pcall(function()
		BaseStateMachine.DisableInternalLoop()
	end)

	return BaseStateMachine, Logger, Signal
end

local function compileStateMachineClass(BaseStateMachine: any, definition: any): any
	if type(definition) ~= "table" then
		error("[MockFramework] FSM definition must be a table")
	end

	if type(definition.new) == "function" then
		return definition
	end

	local effectiveDefinition = if definition.Definition then shallowClone(definition.Definition) else shallowClone(definition)
	if not effectiveDefinition.Name then
		effectiveDefinition.Name = definition.Name or definition.className or "MockFSM"
	end
	if not effectiveDefinition.className then
		effectiveDefinition.className = effectiveDefinition.Name
	end

	local subclass = BaseStateMachine.Extend(effectiveDefinition)
	for key, value in pairs(definition) do
		if key ~= "Name" and key ~= "Schema" and key ~= "ValidStates" and key ~= "Definition" then
			subclass[key] = value
		end
	end
	return subclass
end

local function resolveStateMachineDefinition(fsmClass: any): any
	if type(fsmClass) == "table" then
		return fsmClass
	end

	if isModuleScript(fsmClass) then
		return requireFromModule(fsmClass)
	end

	if type(fsmClass) == "string" then
		local moduleScript = findModule(fsmClass, {
			{ "StateMachines" },
			{ "StateMachines", "FSM" },
			{ "StateMachines", "RBXStateMachine" },
			{ "StateMachines", "FSM", "RBXStateMachine" },
		})
		if not moduleScript then
			error(string.format("[MockFramework] Unable to find FSM module '%s'", fsmClass))
		end
		return requireFromModule(moduleScript)
	end

	error(string.format("[MockFramework] Unsupported FSM class type '%s'", type(fsmClass)))
end

local MockEntityMethods = {}

local function createEntityMetatable()
	return {
		__index = function(self: any, key: any)
			local method = MockEntityMethods[key]
			if method ~= nil then
				return method
			end

			local rawValue = rawget(self, key)
			if rawValue ~= nil then
				return rawValue
			end

			if key == "Data" then
				return rawget(self, "_data")
			elseif key == "Pending" then
				return rawget(self, "_pending")
			elseif key == "Context" then
				return rawget(self, "_context")
			elseif key == "Logs" then
				return rawget(self, "_logs")
			end

			local data = rawget(self, "_data")
			if data then
				return data[key]
			end

			local context = rawget(self, "_context")
			if context then
				return context[key]
			end

			return nil
		end,
		__newindex = function(self: any, key: any, value: any)
			if type(key) == "string" and string.sub(key, 1, 1) == "_" then
				rawset(self, key, value)
				return
			end

			local pending = rawget(self, "_pending")
			local pendingKeys = rawget(self, "_pendingKeys")
			pending[key] = value
			pendingKeys[key] = true
		end,
	}
end

function MockEntityMethods:SetLockBehavior(behavior: boolean | ((string) -> boolean))
	self._lockBehavior = behavior
	return self
end

function MockEntityMethods:SetCharacter(instance: any)
	self._data.Instance = instance
	return self
end

function MockEntityMethods:AcquireLock(lockId: string): boolean
	local behavior = self._lockBehavior
	if type(behavior) == "function" then
		local ok, result = pcall(behavior, lockId)
		if ok then
			return result == true
		end
		return false
	end
	if type(behavior) == "boolean" then
		return behavior
	end
	return true
end

function MockEntityMethods:ReleaseLock(_lockId: string)
	return true
end

function MockEntityMethods:UpdateEntity(_lockId: string?): boolean
	for key in pairs(self._pendingKeys) do
		self._data[key] = self._pending[key]
	end
	table.clear(self._pending)
	table.clear(self._pendingKeys)
	return true
end

function MockEntityMethods:SetContext(key: any, value: any)
	self._context[key] = value
	return value
end

function MockEntityMethods:GetContext(key: any?)
	if key == nil then
		return self._context
	end
	return self._context[key]
end

function MockEntityMethods:Log(entry: any)
	table.insert(self._logs, shallowClone(entry))
	return entry
end

function MockEntityMethods:GetLogs()
	return self._logs
end

local function newMockEntity(entityClass: any, entityId: string, initialData: any?): any
	local entity = {
		EntityId = entityId,
		ClassName = entityClass,
		_data = shallowClone(initialData or {}),
		_pending = {},
		_pendingKeys = {},
		_context = {},
		_logs = {},
		_lockBehavior = true,
	}
	return setmetatable(entity, createEntityMetatable())
end

local function generateEntityId(): string
	entityCounter += 1
	return string.format("MockEntity_%d", entityCounter)
end

local function generateFsmId(): string
	fsmCounter += 1
	return string.format("MockFSM_%d", fsmCounter)
end

function MockFramework.new()
	local self = setmetatable({
		entities = {},
		stateMachines = {},
		transitions = {},
		commands = {},
		events = {},
		_modules = {},
		_fsmTransitionCursor = {},
	}, MockFramework)

	local orchestrator = {
		Entities = self.entities,
		StateMachines = self.stateMachines,
		Modules = self._modules,
		CreatedMachines = {},
		Events = self.events,
		Commands = self.commands,
	}

	function orchestrator.GetEntity(entityId: string)
		return self.entities[entityId]
	end

	function orchestrator.GetEntities()
		return self.entities
	end

	function orchestrator.GetStateMachine(stateMachineId: string)
		return self.stateMachines[stateMachineId]
	end

	function orchestrator.GetStateMachines()
		return self.stateMachines
	end

	function orchestrator.CreateEntity(params: any)
		params = params or {}
		local entityId = params.EntityId or params.Id or generateEntityId()
		local entity = self:CreateEntity(params.EntityClass or params.Name or "MockEntity", entityId, params.InitialData or params.Data)
		if type(params.Context) == "table" then
			for key, value in pairs(params.Context) do
				entity:SetContext(key, value)
			end
		end
		return entity
	end

	function orchestrator.CreateStateMachine(params: any)
		params = params or {}
		local context = if type(params.Context) == "table" then shallowClone(params.Context) else {}
		context.StateMachineId = params.StateMachineId or context.StateMachineId or generateFsmId()
		context.AutoStart = if params.AutoStart ~= nil then params.AutoStart else context.AutoStart
		if params.InitialState ~= nil then
			context.InitialState = params.InitialState
		end
		table.insert(orchestrator.CreatedMachines, params)
		return self:CreateFSM(params.StateMachineClass, context)
	end

	function orchestrator.ServerCommandEntity(entityId: string, commandName: string, ...: any)
		table.insert(self.commands, {
			EntityId = entityId,
			Command = commandName,
			Args = packArgs(...),
			Time = os.clock(),
		})
		return true
	end

	function orchestrator.GetModule(name: string)
		if self._modules[name] ~= nil then
			return self._modules[name]
		end

		local replicatedStorage = getService("ReplicatedStorage")
		if replicatedStorage then
			local ok, sharedFolder = pcall(function()
				return replicatedStorage:FindFirstChild("shared")
			end)
			if ok and sharedFolder then
				local foundOk, moduleScript = pcall(function()
					return sharedFolder:FindFirstChild(name)
				end)
				if foundOk and isModuleScript(moduleScript) then
					local result = requireFromModule(moduleScript)
					self._modules[name] = result
					return result
				end
			end
		end

		return nil
	end

	function orchestrator.RegisterModule(name: string, moduleValue: any)
		self._modules[name] = moduleValue
		return moduleValue
	end

	function orchestrator.FireEventBus(eventName: string, ...: any)
		table.insert(self.events, {
			Event = eventName,
			Args = packArgs(...),
			Time = os.clock(),
		})
		return true
	end

	orchestrator.Scheduler = {
		Frame = 0,
		Step = function(_scheduler, count: number?)
			self:StepFrames(count or 1)
		end,
	}

	self._orchestrator = orchestrator
	return self
end

function MockFramework:_syncTransitionsForMachine(machine: any)
	if type(machine) ~= "table" then
		return
	end

	local fsmId = machine.Id or machine.StateMachineId or tostring(machine)
	local history = machine.TransitionHistory
	if type(history) ~= "table" then
		return
	end

	local cursor = self._fsmTransitionCursor[fsmId] or 0
	for index = cursor + 1, #history do
		local entry = history[index]
		if type(entry) == "table" then
			table.insert(self.transitions, {
				From = entry.From,
				To = entry.To,
				FsmId = fsmId,
				Time = entry.Time or os.clock(),
			})
		end
	end
	self._fsmTransitionCursor[fsmId] = #history
end

function MockFramework:_syncAllTransitions()
	for _, machine in pairs(self.stateMachines) do
		self:_syncTransitionsForMachine(machine)
	end
end

function MockFramework:CreateEntity(entityClass: any, entityId: string?, initialData: any?)
	local resolvedEntityId = entityId or generateEntityId()
	local entity = newMockEntity(entityClass, resolvedEntityId, initialData)
	self.entities[resolvedEntityId] = entity
	return entity
end

function MockFramework:CreateFSM(fsmClass: any, context: any?)
	local BaseStateMachine = select(1, getBaseModules())
	local definition = resolveStateMachineDefinition(fsmClass)
	local compiledClass = compileStateMachineClass(BaseStateMachine, definition)
	local ctx = if type(context) == "table" then shallowClone(context) else {}
	local fsmId = ctx.StateMachineId or ctx.Id or generateFsmId()

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
		local startArgs = nil
		if ctx.InitialState ~= nil then
			startArgs = { State = ctx.InitialState }
		end
		local ok, err = pcall(function()
			if startArgs then
				machine:Start(startArgs)
			else
				machine:Start()
			end
		end)
		if not ok then
			error(string.format("[MockFramework] Failed to start FSM '%s': %s", tostring(fsmId), tostring(err)))
		end
	end

	self:_syncTransitionsForMachine(machine)
	return machine
end

function MockFramework:GetOrchestrator()
	return self._orchestrator
end

function MockFramework:StepFrames(count: number)
	local BaseStateMachine = select(1, getBaseModules())
	local totalFrames = math.max(0, math.floor(count or 1))
	for _ = 1, totalFrames do
		self._orchestrator.Scheduler.Frame += 1
		BaseStateMachine.Step(FRAME_DT)
		self:_syncAllTransitions()
	end
end

function MockFramework:GetTransitions(fsmId: string?)
	self:_syncAllTransitions()
	if fsmId == nil then
		return self.transitions
	end

	local filtered = {}
	for _, entry in ipairs(self.transitions) do
		if entry.FsmId == fsmId then
			table.insert(filtered, entry)
		end
	end
	return filtered
end

function MockFramework:GetCommands()
	return self.commands
end

function MockFramework:Reset()
	self:_syncAllTransitions()
	for fsmId, machine in pairs(self.stateMachines) do
		pcall(function()
			if type(machine.Destroy) == "function" then
				machine:Destroy()
			elseif type(machine.Cancel) == "function" then
				machine:Cancel()
			end
		end)
		self._fsmTransitionCursor[fsmId] = nil
	end

	table.clear(self.entities)
	table.clear(self.stateMachines)
	table.clear(self.transitions)
	table.clear(self.commands)
	table.clear(self.events)
	table.clear(self._fsmTransitionCursor)
	table.clear(self._orchestrator.CreatedMachines)
	self._orchestrator.Scheduler.Frame = 0
end

return MockFramework
