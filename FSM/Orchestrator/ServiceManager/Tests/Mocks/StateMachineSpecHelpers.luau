--!strict
-- @Name ServiceManager/Tests/Mocks/StateMachineSpecHelpers.luau
-- @Author iKrypto
-- @Description Helpers for state-machine contract specs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StateMachineSpecHelpers = {}

local function matchesAncestorPath(instance: Instance?, ancestorNames: { string }): boolean
	local current = instance
	for _, ancestorName in ipairs(ancestorNames) do
		if not current or current.Name ~= ancestorName then
			return false
		end
		current = current.Parent
	end
	return true
end

local function findModule(moduleName: string, ancestorCandidates: { { string } }): ModuleScript?
	for _, descendant in ipairs(game:GetDescendants()) do
		if descendant:IsA("ModuleScript") and descendant.Name == moduleName then
			for _, candidate in ipairs(ancestorCandidates) do
				if matchesAncestorPath(descendant.Parent, candidate) then
					return descendant
				end
			end
		end
	end
	return nil
end

local function requireNamedModule(moduleName: string, ancestorCandidates: { { string } }): (ModuleScript, any)
	local module = findModule(moduleName, ancestorCandidates)
	assert(module, string.format("Module %s not found in descendants", moduleName))
	local ok, result = pcall(require, module)
	assert(ok, string.format("Failed to require %s: %s", moduleName, tostring(result)))
	return module, result
end

function StateMachineSpecHelpers.requireStateMachine(moduleName: string): any
	local _, result = requireNamedModule(moduleName, {
		{ "StateMachine" },
		{ "StateMachines" },
		{ "StateMachines", "FSM" },
		{ "StateMachine", "FSM" },
		{ "StateMachines", "RBXStateMachine" },
		{ "StateMachines", "FSM", "RBXStateMachine" },
	})
	return result
end

function StateMachineSpecHelpers.requireEntity(moduleName: string): any
	local _, result = requireNamedModule(moduleName, {
		{ "Entities" },
		{ "Entities", "FSM" },
		{ "Entities", "RBXStateMachine" },
		{ "Entities", "FSM", "RBXStateMachine" },
	})
	return result
end

function StateMachineSpecHelpers.captureStates(machineDef: any): { [string]: any }
	local captured = {}
	local proxy: any = setmetatable({}, {
		__index = machineDef,
	})

	function proxy:AddState(name: string, definition: any, transitions: { string }?)
		captured[name] = {
			Definition = if type(definition) == "function" then { OnEnter = definition } else definition,
			Transitions = transitions or {},
		}
	end

	(machineDef.RegisterStates :: any)(proxy)
	return captured
end

function StateMachineSpecHelpers.makeCharacterModel(name: string?): (Model, () -> ())
	local model = Instance.new("Model")
	model.Name = name or "StateMachineSpecCharacter"
	model.Parent = ReplicatedStorage
	return model, function()
		if model.Parent then
			model:Destroy()
		end
	end
end

function StateMachineSpecHelpers.ensureAssets(assetIds: { string }): () -> ()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local createdRoot = false
	if not assets then
		assets = Instance.new("Folder")
		assets.Name = "Assets"
		assets.Parent = ReplicatedStorage
		createdRoot = true
	end

	local createdAssets = {}
	for _, assetId in ipairs(assetIds) do
		if not assets:FindFirstChild(assetId, true) then
			local asset = Instance.new("Folder")
			asset.Name = assetId
			asset.Parent = assets
			table.insert(createdAssets, asset)
		end
	end

	return function()
		for _, asset in ipairs(createdAssets) do
			if asset.Parent then
				asset:Destroy()
			end
		end
		if createdRoot and assets and assets.Parent then
			assets:Destroy()
		end
	end
end

function StateMachineSpecHelpers.makeCharacterEntity(overrides: any?): any
	overrides = overrides or {}
	local entity: any = {
		EntityId = overrides.EntityId or "Char_1",
		PlayerEntityId = overrides.PlayerEntityId or "Player_1",
		Instance = overrides.Instance,
		EquippedRight = overrides.EquippedRight or "",
		EquippedLeft = overrides.EquippedLeft or "",
		EquipLock = overrides.EquipLock or {},
		CombatLock = overrides.CombatLock or false,
		CanMove = if overrides.CanMove ~= nil then overrides.CanMove else true,
		MoveSpeedCap = overrides.MoveSpeedCap or 16,
		MouseLocked = if overrides.MouseLocked ~= nil then overrides.MouseLocked else true,
		Context = overrides.Context or {},
		_lockOwner = overrides._lockOwner,
		_updateCalls = 0,
		_releaseCalls = 0,
		_updateResult = overrides._updateResult,
	}
	for key, value in pairs(overrides) do
		entity[key] = value
	end
	function entity:UpdateEntity(lockId: any)
		self._updateCalls += 1
		self._lastUpdateLockId = lockId
		return self._updateResult
	end
	function entity:AcquireLock(lockId: any)
		if self._lockOwner ~= nil and self._lockOwner ~= lockId then
			return false
		end
		self._lockOwner = lockId
		return true
	end
	function entity:ReleaseLock(lockId: any)
		if self._lockOwner == lockId then
			self._lockOwner = nil
		end
		self._releaseCalls += 1
	end
	function entity:SetContext(key: string, value: any)
		self.Context[key] = value
		self[key] = value
	end
	return entity
end

function StateMachineSpecHelpers.makePlayerEntity(overrides: any?): any
	overrides = overrides or {}
	local entity: any = {
		EntityId = overrides.EntityId or "Player_1",
		Inventory = overrides.Inventory or {},
		BagContents = overrides.BagContents or {},
		Equipped = overrides.Equipped or {},
		WeaponEqp = overrides.WeaponEqp or "",
		Context = overrides.Context or {},
		_updateCalls = 0,
		_updateResult = overrides._updateResult,
	}
	for key, value in pairs(overrides) do
		entity[key] = value
	end
	function entity:UpdateEntity(lockId: any)
		self._updateCalls += 1
		self._lastUpdateLockId = lockId
		return self._updateResult
	end
	function entity:SetContext(key: string, value: any)
		self.Context[key] = value
		self[key] = value
	end
	return entity
end

function StateMachineSpecHelpers.makeOrchestrator(opts: any?): any
	opts = opts or {}
	local orchestrator: any = {
		Entities = opts.entities or {},
		Modules = opts.modules or {},
		CreatedMachines = {},
	}
	function orchestrator.GetEntity(entityId: string)
		return orchestrator.Entities[entityId]
	end
	function orchestrator.GetEntities()
		return orchestrator.Entities
	end
	function orchestrator.GetModule(name: string)
		return orchestrator.Modules[name]
	end
	function orchestrator.CreateStateMachine(def: any)
		table.insert(orchestrator.CreatedMachines, def)
		if type(opts.CreateStateMachine) == "function" then
			return opts.CreateStateMachine(def)
		end
		return nil
	end
	return orchestrator
end

function StateMachineSpecHelpers.makeFSM(orchestrator: any, overrides: any?): any
	overrides = overrides or {}
	local fsm: any = {
		Id = overrides.Id or "FSM_Spec",
		State = overrides.State,
		Context = if typeof(overrides.Context) == "table" then overrides.Context else {},
		WaitSpan = overrides.WaitSpan or 0,
		Failure = overrides.Failure,
		Logs = overrides.Logs or {},
		IsActive = if overrides.IsActive ~= nil then overrides.IsActive else true,
		_managed = {},
	}
	for key, value in pairs(overrides) do
		if key ~= "Context" then
			fsm[key] = value
		end
	end
	function fsm:GetOrchestrator()
		return orchestrator
	end
	function fsm:GetEntity(entityId: string)
		return orchestrator.GetEntity(entityId)
	end
	if type(fsm.Fail) ~= "function" then
		function fsm:Fail(reason: string)
			self.Failure = reason
			self.State = "Failed"
		end
	end
	if type(fsm.Log) ~= "function" then
		function fsm:Log(entry: any)
			table.insert(self.Logs, entry)
		end
	end
	if type(fsm.Manage) ~= "function" then
		function fsm:Manage(resource: any)
			table.insert(self._managed, resource)
			return resource
		end
	end
	if type(fsm.ScheduleTransition) ~= "function" then
		function fsm:ScheduleTransition(seconds: number, targetState: string)
			self._scheduledTransition = {
				Seconds = seconds,
				TargetState = targetState,
			}
		end
	end
	return fsm
end

return StateMachineSpecHelpers
