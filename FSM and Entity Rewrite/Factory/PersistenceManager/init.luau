--!strict
--[[
    @module PersistenceManager
    @author iKrypto
    @version 3.0
    @description Manages entity data persistence lifecycle.
    Lazy-loads the DataStoreSystem to avoid circular dependencies.
]]

local RunService = game:GetService("RunService")
local Enums = require(script.Parent.Enums)
local EntityPersistence = require(script.Parent.EntityPersistence)

local Initialized = false

local PersistenceManager = {
    Controller = nil :: any,
    _logger = nil :: any,
    _settings = nil :: any,
    _core = nil :: any,
}

function PersistenceManager.Initialize(Util: any)
    if not RunService:IsServer() then return end
    if Initialized then return end
    Initialized = true

    EntityPersistence.Initialize(Util)

    PersistenceManager._core = Util
    PersistenceManager._settings = Util.Settings
    PersistenceManager._logger = Util.Logger.new({ Name = "PersistenceManager" })

    PersistenceManager._logger:Log({ Level = Enums.LogLevel.INFO, Message = "PersistenceManager initialized (v3.0)" })
end

local function GetController(): any?
    if PersistenceManager.Controller then
        return PersistenceManager.Controller
    end
    if not PersistenceManager._core then return nil end

    -- Lazy-load DataStoreSystem from Registry
    local Registry = PersistenceManager._core.Factory and PersistenceManager._core.Factory.Registry
    local DataStoreSystem = Registry and Registry.GetEntity("DataStoreSystem")

    if not DataStoreSystem then
        PersistenceManager._logger:Log({
            Level = Enums.LogLevel.WARN,
            Message = "DataStoreSystem not found. Persistence disabled.",
        })
        return nil
    end

    local dsSettings = PersistenceManager._settings.DataStore
    PersistenceManager.Controller = EntityPersistence.new({
        DataStoreName = dsSettings.DataStoreName,
        KeyPrefix = dsSettings.KeyPrefix,
        DataStoreReference = DataStoreSystem,
    })

    return PersistenceManager.Controller
end

local function ValidateRequest()
    assert(Initialized, "PersistenceManager not initialized")
    assert(RunService:IsServer(), "PersistenceManager is server-only")
    assert(PersistenceManager._settings.DataStore.PersistenceEnabled, "Persistence is disabled")
end

function PersistenceManager.LoadState(entity: any, key: string)
    ValidateRequest()

    local controller = GetController()
    if not controller then return end

    if type(entity.SetContext) == "function" then
        entity:SetContext("_PersistenceKey", key)
        entity:SetContext("_IsPersistent", true)
    end

    local success, data = controller:Load(entity, key)
    if success and data then
        PersistenceManager._logger:Log({
            Level = Enums.LogLevel.INFO,
            Message = string.format("Restored state for key '%s'", key),
        })
    end
end

function PersistenceManager.SaveState(entity: any)
    ValidateRequest()

    local controller = GetController()
    if not controller then return end

    -- Access private state through the typed getter
    local getPS = rawget(entity, "_getPrivateState")
    local context = if getPS then getPS().Context else {}

    if not context._IsPersistent then return end
    local key = context._PersistenceKey or context.EntityId
    if not key then return end

    controller:Save(entity, key)
end

return PersistenceManager
