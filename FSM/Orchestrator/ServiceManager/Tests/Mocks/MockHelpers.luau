--!strict

local MockHelpers = {}

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

local function generateEntityId(): string
	entityCounter += 1
	return string.format("MockEntity_%d", entityCounter)
end

local function generateFsmId(): string
	fsmCounter += 1
	return string.format("MockFSM_%d", fsmCounter)
end

local function resolveMock(mockOrEnv: any): any
	if type(mockOrEnv) == "table" and mockOrEnv.Mock ~= nil then
		return mockOrEnv.Mock
	end
	return mockOrEnv
end

local function createCharacterEntity(mockOrEnv: any, entityId: string, data: any?): any
	local mock = resolveMock(mockOrEnv)
	local initial = shallowClone(data or {})
	initial.Health = if initial.Health ~= nil then initial.Health else 100
	initial.MaxHealth = if initial.MaxHealth ~= nil then initial.MaxHealth else 100
	initial.Stamina = if initial.Stamina ~= nil then initial.Stamina else 100
	initial.MaxStamina = if initial.MaxStamina ~= nil then initial.MaxStamina else 100
	initial.Mana = if initial.Mana ~= nil then initial.Mana else 50
	initial.MaxMana = if initial.MaxMana ~= nil then initial.MaxMana else 50
	initial.IsStunned = if initial.IsStunned ~= nil then initial.IsStunned else false
	initial.IsKnocked = if initial.IsKnocked ~= nil then initial.IsKnocked else false
	initial.IsBlocking = if initial.IsBlocking ~= nil then initial.IsBlocking else false
	initial.CanMove = if initial.CanMove ~= nil then initial.CanMove else true
	initial.MoveSpeedCap = if initial.MoveSpeedCap ~= nil then initial.MoveSpeedCap else 16
	initial.EquippedRight = if initial.EquippedRight ~= nil then initial.EquippedRight else ""
	initial.EquippedLeft = if initial.EquippedLeft ~= nil then initial.EquippedLeft else ""
	initial.EquipLock = if typeof(initial.EquipLock) == "table" then shallowClone(initial.EquipLock) else {}
	initial.AbilityCooldowns = if typeof(initial.AbilityCooldowns) == "table" then shallowClone(initial.AbilityCooldowns) else {}
	initial.ActiveStatusEffects = if typeof(initial.ActiveStatusEffects) == "table" then shallowClone(initial.ActiveStatusEffects) else {}
	return mock:CreateEntity("CharacterEntity", entityId, initial)
end

local function createPlayerEntity(mockOrEnv: any, entityId: string, data: any?): any
	local mock = resolveMock(mockOrEnv)
	local initial = shallowClone(data or {})
	initial.Inventory = if typeof(initial.Inventory) == "table" then shallowClone(initial.Inventory) else {}
	initial.BagContents = if typeof(initial.BagContents) == "table" then shallowClone(initial.BagContents) else {}
	initial.Equipped = if typeof(initial.Equipped) == "table" then shallowClone(initial.Equipped) else {}
	initial.WeaponEqp = if initial.WeaponEqp ~= nil then initial.WeaponEqp else ""
	initial.LearnedAbilities = if typeof(initial.LearnedAbilities) == "table" then shallowClone(initial.LearnedAbilities) else {}
	initial.QuickItemSlots = if typeof(initial.QuickItemSlots) == "table" then shallowClone(initial.QuickItemSlots) else { "", "", "", "" }
	return mock:CreateEntity("PlayerEntity", entityId, initial)
end

local function stepFrames(mockOrEnv: any, count: number)
	local mock = resolveMock(mockOrEnv)
	local BaseStateMachine = select(1, getBaseModules())
	local totalFrames = math.max(0, math.floor(count or 1))
	for _ = 1, totalFrames do
		mock._orchestrator.Scheduler.Frame += 1
		BaseStateMachine.Step(FRAME_DT)
		if mock._transitionRecorder then
			mock._transitionRecorder:SyncAll(mock.stateMachines)
		end
	end
end

local function stepUntil(mockOrEnv: any, machine: any, target: any, maxFrames: number?): boolean
	local mock = resolveMock(mockOrEnv)
	local frames = maxFrames or 240
	for _ = 1, frames do
		if type(target) == "string" then
			if machine.State == target then
				return true
			end
		elseif type(target) == "table" then
			if table.find(target, machine.State) then
				return true
			end
		elseif type(target) == "function" then
			if target(machine) then
				return true
			end
		end
		stepFrames(mock, 1)
	end
	return false
end

local function getTransitionSequence(mockOrEnv: any, machine: any): { string }
	local mock = resolveMock(mockOrEnv)
	local transitions = mock:GetTransitions(machine.Id)
	local sequence = {}
	for _, entry in ipairs(transitions) do
		table.insert(sequence, tostring(entry.To))
	end
	return sequence
end

local function containsTransition(mockOrRecorder: any, fromOrExpected: any, toState: any?, fsmId: string?): boolean
	if type(mockOrRecorder) == "table" and type(mockOrRecorder.containsTransition) == "function" then
		return mockOrRecorder:containsTransition(fromOrExpected, toState, fsmId)
	end
	local mock = resolveMock(mockOrRecorder)
	if mock._transitionRecorder then
		return mock._transitionRecorder:containsTransition(fromOrExpected, toState, fsmId)
	end
	return false
end

MockHelpers.FRAME_DT = FRAME_DT
MockHelpers.shallowClone = shallowClone
MockHelpers.packArgs = packArgs
MockHelpers.getService = getService
MockHelpers.isModuleScript = isModuleScript
MockHelpers.findModule = findModule
MockHelpers.requireFromModule = requireFromModule
MockHelpers.getBaseModules = getBaseModules
MockHelpers.compileStateMachineClass = compileStateMachineClass
MockHelpers.resolveStateMachineDefinition = resolveStateMachineDefinition
MockHelpers.generateEntityId = generateEntityId
MockHelpers.generateFsmId = generateFsmId
MockHelpers.CreateCharacterEntity = createCharacterEntity
MockHelpers.CreatePlayerEntity = createPlayerEntity
MockHelpers.StepFrames = stepFrames
MockHelpers.StepUntil = stepUntil
MockHelpers.GetTransitionSequence = getTransitionSequence
MockHelpers.ContainsTransition = containsTransition

return MockHelpers
