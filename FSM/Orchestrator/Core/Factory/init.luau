--!strict
--[=[
	@Name Factory
	@Author iKrypto
	@Description Generic factory for compiling, managing, and instantiating game classes
	(Entities and StateMachines). Handles folder-based auto-compilation, class resolution,
	entity creation with Registry integration, persistence loading, replication wiring,
	and FSM lifecycle management.

	@usage
	-- Creating an Entity:
	local entity = Factory.CreateEntity({
		EntityClass = "Door",
		EntityId = "door-123",
		Context = { Position = Vector3.new(0, 0, 0) },
		Persistent = true,
	})

	-- Creating a StateMachine:
	local fsm = Factory.CreateStateMachine({
		StateMachineClass = "DoorFSM",
		StateMachineId = "door-fsm-123",
		Context = { EntityRef = entity },
	})
]=]

local Factory = {
	Registry = require(script.Registry),
	BehaviorTree = require(script.BehaviorTree),
	PersistenceManager = require(script.PersistenceManager),
	BaseModules = {
		BaseEntity = require(script.BaseEntity),
		BaseStateMachine = require(script.BaseStateMachine),
	}
};

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Utility, Logger, Initialized

local EntityAlias = {"Entity", "Entities"}
local StateMachineAlias = {"StateMachine", "StateMachines", "SM", "FSM"}

--[=[
	@description Creates a folder configuration descriptor from a Folder instance.
	Determines whether the folder contains Entities or StateMachines based on its
	name (alias-matched), and associates the appropriate base module.

	@param configurationFolder Folder -- The folder to configure
	@return { Folder: Folder, Base: any?, TypeName: string? }
	@reads EntityAlias, StateMachineAlias, Factory.BaseModules
	@writes None
]=]
local function CreateConfiguration(configurationFolder: Folder)
	assert(configurationFolder ~= nil, "Configuration folder is nil")
	
	local configurationName = configurationFolder.Name
	if table.find(EntityAlias, configurationName) then configurationName = "Entities" end
	if table.find(StateMachineAlias, configurationName) then configurationName = "StateMachines" end
	assert(configurationName == "Entities" or configurationName == "StateMachines", "Invalid configuration folder: " .. configurationFolder:GetFullName())

	local baseName = (configurationName == "Entities" and "BaseEntity") or "BaseStateMachine"
	local typeName = (configurationName == "Entities" and "Entity") or "StateMachine"
	
	local baseModule = Factory.BaseModules[baseName]

	if not baseModule then
		Logger:Log({ Level = "ERROR", Message = string.format("Base '%s' missing in %s. Check your configuration. Expected %s, found %s", baseName, script.Name, baseName, tostring(baseModule)) })
		return { Folder = configurationFolder, Base = nil }
	end
	
	Logger:Log({ Level = "INFO", Message = string.format("Loaded folder: %s", configurationFolder:GetFullName()) })

	return {
		Folder = configurationFolder,
		Base = baseModule,
		TypeName = typeName
	}
end

--[=[
	@description Resolves a class definition from a string name or returns the
	object if it's already a class table. Looks up via `Factory.Get()`.

	@param category "Entity" | "StateMachine" -- The class category
	@param input any -- Class name (string) or class table
	@return any? -- Resolved class table, or nil if not found
	@reads CompiledClasses (via Factory.Get)
	@writes None
]=]
local function ResolveClass(category: "Entity" | "StateMachine", input: any): any?
	if type(input) ~= "string" then return input end

	-- Try ClassFactory
	if Factory.Get then
		local ok, result = pcall(function() 
			return Factory.Get(category, input) 
		end)
		if ok and result then return result end
	end
	
	return nil
end

--[=[
	@description Returns the display name of a class table/definition.

	@param class any -- Class table or definition
	@return string -- Class name or "Unknown"
	@reads class.Definition.Name, class.Name
	@writes None
]=]
local function GetClassName(class: any): string
	if not class then return "Unknown" end
	return (class.Definition and class.Definition.Name) or class.Name or tostring(class)
end

-- Configuration Map
local CompiledClasses = {
	StateMachines = {},
	Entities = {}
};
--[=[
	@description Handles `Initialize` for `Factory`.
	@param Util any -- `Util` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Factory.Initialize(Util)
	if Initialized then return end
	Initialized = true

	local Initializable = {
		Factory.BaseModules.BaseEntity,
		Factory.BaseModules.BaseStateMachine,
		Factory.BehaviorTree,
		Factory.Registry,
		Factory.PersistenceManager
	}
	
	Utility = Util
	Logger = Util.Logger.new({ Name = "Factory" })

	for _, module in Initializable do
		local Success, Result = pcall(module.Initialize, Util)
		if not Success then
			Logger:Log({ Level = "ERROR", Message = string.format("Failed to initialize %s: %s", tostring(module), tostring(Result)) })
		end
	end

	-- Initialize Configurations
	local GameObjects = game:GetDescendants()
	for _, object in GameObjects do
		if object:IsA("Folder") then
			if table.find(EntityAlias, object.Name) or table.find(StateMachineAlias, object.Name) then
				Factory.CompileFolder(object)
			end
		end
	end
	Logger:Log({ Level = "INFO", Message = "Factory initialized" })
end
--[=[
	@description Returns the data produced by `Factory.Get`.
	@param typeName string -- `typeName` input parameter.
	@param name string -- `name` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Factory.Get(typeName: string, name: string): any
	assert(Initialized, "Factory not initialized")
	-- Process aliases: Entity -> Entities, StateMachine -> StateMachines
	local configKey = typeName
	if typeName == "Entity" then configKey = "Entities" end
	if typeName == "StateMachine" then configKey = "StateMachines" end

	local category = CompiledClasses[configKey]
	if not category then 
		-- Fallback check
		category = CompiledClasses[typeName]
	end

	if not category then
		Logger:Log({ Level = "ERROR", Message = `[CompiledClass] {typeName} '{name}' is not registered or compiled.` })
		return nil
	end

	return category[name] or Logger:Log({ Level = "ERROR", Message = `[SubClass] {typeName} '{name}' is not registered or compiled.` })
end
--[=[
	@description Returns the data produced by `Factory.GetAll`.
	@param typeName string -- `typeName` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Factory.GetAll(typeName: string): any
	assert(Initialized, "Factory not initialized")
	local configKey = typeName
	if table.find(EntityAlias, configKey) then configKey = "Entities" end
	if table.find(StateMachineAlias, configKey) then configKey = "StateMachines" end
	
	local category = CompiledClasses[configKey]
	if not category then Logger:Log({ Level = "ERROR", Message = string.format("[GetAll] %s '%s' is not registered or compiled.", typeName, configKey) }) end
	return category
end

--[=[
	@description Compiles a raw definition into a proper subclass using the
	base's `.Extend()` method, then mixes in any extra methods/properties
	from the definition table.

	@param name string -- Class name
	@param classDef any -- Raw definition table (may have a nested .Definition)
	@param classBase any -- Base class (BaseEntity or BaseStateMachine)
	@return () (stores result in CompiledClasses via CompileModule)
	@reads classDef.Definition
	@writes None (caller stores result)
]=]
local function CompileClass(name: string, classDef: any, classBase: any)
	assert(Initialized, "Factory not initialized")

	local effectiveDefinition = if classDef.Definition
		then table.clone(classDef.Definition)
		else table.clone(classDef)

	-- Ensure classDef has the name
	if not effectiveDefinition.Name then effectiveDefinition.Name = name end
	-- Ensure classDef has className (required by BaseStateMachine.Extend)
	if not effectiveDefinition.className then effectiveDefinition.className = name end

	-- Create the subclass using Base.Extend
	-- The classDef itself is expected to contain methods and properties
	-- We pass classDef as the "extensionParams" to Extend. 
	-- Note: BaseEntity.Extend / BaseStateMachine.Extend expect { Name, Schema/ValidStates, etc }
	-- They return a "Subclass" table. We then need to mixin the rest of classDef into that Subclass.

	local Subclass = classBase.Extend(effectiveDefinition)

	-- Mixin methods from the definition to the subclass
	for k, v in pairs(classDef) do
		if k ~= "Name" and k ~= "Schema" and k ~= "ValidStates" and k ~= "Definition" then
			Subclass[k] = v
		end
	end

	return Subclass
end

--[=[
	@description Compiles a ModuleScript into a proper subclass using the base's
	`.Extend()` method. Requires the module, calls `StaticInit` if present,
	and stores the compiled class in `CompiledClasses`.

	@param child ModuleScript -- The module to compile
	@param typeName string -- "Entity" or "StateMachine"
	@param classBase any -- Base class (BaseEntity or BaseStateMachine)
	@return ()
	@reads child (via require)
	@writes CompiledClasses
]=]
local function CompileModule(child: ModuleScript, typeName: string, classBase: any)
	local success, result = pcall(require, child)
	if success and type(result) == "table" then
		-- Wrap StaticInit / Initialize in pcall: a throwing static initializer
		-- must NOT abort Factory.Initialize and leave the orchestrator in a
		-- half-bootstrapped state. Log + skip and let other modules compile.
		if result.StaticInit then
			local okInit, errInit = pcall(result.StaticInit, Utility)
			if not okInit then
				Logger:Log({ Level = "ERROR", Message = string.format("StaticInit failed for '%s': %s", child.Name, tostring(errInit)) })
			end
		elseif result.Initialize then
			-- NOTE: this `Initialize` fallback predates StaticInit and is
			-- ambiguous (per-instance hook vs module-level init). Kept for
			-- backwards compat but pcall'd defensively.
			local okInit, errInit = pcall(result.Initialize, Utility)
			if not okInit then
				Logger:Log({ Level = "ERROR", Message = string.format("Initialize failed for '%s': %s", child.Name, tostring(errInit)) })
			end
		end

		-- Resolve storage key
		local configKey = typeName
		if typeName == "Entity" then configKey = "Entities" end
		if typeName == "StateMachine" then configKey = "StateMachines" end

		if not CompiledClasses[configKey] then
			Logger:Log({ Level = "WARN", Message = string.format("%s '%s' storage missing.", typeName, child.Name) })
			CompiledClasses[configKey] = {}
		end

		-- The ModuleScript return value IS the definition
		local className = result.Name or child.Name
		local compileSuccess, compiledClass = pcall(CompileClass, className, result, classBase)

		if compileSuccess then
			CompiledClasses[configKey][className] = compiledClass
			Logger:Log({ Level = "INFO", Message = string.format("Compiled %s: %s", typeName, className) })
		else
			Logger:Log({ Level = "ERROR", Message = string.format("Failed to compile %s '%s': %s", typeName, className, tostring(compiledClass)) })
		end
	else
		Logger:Log({ Level = "ERROR", Message = string.format("Failed to require '%s' or invalid return type: %s", child.Name, tostring(result)) })
	end
end
--[=[
	@description Implements `Factory.CompileFolder`.
	@param configurationFolder Folder -- `configurationFolder` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Factory.CompileFolder(configurationFolder: Folder)
	assert(Initialized, "Factory not initialized")
	
	local FolderConfig = CreateConfiguration(configurationFolder)
	if not FolderConfig.Base then return end

	-- Allow nested folders
	local Folders = {FolderConfig.Folder}
	for _, folderChild in FolderConfig.Folder:GetDescendants() do
		if folderChild:IsA("Folder") then
			Folders[#Folders + 1] = folderChild
		end
	end
	
	for _, folder in pairs(Folders) do
		for _, folderChild in folder:GetChildren() do
			if folderChild:IsA("ModuleScript") then
				CompileModule(folderChild, FolderConfig.TypeName, FolderConfig.Base)
			end
		end
	end
end
--[=[
	@description Creates the result managed by `Factory.CreateEntity`.
	@param params { EntityClass: any, EntityId: string?, Context: {any}?, Persistent: boolean?, PersistenceKey: string?, InitialData: { [string]: any }? } -- `params` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Factory.CreateEntity(params: { EntityClass: any, EntityId: string?, Context: {any}?, Persistent: boolean?, PersistenceKey: string?, InitialData: { [string]: any }? })
assert(Initialized, "Factory not initialized")
local EntityClass = ResolveClass("Entity", params.EntityClass)
local entityId = params.EntityId or HttpService:GenerateGUID(false)
local entityContext = if params.Context then table.clone(params.Context) else {}
entityContext.EntityId = entityId

if not EntityClass then
Logger:Log({ Level = "ERROR", Message = "Failed to resolve EntityClass for " .. tostring(entityId) })
return nil
end

local existing = Factory.Registry.GetEntity(entityId)
if existing then
Logger:Log({
Level = "WARN",
Message = string.format(
"CreateEntity('%s'): entity already exists. Returning existing instance. "
.. "New params (Context, InitialData) are NOT applied. Use a unique EntityId "
.. "or call Factory.GetEntity('%s') explicitly.",
entityId, entityId),
})
return existing
end

local entityClassName = GetClassName(EntityClass)

local function getLiveEntityId(entity)
return (entity._privateProperties and entity._privateProperties.Context and entity._privateProperties.Context.EntityId) or entityId
end

local function broadcastEntityCreated(entity)
if not (RunService:IsServer() and Utility.NetworkManager) then return end
local sanitizedInitial = {} :: { [string]: any }
local schema = (entity.GetValidProperties and entity:GetValidProperties()) or {}
for k, v in pairs(entity._privateProperties.Data) do
local def = schema[k]
if def and def.Replicate then
sanitizedInitial[k] = v
end
end
sanitizedInitial._v = entity._privateProperties.Version
local liveId = getLiveEntityId(entity)
Utility.NetworkManager.BroadcastEntityCommand(liveId, "OnEntityCreated", {
EntityId = liveId,
EntityClassName = entityClassName,
InitialData = sanitizedInitial,
})
end

local function wireEntityLifecycle(entity)
local lifecycleToken = entity._privateProperties._lifecycleToken
local stateConn
if RunService:IsServer() then
local ReplicationState = {
Pending = {} :: { [string]: any },
Processing = false,
LastSent = nil,
}

stateConn = entity.StateUpdated:Connect(function(changes)
if not changes then return end
if not entity._privateProperties or not entity._privateProperties.IsValid then return end
if entity._privateProperties._lifecycleToken ~= lifecycleToken then return end

local schema = entity:GetValidProperties()
local entityReplication = entity.Definition and entity.Definition.Replication
if entityReplication and entityReplication.Enabled == false then return end

local entityRateLimit = (entityReplication and entityReplication.RateLimit) or 0
local processNow = {}
local processLater = {}

for key, value in pairs(changes) do
if key == "_v" then continue end
local def = schema[key]
if not def or not def.Replicate then
continue
end

if entityRateLimit > 0 then
ReplicationState.Pending[key] = value
processLater[key] = true
else
processNow[key] = value
end
end

if next(processNow) and Utility.NetworkManager then
processNow._v = entity.Version
Utility.NetworkManager.BroadcastEntityUpdate(getLiveEntityId(entity), processNow)
end

if next(processLater) and not ReplicationState.Processing then
ReplicationState.Processing = true
task.spawn(function()
while next(ReplicationState.Pending) do
if not entity._privateProperties or not entity._privateProperties.IsValid then
table.clear(ReplicationState.Pending)
break
end
if entity._privateProperties._lifecycleToken ~= lifecycleToken then
table.clear(ReplicationState.Pending)
break
end

local now = os.clock()
local packet = {}
local lastSent = ReplicationState.LastSent or 0
local interval = 1 / entityRateLimit

if (now - lastSent) >= interval then
for key, data in pairs(ReplicationState.Pending) do
packet[key] = data
ReplicationState.Pending[key] = nil
end
ReplicationState.LastSent = now
end

if next(packet) and Utility.NetworkManager then
packet._v = entity.Version
Utility.NetworkManager.BroadcastEntityUpdate(getLiveEntityId(entity), packet)
end

task.wait(1 / 60)
end
ReplicationState.Processing = false
end)
end

if entity._privateProperties and entity._privateProperties.Persistent and Factory.PersistenceManager and next(changes) then
	-- Debounce persistent saves: wait 2 seconds after last change before saving
	local pp = entity._privateProperties
	pp._pendingSaveToken = (pp._pendingSaveToken or 0) + 1
	local saveToken = pp._pendingSaveToken
	task.delay(2, function()
		if pp._pendingSaveToken == saveToken and pp.IsValid and pp._lifecycleToken == lifecycleToken then
			pcall(Factory.PersistenceManager.SaveState, entity)
		end
	end)
end
end)

broadcastEntityCreated(entity)
end

entity.Destroyed:Connect(function()
if entity._privateProperties and entity._privateProperties._lifecycleToken ~= lifecycleToken then
return
end
if stateConn then stateConn:Disconnect() end
local liveId = getLiveEntityId(entity)
if RunService:IsServer() and Utility.NetworkManager then
if params.Persistent and Factory.PersistenceManager then
Factory.PersistenceManager.SaveState(entity)
end
Utility.NetworkManager.BroadcastEntityCommand(liveId, "OnEntityDestroyed")
Utility.NetworkManager.UnregisterEntityCommands(liveId)
end
Factory.Registry.UnregisterEntity(liveId)
end)
end

local entity
local pooled = Factory.Registry.GetPooledEntity(entityClassName)
if pooled then
local pp = pooled._privateProperties
pp._lifecycleToken = (pp._lifecycleToken or 0) + 1
pp.IsValid = true
table.clear(pp.Data)
table.clear(pp.Pending)
if pp._pendingKeys then
table.clear(pp._pendingKeys)
else
pp._pendingKeys = {}
end
if pp._cache then table.clear(pp._cache) end
table.clear(pp.Context)
pp.Version = 0
pp.EntityLocked = nil
pp.Persistent = params.Persistent
if pp._cleanupTasks then table.clear(pp._cleanupTasks) end
if pp._versionHistory then table.clear(pp._versionHistory) end

if pp._stateUpdatedEvent then pp._stateUpdatedEvent:Destroy() end
if pp._entityDestroyedEvent then pp._entityDestroyedEvent:Destroy() end
local Signal = Utility.Signal
pp._stateUpdatedEvent = Signal.new()
pp._entityDestroyedEvent = Signal.new()
pooled.StateUpdated = pp._stateUpdatedEvent
pooled.Destroyed = pp._entityDestroyedEvent

for k, v in pairs(entityContext) do
pp.Context[k] = v
end
pp.Context.EntityId = entityId

if params.InitialData then
for k, v in pairs(params.InitialData) do
if k ~= "_v" then pp.Data[k] = v end
end
if type(params.InitialData._v) == "number" then
pp.Version = params.InitialData._v
end
end

local classGetContext = pp._class and rawget(pp._class, "GetContext")
if type(classGetContext) == "function" then
local ok, rebuiltContext = pcall(classGetContext, pooled, {
Name = entityClassName,
OwnerId = entityContext.OwnerId,
Context = entityContext,
InitialData = params.InitialData,
})
if ok and rebuiltContext then
for contextKey, contextValue in pairs(rebuiltContext) do
pooled:SetContext(contextKey, contextValue)
end
elseif not ok then
Logger:Log({ Level = "WARN", Message = string.format("GetContext failed while reusing Entity %s: %s", entityId, tostring(rebuiltContext)) })
end
end

entity = pooled
else
local success, newEntity = xpcall(function()
return EntityClass.new({
Name = entityClassName,
OwnerId = entityContext.OwnerId,
Context = entityContext,
InitialData = params.InitialData,
})
end, function(err) return debug.traceback(tostring(err)) end)

if not success then
Logger:Log({ Level = "ERROR", Message = "Failed to instantiate Entity " .. entityId .. ": " .. tostring(newEntity) })
return nil
end

newEntity._privateProperties._lifecycleToken = (newEntity._privateProperties._lifecycleToken or 0) + 1
if type((newEntity :: any).SetContext) == "function" then
for k, v in pairs(entityContext) do
if k ~= "OwnerId" and k ~= "Name" then
pcall(function() (newEntity :: any):SetContext(k, v) end)
end
end
end

entity = newEntity
end

Factory.Registry.RegisterEntity(entityId, entity)
entity._privateProperties.Persistent = params.Persistent

if RunService:IsServer() and params.Persistent and Factory.PersistenceManager then
Factory.PersistenceManager.LoadState(entity, params.PersistenceKey or entityId)
Logger:Log({ Level = "INFO", Message = "Loaded state for Entity " .. entityId })
end

wireEntityLifecycle(entity)

Logger:Log({ Level = "DEBUG", Message = "Created Entity " .. entityId })
return entity
end
--[=[
	@description Creates the result managed by `Factory.CreateStateMachine`.
	@param params { StateMachineClass: any, StateMachineId: string?, Context: {any}?, AutoStart: boolean?, InitialState: string? } -- `params` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Factory.CreateStateMachine(params: { StateMachineClass: any, StateMachineId: string?, Context: {any}?, AutoStart: boolean?, InitialState: string? })
	assert(Initialized, "Factory not initialized")
	local StateMachineClass = ResolveClass("StateMachine", params.StateMachineClass)
	local smId = params.StateMachineId or HttpService:GenerateGUID(false)
	local smContext = if params.Context then table.clone(params.Context) else {}
	smContext.StateMachineId = smId

	if not StateMachineClass then
		Logger:Log({ Level = "ERROR", Message = "Failed to resolve StateMachineClass " .. tostring(smId) })
		return nil
	end

	local existing = Factory.Registry.GetStateMachine(smId)
	if existing then
		Logger:Log({
			Level = "WARN",
			Message = string.format(
				"CreateStateMachine('%s'): FSM already exists. Returning existing instance. "
				.. "New params (Context, AutoStart) are NOT applied. Use a unique StateMachineId "
				.. "or call Factory.GetStateMachine('%s') explicitly.",
				smId, smId),
		})
		return existing
	end

	local success, newSM = xpcall(StateMachineClass.new, function(err) return debug.traceback(tostring(err)) end, smContext)

	if not success then
		Logger:Log({ Level = "ERROR", Message = "Failed to instantiate StateMachine " .. smId .. ": " .. tostring(newSM) })
		return nil
	end

	-- Inject self-reference into Context so BehaviorTree leaves and other
	-- consumers can reach the FSM (e.g. RetryBehavior expects context.FSM).
	if newSM and newSM.Context then
		newSM.Context.FSM = newSM
		newSM.Context.StateMachineId = smId
	end

	Factory.Registry.RegisterStateMachine(smId, newSM)

	local connections = {};
	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true
		if Factory.Registry.GetStateMachine(smId) == newSM then
			Factory.Registry.UnregisterStateMachine(smId)
		end
		-- Disconnect local listeners first back-to-front
		for i = #connections, 1, -1 do
			connections[i]:Disconnect()
		end

		newSM:Destroy()
	end

	connections[#connections + 1] = newSM.Completed:Connect(cleanup)
	connections[#connections + 1] = newSM.Failed:Connect(cleanup)
	connections[#connections + 1] = newSM.Cancelled:Connect(cleanup)

	-- Replicate state changes if Server
	if RunService:IsServer() and Utility.Settings.ServiceManager.Enabled then
		connections[#connections + 1] = newSM.StateChanged:Connect(function(newState, oldState)
			if not Utility.NetworkManager then return end
			Utility.NetworkManager.BroadcastEntityCommand("SyncClient", smId, "ApplyStateMachineStateChanged", newState)
		end)
	end

	-- Auto-start unless caller opts out. Without this, the FSM stays inactive
	-- (IsActive=false) and Step is gated, so OnEnter for the InitialState is
	-- never fired. Persistence/DataStore flows would hang forever.
	if params.AutoStart ~= false and type(newSM.Start) == "function" then
		local startParams = nil
		if params.InitialState then
			startParams = { State = params.InitialState }
		end
		local ok, err = pcall(function()
			if startParams then newSM:Start(startParams) else newSM:Start() end
		end)
		if not ok then
			Logger:Log({ Level = "ERROR", Message = "Failed to auto-start " .. smId .. ": " .. tostring(err) })
			cleanup()
			return nil
		end
		if not newSM.IsActive and Factory.Registry.GetStateMachine(smId) == newSM then
			Logger:Log({ Level = "ERROR", Message = "StateMachine " .. smId .. " never entered an active state during auto-start; cleaning it up." })
			cleanup()
			return nil
		end
	end

	Logger:Log({ Level = "DEBUG", Message = "Created StateMachine " .. smId })
	return newSM
end

return Factory
