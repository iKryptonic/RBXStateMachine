--!strict
--[[
    @module Factory
    @author iKrypto
    @version 3.0
    @description Generic factory for compiling, retrieving, and instantiating
    game classes (Entities and StateMachines).
    
    Changes from v2:
        - Uses _getPrivateState() accessor instead of broken _privateProperties clone
        - Pooled entity path no longer shadows entityId
        - Replication rate-limit loop simplified
]]

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Enums = require(script.Parent.Enums)

local Factory = {
    Registry = require(script.Parent.Registry),
    BehaviorTree = require(script.Parent.BehaviorTree),
    PersistenceManager = require(script.Parent.PersistenceManager),
    BaseModules = {
        BaseEntity = require(script.Parent.BaseEntity),
        BaseStateMachine = require(script.Parent.BaseStateMachine),
    },
}

local Utility: any = nil
local Logger: any = nil
local Initialized = false

local EntityAlias = { "Entity", "Entities" }
local StateMachineAlias = { "StateMachine", "StateMachines", "SM", "FSM" }

local CompiledClasses = {
    StateMachines = {} :: { [string]: any },
    Entities = {} :: { [string]: any },
}

--============================================================================--
-- Helpers
--============================================================================--

local function CreateConfiguration(folder: Folder): { Folder: Folder, Base: any?, TypeName: string? }
    local name = folder.Name
    if table.find(EntityAlias, name) then name = "Entities" end
    if table.find(StateMachineAlias, name) then name = "StateMachines" end
    assert(name == "Entities" or name == "StateMachines", "Invalid config folder: " .. folder:GetFullName())

    local baseName = name == "Entities" and "BaseEntity" or "BaseStateMachine"
    local typeName = name == "Entities" and "Entity" or "StateMachine"
    local base = Factory.BaseModules[baseName]

    if not base then
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "Missing base: " .. baseName })
        return { Folder = folder, Base = nil, TypeName = nil }
    end

    return { Folder = folder, Base = base, TypeName = typeName }
end

local function ResolveClass(category: string, input: any): any?
    if type(input) ~= "string" then return input end
    local ok, result = pcall(Factory.Get, category, input)
    return ok and result or nil
end

local function GetClassName(class: any): string
    if not class then return "Unknown" end
    return (class.Definition and class.Definition.Name) or class.Name or tostring(class)
end

local function CompileClass(name: string, classDef: any, classBase: any): any
    local def = classDef.Definition or classDef
    if not def.Name then def.Name = name end
    if not def.className then def.className = name end

    local Subclass = classBase.Extend(def)

    for k, v in pairs(classDef) do
        if k ~= "Name" and k ~= "Schema" and k ~= "ValidStates" and k ~= "Definition" then
            Subclass[k] = v
        end
    end

    return Subclass
end

local function CompileModule(child: ModuleScript, typeName: string, classBase: any)
    local ok, result = pcall(require, child)
    if not ok or type(result) ~= "table" then
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "Failed to require: " .. child.Name .. " — " .. tostring(result) })
        return
    end

    if result.StaticInit then result.StaticInit(Utility) end

    local configKey = typeName == "Entity" and "Entities" or "StateMachines"
    if not CompiledClasses[configKey] then
        CompiledClasses[configKey] = {}
    end

    local className = result.Name or child.Name
    local compOk, compiled = pcall(CompileClass, className, result, classBase)

    if compOk then
        CompiledClasses[configKey][className] = compiled
        Logger:Log({ Level = Enums.LogLevel.INFO, Message = string.format("Compiled %s: %s", typeName, className) })
    else
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = string.format("Compile failed %s '%s': %s", typeName, className, tostring(compiled)) })
    end
end

--============================================================================--
-- Public API
--============================================================================--

function Factory.Initialize(Util: any)
    if Initialized then return end
    Initialized = true

    Utility = Util
    Logger = Util.Logger.new({ Name = "Factory" })

    -- Initialize sub-modules
    local initList = {
        Factory.BaseModules.BaseEntity,
        Factory.BaseModules.BaseStateMachine,
        Factory.BehaviorTree,
        Factory.Registry,
        Factory.PersistenceManager,
    }
    for _, mod in ipairs(initList) do
        local ok, err = pcall(mod.Initialize, Util)
        if not ok then
            Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "Init failed: " .. tostring(err) })
        end
    end

    -- Auto-discover and compile folders
    for _, obj in ipairs(game:GetDescendants()) do
        if obj:IsA("Folder") then
            if table.find(EntityAlias, obj.Name) or table.find(StateMachineAlias, obj.Name) then
                Factory.CompileFolder(obj)
            end
        end
    end

    Logger:Log({ Level = Enums.LogLevel.INFO, Message = "Factory initialized (v3.0)" })
end

function Factory.Get(typeName: string, name: string): any
    assert(Initialized, "Factory not initialized")
    local configKey = typeName
    if typeName == "Entity" then configKey = "Entities" end
    if typeName == "StateMachine" then configKey = "StateMachines" end

    local category = CompiledClasses[configKey] or CompiledClasses[typeName]
    if not category then
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = string.format("%s category not found", typeName) })
        return nil
    end

    local class = category[name]
    if not class then
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = string.format("%s '%s' not compiled", typeName, name) })
    end
    return class
end

function Factory.GetAll(typeName: string): { [string]: any }?
    assert(Initialized, "Factory not initialized")
    local key = typeName
    if table.find(EntityAlias, key) then key = "Entities" end
    if table.find(StateMachineAlias, key) then key = "StateMachines" end
    return CompiledClasses[key]
end

function Factory.CompileFolder(folder: Folder)
    assert(Initialized, "Factory not initialized")
    local config = CreateConfiguration(folder)
    if not config.Base then return end

    local folders = { config.Folder }
    for _, child in ipairs(config.Folder:GetDescendants()) do
        if child:IsA("Folder") then
            table.insert(folders, child)
        end
    end

    for _, f in ipairs(folders) do
        for _, child in ipairs(f:GetChildren()) do
            if child:IsA("ModuleScript") then
                CompileModule(child, config.TypeName :: string, config.Base)
            end
        end
    end
end

--============================================================================--
-- Entity Creation
--============================================================================--

function Factory.CreateEntity(params: {
    EntityClass: any,
    EntityId: string?,
    Context: { [any]: any }?,
    Persistent: boolean?,
    PersistenceKey: string?,
}): any?
    assert(Initialized, "Factory not initialized")

    local EntityClass = ResolveClass("Entity", params.EntityClass)
    local entityId = params.EntityId or HttpService:GenerateGUID(false)
    local ctx = params.Context or {}
    ctx.EntityId = entityId

    if not EntityClass then
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "Cannot resolve EntityClass for " .. entityId })
        return nil
    end

    -- Check registry
    local existing = Factory.Registry.GetEntity(entityId)
    if existing then return existing end

    local className = GetClassName(EntityClass)

    -- Check pool (FIX: no variable shadowing)
    local pooled = Factory.Registry.GetPooledEntity(className)
    if pooled then
        local ps = rawget(pooled, "_getPrivateState")()
        ps.IsValid = true
        table.clear(ps.Data)
        table.clear(ps.Pending)
        if ctx then
            for k, v in pairs(ctx) do
                ps.Context[k] = v
            end
        end
        ps.Context.EntityId = entityId
        Factory.Registry.RegisterEntity(entityId, pooled)
        return pooled
    end

    -- Create new
    local ok, newEntity = xpcall(function()
        return EntityClass.new({
            Name = className,
            Instance = ctx.Instance,
            OwnerId = ctx.OwnerId,
            Context = ctx,
        })
    end, function(err) return debug.traceback(tostring(err)) end)

    if not ok then
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "Entity creation failed: " .. tostring(newEntity) })
        return nil
    end

    -- Inject context
    if type(newEntity.SetContext) == "function" then
        for k, v in pairs(ctx) do
            if k ~= "Instance" and k ~= "OwnerId" and k ~= "Name" then
                pcall(newEntity.SetContext, newEntity, k, v)
            end
        end
    end

    Factory.Registry.RegisterEntity(entityId, newEntity)

    -- Persistence
    if RunService:IsServer() and params.Persistent and Factory.PersistenceManager then
        pcall(Factory.PersistenceManager.LoadState, newEntity, params.PersistenceKey or entityId)
    end

    -- Destruction cleanup
    newEntity.Destroyed:Connect(function()
        if RunService:IsServer() and params.Persistent and Factory.PersistenceManager then
            pcall(Factory.PersistenceManager.SaveState, newEntity)
        end
        Factory.Registry.UnregisterEntity(entityId)
    end)

    Logger:Log({ Level = Enums.LogLevel.DEBUG, Message = "Created Entity " .. entityId })
    return newEntity
end

--============================================================================--
-- StateMachine Creation
--============================================================================--

function Factory.CreateStateMachine(params: {
    StateMachineClass: any,
    StateMachineId: string?,
    Context: { [any]: any }?,
}): any?
    assert(Initialized, "Factory not initialized")

    local SMClass = ResolveClass("StateMachine", params.StateMachineClass)
    local smId = params.StateMachineId or HttpService:GenerateGUID(false)
    local ctx = params.Context or {}
    ctx.StateMachineId = smId

    if not SMClass then
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "Cannot resolve SMClass for " .. smId })
        return nil
    end

    local existing = Factory.Registry.GetStateMachine(smId)
    if existing then return existing end

    local ok, newSM = xpcall(SMClass.new, function(err) return debug.traceback(tostring(err)) end, ctx)
    if not ok then
        Logger:Log({ Level = Enums.LogLevel.ERROR, Message = "SM creation failed: " .. tostring(newSM) })
        return nil
    end

    Factory.Registry.RegisterStateMachine(smId, newSM)

    local conns = {}
    local function cleanup()
        if Factory.Registry.GetStateMachine(smId) == newSM then
            Factory.Registry.UnregisterStateMachine(smId)
        end
        for i = #conns, 1, -1 do
            conns[i]:Disconnect()
        end
        newSM:Destroy()
    end

    table.insert(conns, newSM.Completed:Connect(cleanup))
    table.insert(conns, newSM.Failed:Connect(cleanup))
    table.insert(conns, newSM.Cancelled:Connect(cleanup))

    Logger:Log({ Level = Enums.LogLevel.DEBUG, Message = "Created SM " .. smId })
    return newSM
end

return Factory
