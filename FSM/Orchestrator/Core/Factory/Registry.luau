--!strict
--[=[
	@Name Core/Registry.luau
	@Author iKrypto
	@Description Central registry for tracking active Entity and StateMachine instances
	by ID. Provides registration/unregistration, lookup, object pooling for entity
	reuse, and signals for registration events (EntityRegistered, StateMachineRegistered).
]=]
local Registry = {
	Entities = {} :: { [string]: any },
	StateMachines = {} :: { [string]: any },
	EntityPools = {} :: { [string]: { any } },
}

local Initialized = false
--[=[
	@description Handles `Initialize` for `Registry`.
	@param Util any -- `Util` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Registry.Logger = Util.Logger.new({ Name = "Registry" })

	Registry.Logger:Log({ Level = "INFO", Message = "Registry initialized" })
	
	Registry.EntityRegistered = Util.Signal.new()
	Registry.EntityUnregistered = Util.Signal.new()
	Registry.StateMachineRegistered = Util.Signal.new()
end

local function ValidateRequest()
	assert(Initialized, "Registry not initialized")
	assert(type(Registry.Logger) == "table", "Logger not initialized")
end
--[=[
	@description Handles `RegisterEntity` for `Registry`.
	@param id string -- `id` input parameter.
	@param entity any -- `entity` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.RegisterEntity(id: string, entity: any)
	ValidateRequest()
	Registry.Entities[id] = entity
	Registry.Logger:Log({ Level = "INFO", Message = "Entity registered: " .. id })
	Registry.EntityRegistered:Fire(id, entity)
end
--[=[
	@description Implements `Registry.UnregisterEntity`.
	@param id string -- `id` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.UnregisterEntity(id: string)
	ValidateRequest()
	local entity = Registry.Entities[id]
	Registry.Entities[id] = nil
	Registry.Logger:Log({ Level = "INFO", Message = "Entity unregistered: " .. id })
	if entity and Registry.EntityUnregistered then
		Registry.EntityUnregistered:Fire(id, entity)
	end
end
--[=[
	@description Returns the data produced by `Registry.GetEntity`.
	@param id string -- `id` input parameter.
	@return any? -- Return value produced by the implementation, if any.
]=]

function Registry.GetEntity(id: string): any?
	ValidateRequest()
	return Registry.Entities[id]
end
--[=[
	@description Handles `RegisterStateMachine` for `Registry`.
	@param id string -- `id` input parameter.
	@param stateMachine any -- `stateMachine` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.RegisterStateMachine(id: string, stateMachine: any)
	ValidateRequest()
	Registry.StateMachines[id] = stateMachine
	Registry.Logger:Log({ Level = "INFO", Message = "State Machine registered: " .. id })
	Registry.StateMachineRegistered:Fire(id, stateMachine)
end
--[=[
	@description Implements `Registry.UnregisterStateMachine`.
	@param id string -- `id` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.UnregisterStateMachine(id: string)
	ValidateRequest()
	Registry.StateMachines[id] = nil
	Registry.Logger:Log({ Level = "INFO", Message = "State Machine unregistered: " .. id })
end
--[=[
	@description Returns the data produced by `Registry.GetStateMachine`.
	@param id string -- `id` input parameter.
	@return any? -- Return value produced by the implementation, if any.
]=]

function Registry.GetStateMachine(id: string): any?
	ValidateRequest()
	return Registry.StateMachines[id]
end

--[=[
	@description Adds an entity to the reuse pool keyed by class name.
	Pooled entities can be retrieved later via GetPooledEntity to avoid
	reconstruction overhead.

	@param className string -- Entity class name for pool grouping
	@param entity any -- Entity instance to pool
	@return ()
	@reads None
	@writes Registry.EntityPools[className]
]=]
local MAX_POOL_SIZE = 64
--[=[
	@description Implements `Registry.PoolEntity`.
	@param className string -- `className` input parameter.
	@param entity any -- `entity` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.PoolEntity(className: string, entity: any)
	ValidateRequest()
	if not Registry.EntityPools[className] then
		Registry.EntityPools[className] = {}
	end
	if #Registry.EntityPools[className] >= MAX_POOL_SIZE then
		return
	end
	table.insert(Registry.EntityPools[className], entity)
	Registry.Logger:Log({ Level = "DEBUG", Message = "Entity pooled: " .. className })
end
--[=[
	@description Returns the data produced by `Registry.GetPooledEntity`.
	@param className string -- `className` input parameter.
	@return any? -- Return value produced by the implementation, if any.
]=]

function Registry.GetPooledEntity(className: string): any?
	ValidateRequest()
	local pool = Registry.EntityPools[className]
	if pool and #pool > 0 then
		Registry.Logger:Log({ Level = "DEBUG", Message = "Entity retrieved from pool: " .. className })
		return table.remove(pool)
	end
	Registry.Logger:Log({ Level = "DEBUG", Message = "Entity not found in pool: " .. className })
	return nil
end
--[=[
	@description Returns the data produced by `Registry.GetAllEntities`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.GetAllEntities()
	ValidateRequest()
	return table.clone(Registry.Entities)
end
--[=[
	@description Returns the data produced by `Registry.GetAllStateMachines`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.GetAllStateMachines()	
	ValidateRequest()
	return table.clone(Registry.StateMachines)
end
--[=[
	@description Implements `Registry.Destroy`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function Registry.Destroy()
	if Registry.EntityRegistered then Registry.EntityRegistered:Destroy() end
	if Registry.EntityUnregistered then Registry.EntityUnregistered:Destroy() end
	if Registry.StateMachineRegistered then Registry.StateMachineRegistered:Destroy() end
	Initialized = false
end

return Registry
