--!strict
-- @Name Core/Registry.luau
-- @Description Central registry for active Entities and StateMachines.
local Registry = {
	Entities = {} :: { [string]: any },
	StateMachines = {} :: { [string]: any },
	EntityPools = {} :: { [string]: { any } },
}

local Initialized = false

--[[
	@description Initializes the registry.
	@param Logger Logger
]]
function Registry.Initialize(Util)
	if Initialized then return end
	Initialized = true
	Registry.Logger = Util.Logger.new({ Name = "Registry" })

	Registry.Logger:Log({ Level = "INFO", Message = "Registry initialized" })
	
	Registry.EntityRegistered = Util.Signal.new()
	Registry.StateMachineRegistered = Util.Signal.new()
end

local function ValidateRequest()
	assert(Initialized, "Registry not initialized")
	assert(type(Registry.Logger) == "table", "Logger not initialized")
end

--[[
	@description Registers an entity.
	@param id string
	@param entity any
]]
function Registry.RegisterEntity(id: string, entity: any)
	ValidateRequest()
	Registry.Entities[id] = entity
	Registry.Logger:Log({ Level = "INFO", Message = "Entity registered: " .. id })
	Registry.EntityRegistered:Fire(id, entity)
end

--[[
	@description Unregisters an entity.
	@param id string
]]
function Registry.UnregisterEntity(id: string)
	ValidateRequest()
	Registry.Entities[id] = nil
	Registry.Logger:Log({ Level = "INFO", Message = "Entity unregistered: " .. id })
end

--[[
	@description Retrieves an entity by ID.
	@param id string
	@return any?
]]
function Registry.GetEntity(id: string): any?
	ValidateRequest()
	return Registry.Entities[id]
end

--[[
	@description Registers a state machine.
	@param id string
	@param stateMachine any
]]
function Registry.RegisterStateMachine(id: string, stateMachine: any)
	ValidateRequest()
	Registry.StateMachines[id] = stateMachine
	Registry.Logger:Log({ Level = "INFO", Message = "State Machine registered: " .. id })
	Registry.StateMachineRegistered:Fire(id, stateMachine)
end

--[[
	@description Unregisters a state machine.
	@param id string
]]
function Registry.UnregisterStateMachine(id: string)
	ValidateRequest()
	Registry.StateMachines[id] = nil
	Registry.Logger:Log({ Level = "INFO", Message = "State Machine unregistered: " .. id })
end

--[[
	@description Retrieves a state machine by ID.
	@param id string
	@return any?
]]
function Registry.GetStateMachine(id: string): any?
	ValidateRequest()
	return Registry.StateMachines[id]
end

--[[
	@description Adds an entity to the pool.
	@param className string
	@param entity any
]]
function Registry.PoolEntity(className: string, entity: any)
	ValidateRequest()
	if not Registry.EntityPools[className] then
		Registry.EntityPools[className] = {}
	end
	table.insert(Registry.EntityPools[className], entity)
	Registry.Logger:Log({ Level = "DEBUG", Message = "Entity pooled: " .. className })
end

--[[
	@description Retrieves an entity from the pool.
	@param className string
	@return any?
]]
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

--[[
	@description Returns all active entities.
]]
function Registry.GetAllEntities()
	ValidateRequest()
	return Registry.Entities
end

--[[
	@description Returns all active state machines.
]]
function Registry.GetAllStateMachines()	
	ValidateRequest()
	return Registry.StateMachines
end

return Registry
