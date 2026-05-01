--!strict
--[[
    @module Registry
    @author iKrypto
    @version 3.0
    @description Central registry for active Entities, StateMachines, and object pools.
]]

local Enums = require(script.Parent.Enums)

local Registry = {
    Entities = {} :: { [string]: any },
    StateMachines = {} :: { [string]: any },
    EntityPools = {} :: { [string]: { any } },
}

local Initialized = false
local Logger: any = nil
local Signal: any = nil

function Registry.Initialize(Util: any)
    if Initialized then return end
    Initialized = true
    Logger = Util.Logger.new({ Name = "Registry" })
    Signal = Util.Signal

    Registry.EntityRegistered = Signal.new()
    Registry.StateMachineRegistered = Signal.new()

    Logger:Log({ Level = Enums.LogLevel.INFO, Message = "Registry initialized (v3.0)" })
end

local function ValidateRequest()
    assert(Initialized, "Registry not initialized")
end

-- Entity operations

function Registry.RegisterEntity(id: string, entity: any)
    ValidateRequest()
    Registry.Entities[id] = entity
    Registry.EntityRegistered:Fire(id, entity)
    Logger:Log({ Level = Enums.LogLevel.DEBUG, Message = "Entity registered: " .. id })
end

function Registry.UnregisterEntity(id: string)
    ValidateRequest()
    Registry.Entities[id] = nil
    Logger:Log({ Level = Enums.LogLevel.DEBUG, Message = "Entity unregistered: " .. id })
end

function Registry.GetEntity(id: string): any?
    ValidateRequest()
    return Registry.Entities[id]
end

function Registry.GetAllEntities(): { [string]: any }
    ValidateRequest()
    return Registry.Entities
end

-- StateMachine operations

function Registry.RegisterStateMachine(id: string, sm: any)
    ValidateRequest()
    Registry.StateMachines[id] = sm
    Registry.StateMachineRegistered:Fire(id, sm)
    Logger:Log({ Level = Enums.LogLevel.DEBUG, Message = "SM registered: " .. id })
end

function Registry.UnregisterStateMachine(id: string)
    ValidateRequest()
    Registry.StateMachines[id] = nil
    Logger:Log({ Level = Enums.LogLevel.DEBUG, Message = "SM unregistered: " .. id })
end

function Registry.GetStateMachine(id: string): any?
    ValidateRequest()
    return Registry.StateMachines[id]
end

function Registry.GetAllStateMachines(): { [string]: any }
    ValidateRequest()
    return Registry.StateMachines
end

-- Object Pooling

function Registry.PoolEntity(className: string, entity: any)
    ValidateRequest()
    if not Registry.EntityPools[className] then
        Registry.EntityPools[className] = {}
    end
    table.insert(Registry.EntityPools[className], entity)
    Logger:Log({ Level = Enums.LogLevel.DEBUG, Message = "Pooled: " .. className })
end

function Registry.GetPooledEntity(className: string): any?
    ValidateRequest()
    local pool = Registry.EntityPools[className]
    if pool and #pool > 0 then
        return table.remove(pool)
    end
    return nil
end

return Registry
