--!strict
-- @Name Factory.lua
-- @Author iKrypto
-- @Description Generic factory for compiling and retrieving game classes.

local Factory = {
	Registry = require(script.Registry),
	PersistenceManager = require(script.PersistenceManager),
	BaseModules = {
		BaseEntity = require(script.BaseEntity),
		BaseStateMachine = require(script.BaseStateMachine),
	}
};

-- BehaviorTree is optional — don't crash if it doesn't exist
local btOk, btModule = pcall(require, script:FindFirstChild("BehaviorTree"))
Factory.BehaviorTree = btOk and btModule or nil

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Utility, Logger, Initialized

local EntityAlias = {"Entity", "Entities"}
local StateMachineAlias = {"StateMachine", "StateMachines", "SM", "FSM"}

--[[
	@description Creates a configuration for a class type from a folder.
	@param configurationFolder Folder
	@return { Folder: Folder, Base: any }
]]
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

--[[
	@description Helper to resolve a class definition from a string or a class.
	@param category "Entity" | "StateMachine"
	@param input any
	@return any?
]]
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

--[[
	@description Gets the name of a class.
	@param class any
	@return string
]]
local function GetClassName(class: any): string
	if not class then return "Unknown" end
	return (class.Definition and class.Definition.Name) or class.Name or tostring(class)
end

-- Configuration Map
local TYPES = {
};
local CompiledClasses = {
	StateMachines = {},
	Entities = {}
};

--[[
	Initializes the factory.
	@param Util Utility
]]
function Factory.Initialize(Util)
	if Initialized then return end
	Initialized = true

	local Initializable = {
		Factory.BaseModules.BaseEntity,
		Factory.BaseModules.BaseStateMachine,
		Factory.Registry,
		Factory.PersistenceManager
	}
	if Factory.BehaviorTree then
		table.insert(Initializable, Factory.BehaviorTree)
	end
	
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

--[[
    Retrieves a compiled class.
	@param typeName "Entity" | "StateMachine"
	@param name string
	@return any
]]
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

	if not category then Logger:Log({ Level = "ERROR", Message = `[CompiledClass] {typeName} '{name}' is not registered or compiled.` }) end

	return category[name] or Logger:Log({ Level = "ERROR", Message = `[SubClass] {typeName} '{name}' is not registered or compiled.` })
end

--[[
    Returns the compiled classes table for a type.
	Note: the returned table is shared (do not mutate it).
	@param typeName "Entity" | "StateMachine"
	@return any
]]
function Factory.GetAll(typeName: string): any
	assert(Initialized, "Factory not initialized")
	local configKey = typeName
	if table.find(EntityAlias, configKey) then configKey = "Entities" end
	if table.find(StateMachineAlias, configKey) then configKey = "StateMachines" end
	
	local category = CompiledClasses[configKey]
	if not category then Logger:Log({ Level = "ERROR", Message = string.format("[GetAll] %s '%s' is not registered or compiled.", typeName, configKey) }) end
	return category
end

--[[
    Compiles a raw definition into a proper subclass using the base's .Extend method.
	@param name string
	@param classDef any
	@param classBase any
]]
local function CompileClass(name: string, classDef: any, classBase: any)
	assert(Initialized, "Factory not initialized")

	local effectiveDefinition = classDef
	if classDef.Definition then
		effectiveDefinition = classDef.Definition
	end

	-- Clone to avoid mutating the user's original table
	effectiveDefinition = table.clone(effectiveDefinition)

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

--[[
	@description Compiles a ModuleScript into a proper subclass using the base's .Extend method.
	@param child ModuleScript
	@param typeName "Entity" | "StateMachine"
	@param classBase any
	@return boolean
]]
local function CompileModule(child: ModuleScript, typeName: string, classBase: any)
	local success, result = pcall(require, child)
	if success and type(result) == "table" then
		if result.StaticInit then
			result.StaticInit(Utility)
		elseif result.Initialize then
			result.Initialize(Utility)
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

--[[
	Compiles statemachine or entity folders into the registry.
	This is called automatically on initialization, but can be called manually to compile new folders.
]]
function Factory.CompileFolder(configurationFolder: Folder)
	assert(Initialized, "Factory not initialized")
	
	local FolderConfig = CreateConfiguration(configurationFolder)
	if not FolderConfig.Base then return end

	for _, folderChild in FolderConfig.Folder:GetChildren() do
		if folderChild:IsA("ModuleScript") then
			CompileModule(folderChild, FolderConfig.TypeName, FolderConfig.Base)
		end
	end
end

--[[
	@description Creates (or retrieves) a unique Entity instance by ID.
	@param params { EntityClass: any, EntityId: string?, Context: {any}?, Persistent: boolean?, PersistenceKey: string? }
	@return any?
]]
function Factory.CreateEntity(params: { EntityClass: any, EntityId: string?, Context: {any}?, Persistent: boolean?, PersistenceKey: string?, InitialData: { [string]: any }? })
	assert(Initialized, "Factory not initialized")
	local EntityClass = ResolveClass("Entity", params.EntityClass)
	local entityId = params.EntityId or HttpService:GenerateGUID(false)
	local entityContext = params.Context or {}
	entityContext.EntityId = entityId

	if not EntityClass then
		Logger:Log({ Level = "ERROR", Message = "Failed to resolve EntityClass for " .. tostring(entityId) })
		return nil
	end

	-- Check Registry
	local existing = Factory.Registry.GetEntity(entityId)
	if existing then return existing end

	local entityClassName = GetClassName(EntityClass)

	-- Check Pool
	local pooled = Factory.Registry.GetPooledEntity(entityClassName)
	if pooled then
		pooled._privateProperties.IsValid = true
		table.clear(pooled._privateProperties.Data)
		table.clear(pooled._privateProperties.Pending)
		table.clear(pooled._privateProperties._cache)
		table.clear(pooled._privateProperties.Context)
		pooled._privateProperties.Version = 0
		pooled._privateProperties.EntityLocked = false

		-- Reset signals to prevent old listeners from firing
		if pooled._privateProperties._stateUpdatedEvent then
			pooled._privateProperties._stateUpdatedEvent:Destroy()
		end
		if pooled._privateProperties._entityDestroyedEvent then
			pooled._privateProperties._entityDestroyedEvent:Destroy()
		end
		local Signal = Utility.Signal
		pooled._privateProperties._stateUpdatedEvent = Signal.new()
		pooled._privateProperties._entityDestroyedEvent = Signal.new()
		pooled.StateUpdated = pooled._privateProperties._stateUpdatedEvent
		pooled.Destroyed = pooled._privateProperties._entityDestroyedEvent

		if params.Context then
			for k, v in pairs(params.Context) do pooled._privateProperties.Context[k] = v end
		end
		pooled._privateProperties.Context.EntityId = entityId
		-- Restore replicated state if provided
		if params.InitialData then
			for k, v in pairs(params.InitialData) do
				if k ~= "_v" then pooled._privateProperties.Data[k] = v end
			end
			if type(params.InitialData._v) == "number" then
				pooled._privateProperties.Version = params.InitialData._v
			end
		end
		Factory.Registry.RegisterEntity(entityId, pooled)

		if RunService:IsServer() and Utility.NetworkManager then
			pcall(Utility.NetworkManager.BroadcastEntityCommand, entityId, "OnEntityCreated", {
				EntityId = entityId,
				EntityClassName = entityClassName,
				Instance = pooled.Instance,
				InitialData = {}
			})
		end
		return pooled
	end

	local success, newEntity = xpcall(function()
		return EntityClass.new({
			Name = entityClassName,
			Instance = entityContext.Instance,
			OwnerId = entityContext.OwnerId,
			Context = entityContext,
			InitialData = params.InitialData,
		})
	end, function(err) return debug.traceback(tostring(err)) end)

	if not success then
		Logger:Log({ Level = "ERROR", Message = "Failed to instantiate Entity " .. entityId .. ": " .. tostring(newEntity) })
		return nil
	end

	-- Inject Context
	if type((newEntity :: any).SetContext) == "function" then
		for k, v in pairs(entityContext) do
			if k ~= "Instance" and k ~= "OwnerId" and k ~= "Name" then
				pcall(function() (newEntity :: any):SetContext(k, v) end)
			end
		end
	end

	-- Registered
	Factory.Registry.RegisterEntity(entityId, newEntity)

	-- Persistence
	if RunService:IsServer() and params.Persistent and Factory.PersistenceManager then
		Factory.PersistenceManager.LoadState(newEntity, params.PersistenceKey or entityId)
		Logger:Log({ Level = "INFO", Message = "Loaded state for Entity " .. entityId })
	end

	-- Wire up StateUpdated for Replication
	if RunService:IsServer() then
		local ReplicationState = {
			Pending = {} :: { [string]: any },
			Processing = false,
			LastSent = nil,
		}

		newEntity.StateUpdated:Connect(function(changes)
			if not changes then return end;
			if not newEntity._privateProperties.IsValid then return end
			local schema = newEntity:GetValidProperties()
			
			local entityReplication = newEntity.Definition and newEntity.Definition.Replication
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
					ReplicationState.Pending[key] = { Value = value, Rate = entityRateLimit }
					processLater[key] = true
				else
					processNow[key] = value
				end
			end

			-- Send Immediate Updates
			if next(processNow) then
				if Utility.NetworkManager then
					processNow._v = newEntity.Version
					pcall(Utility.NetworkManager.BroadcastEntityUpdate, entityId, processNow)
				end
			end

			-- Start Processing Loop if needed
			if next(processLater) and not ReplicationState.Processing then
				ReplicationState.Processing = true
				task.spawn(function()
					while next(ReplicationState.Pending) do
						if not newEntity._privateProperties.IsValid then
							table.clear(ReplicationState.Pending)
							break
						end
						local now = os.clock()
						local packet = {}
						local lastSent = ReplicationState.LastSent or 0
						local safeRate = math.max(entityRateLimit, 1)
						local interval = 1 / safeRate
						
						if (now - lastSent) >= interval then
							for key, data in pairs(ReplicationState.Pending) do
								packet[key] = data.Value
								ReplicationState.Pending[key] = nil
							end
							ReplicationState.LastSent = now
						end
						
						if next(packet) and Utility.NetworkManager then
							packet._v = newEntity.Version
							pcall(Utility.NetworkManager.BroadcastEntityUpdate, entityId, packet)
						end
						
						task.wait(1/60) 
					end
					ReplicationState.Processing = false
				end)
			end

			-- Auto-save
			if params.Persistent and Factory.PersistenceManager and changes.SaveState then
				pcall(Factory.PersistenceManager.SaveState, newEntity)
			end
		end)

		-- Broadcast Creation — sanitize Data to only include Replicate=true fields
		if Utility.NetworkManager then
			local sanitizedInitial = {} :: { [string]: any }
			local schema = newEntity:GetValidProperties()
			for k, v in pairs(newEntity._privateProperties.Data) do
				local def = schema[k]
				if def and def.Replicate then
					sanitizedInitial[k] = v
				end
			end
			sanitizedInitial._v = newEntity._privateProperties.Version
			pcall(Utility.NetworkManager.BroadcastEntityCommand, entityId, "OnEntityCreated", {
				EntityId = entityId,
				EntityClassName = entityClassName,
				Instance = entityContext.Instance,
				InitialData = sanitizedInitial,
			})
		end
	end

	newEntity.Destroyed:Connect(function()
		if RunService:IsServer() and Utility.NetworkManager then
			-- Final Save
			if params.Persistent and Factory.PersistenceManager then
				pcall(Factory.PersistenceManager.SaveState, newEntity)
			end
			pcall(Utility.NetworkManager.BroadcastEntityCommand, entityId, "OnEntityDestroyed")
			pcall(Utility.NetworkManager.UnregisterEntityCommands, entityId)
		end
		Factory.Registry.UnregisterEntity(entityId)
	end)

	Logger:Log({ Level = "DEBUG", Message = "Created Entity " .. entityId })
	return newEntity
end

--[[
	@description Creates a StateMachine instance.
	@param params { StateMachineClass: any, StateMachineId: string?, Context: {any}? }
	@return any?
]]
function Factory.CreateStateMachine(params: { StateMachineClass: any, StateMachineId: string?, Context: {any}?, AutoStart: boolean?, InitialState: string? })
	assert(Initialized, "Factory not initialized")
	local StateMachineClass = ResolveClass("StateMachine", params.StateMachineClass)
	local smId = params.StateMachineId or HttpService:GenerateGUID(false)
	local smContext = params.Context or {}
	smContext.StateMachineId = smId

	if not StateMachineClass then
		Logger:Log({ Level = "ERROR", Message = "Failed to resolve StateMachineClass " .. tostring(smId) })
		return nil
	end

	local existing = Factory.Registry.GetStateMachine(smId)
	if existing then return existing end

	local success, newSM = xpcall(StateMachineClass.new, function(err) return debug.traceback(tostring(err)) end, smContext)

	if not success then
		Logger:Log({ Level = "ERROR", Message = "Failed to instantiate StateMachine " .. smId .. ": " .. tostring(newSM) })
		return nil
	end

	-- Inject self-reference into Context so BehaviorTree leaves and other
	-- consumers can reach the FSM via context.
	if newSM and newSM.Context then
		newSM.Context.FSM = newSM
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
		newSM.StateChanged:Connect(function(newState, oldState)
			if not Utility.NetworkManager then return end
			Utility.NetworkManager.BroadcastEntityCommand("SyncClient", smId, "ApplyStateMachineStateChanged", newState)
		end)
	end

	-- Auto-start unless caller opts out
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
		end
	end

	Logger:Log({ Level = "DEBUG", Message = "Created StateMachine " .. smId })
	return newSM
end

return Factory