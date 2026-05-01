--!strict
--[[
    @module EntityPersistence
    @author iKrypto
    @version 3.0
    @description Persistence helper for saving/loading BaseEntity state to DataStore.
    
    Bug fixes from v2:
        - PersistenceConfig type is now properly defined
        - pcall return values for decodePayload are handled correctly
        - Delete() result checking improved
    
    Usage:
        local EP = require(path.to.EntityPersistence)
        EP.Initialize(Util)
        local controller = EP.new({
            DataStoreName = "GameData",
            KeyPrefix = "Door",
            DataStoreReference = myDataStoreWrapper,
        })
        controller:Save(entity, "door_123")
        controller:Load(entity, "door_123")
]]

local HttpService = game:GetService("HttpService")

local Enums = require(script.Parent.Enums)

local EntityPersistence = {}
local Logger: any = nil
local Initialized = false

--============================================================================--
-- Helpers
--============================================================================--

local function makeKey(prefix: string?, key: string): string
    if prefix and prefix ~= "" then
        return prefix .. ":" .. key
    end
    return key
end

local function encodePayload(data: { [string]: any }, meta: { [string]: any }?): string
    return HttpService:JSONEncode({
        version = 1,
        updatedAt = os.time(),
        data = data,
        meta = meta or {},
    })
end

--- FIX: Returns (data, meta) properly. Handles both raw table and JSON string.
local function decodePayload(raw: any): ({ [string]: any }, { [string]: any }?)
    if type(raw) == "table" then
        if raw.data ~= nil then
            return raw.data, raw.meta
        end
        return raw, nil
    end
    local decoded = HttpService:JSONDecode(raw)
    if decoded.data ~= nil then
        return decoded.data, decoded.meta
    end
    return decoded, nil
end

--============================================================================--
-- Module Init
--============================================================================--

function EntityPersistence.Initialize(Util: any)
    if Initialized then return end
    Initialized = true
    Logger = Util.Logger.new({ Name = "EntityPersistence" })
    Logger:Log({ Level = Enums.LogLevel.INFO, Message = "EntityPersistence initialized" })
end

--============================================================================--
-- Constructor
--============================================================================--

--[[
    @description Creates a new EntityPersistence controller.
    @param config { DataStoreName: string, KeyPrefix: string?, DataStoreReference: any }
    @return EntityPersistence controller
]]
function EntityPersistence.new(config: {
    DataStoreName: string,
    KeyPrefix: string?,
    DataStoreReference: any,
}): any
    assert(Initialized, "EntityPersistence not initialized")
    assert(config.DataStoreName, "EntityPersistence.new requires DataStoreName")
    assert(config.DataStoreReference, "EntityPersistence.new requires DataStoreReference")

    local DataStore = config.DataStoreReference
    local controller = {} :: any

    --[[
        @description Saves entity data to the datastore.
        @param entity any
        @param key string
        @param metadata { [string]: any }?
        @return boolean, string?
    ]]
    function controller:Save(entity: any, key: string, metadata: { [string]: any }?): (boolean, string?)
        if not entity or type(entity.Serialize) ~= "function" then
            return false, Enums.PersistenceResult.MissingSerialization
        end

        local data = entity:Serialize()

        local encodeOk, payload = pcall(encodePayload, data, metadata)
        if not encodeOk then
            return false, Enums.PersistenceResult.SerializeFail
        end

        local storeOk, storeErr = pcall(function()
            if DataStore.SetAsync then
                DataStore:SetAsync(config.DataStoreName, makeKey(config.KeyPrefix, key), payload)
            end
        end)
        if not storeOk then
            Logger:Log({
                Level = Enums.LogLevel.ERROR,
                Message = string.format("Save failed for key '%s': %s", key, tostring(storeErr)),
            })
            return false, Enums.PersistenceResult.DataStoreFail
        end

        Logger:Log({ Level = Enums.LogLevel.INFO, Message = string.format("Saved key '%s'", key) })
        return true, nil
    end

    --[[
        @description Loads entity data from the datastore and deserializes it.
        @param entity any
        @param key string
        @return boolean, { [string]: any }?, string?
    ]]
    function controller:Load(entity: any, key: string): (boolean, { [string]: any }?, string?)
        local getOk, raw = pcall(function()
            if DataStore.GetAsync then
                return DataStore:GetAsync(config.DataStoreName, makeKey(config.KeyPrefix, key))
            end
            return nil
        end)

        if not getOk then
            return false, nil, Enums.PersistenceResult.DataStoreFail .. ": " .. tostring(raw)
        end

        if raw == nil then
            return true, nil, nil -- No data stored yet
        end

        -- FIX: Properly unpack pcall + multi-return
        local decodeOk, decodeResult = pcall(function()
            local data, meta = decodePayload(raw)
            return { data = data, meta = meta }
        end)

        if not decodeOk then
            return false, nil, Enums.PersistenceResult.DecodeFail .. ": " .. tostring(decodeResult)
        end

        local data = decodeResult.data

        if entity and type(entity.Deserialize) == "function" then
            entity:Deserialize(data)
        end

        Logger:Log({ Level = Enums.LogLevel.INFO, Message = string.format("Loaded key '%s'", key) })
        return true, data, nil
    end

    --[[
        @description Atomically updates stored data via a mutation function.
        @param key string
        @param mutateFn (data) -> data
        @return boolean, string?
    ]]
    function controller:Update(key: string, mutateFn: (data: { [string]: any }) -> { [string]: any }): (boolean, string?)
        if not DataStore.UpdateAsync then
            return false, "UpdateAsync not supported"
        end

        local ok, err = pcall(function()
            DataStore:UpdateAsync(config.DataStoreName, makeKey(config.KeyPrefix, key), function(old: any)
                local current: { [string]: any } = {}
                local meta: { [string]: any } = {}

                if old ~= nil then
                    local decOk, result = pcall(function()
                        local d, m = decodePayload(old)
                        return { data = d, meta = m }
                    end)
                    if decOk then
                        current = result.data
                        meta = result.meta or {}
                    end
                end

                local nextData = mutateFn(current)
                return encodePayload(nextData, meta)
            end)
        end)

        if not ok then
            return false, Enums.PersistenceResult.DataStoreFail .. ": " .. tostring(err)
        end
        return true, nil
    end

    --[[
        @description Deletes stored data for the given key.
        @param key string
        @return boolean, string?
    ]]
    function controller:Delete(key: string): (boolean, string?)
        local ok, err = pcall(function()
            if DataStore.RemoveAsync then
                DataStore:RemoveAsync(config.DataStoreName, makeKey(config.KeyPrefix, key))
            end
        end)

        if not ok then
            return false, Enums.PersistenceResult.DataStoreFail .. ": " .. tostring(err)
        end

        Logger:Log({ Level = Enums.LogLevel.INFO, Message = string.format("Deleted key '%s'", key) })
        return true, nil
    end

    Logger:Log({
        Level = Enums.LogLevel.INFO,
        Message = string.format("Controller created for '%s'", config.DataStoreName),
    })
    return controller
end

return EntityPersistence
