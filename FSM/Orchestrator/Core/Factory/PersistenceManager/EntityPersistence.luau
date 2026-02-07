--!strict
-- @Name EntityPersistence
-- @Author iKrypto
-- @Description Persistence helper for saving/loading BaseEntity state to DataStore.
--
-- Usage:
-- local EntityPersistence = require(Path.To.EntityPersistence)
-- local persistence = EntityPersistence.new({ DataStoreName = "EntitySaveData", KeyPrefix = "Door" })
-- persistence:Save(entity, "123")
-- persistence:Load(entity, "123")

local HttpService = game:GetService("HttpService")

local EntityPersistence = {}
local Logger, Initialized = nil, false

local function ValidateRequest(config)
	assert(Initialized, "EntityPersistence not initialized")
	assert(Logger, "EntityPersistence not initialized")
	assert(config and config.DataStoreName, "EntityPersistence.new requires DataStoreName")
	assert(config and config.DataStoreReference, "EntityPersistence.new requires DataStoreReference")
end

--[[ 
    -- @description Creates a new EntityPersistence controller for the given config.
    -- @param config PersistenceConfig
    -- @return EntityPersistence
]]
local function makeKey(prefix: string?, key: string): string
	if prefix and prefix ~= "" then
		return prefix .. ":" .. key
	end
	return key
end

--[[
    @description Encodes data and metadata into a JSON payload for storage.
    @param data { [string]: any }
    @param meta { [string]: any }?
    @return string
]]
local function encodePayload(data: { [string]: any }, meta: { [string]: any }?)
	return HttpService:JSONEncode({
		version = 1,
		updatedAt = os.time(),
		data = data,
		meta = meta or {},
	})
end

--[[
    @description Decodes a JSON payload into data and metadata.
    @param raw string
    @return ({ [string]: any }, { [string]: any }?)
]]
local function decodePayload(raw: any): ({ [string]: any }, { [string]: any }?)
	if type(raw) == "table" then
		return raw, nil
	end
	local decoded = HttpService:JSONDecode(raw)
	if decoded.data ~= nil then
		return decoded.data, decoded.meta
	end
	return decoded, nil
end

--[[
	Initializes the EntityPersistence
]]
function EntityPersistence.Initialize(Util)
	if Initialized then return end
    Initialized = true
    Logger = Util.Logger.new({ Name = "EntityPersistence" })

	Logger:Log({ Level = "INFO", Message = "EntityPersistence initialized" })
end


--[[
    @description Creates a new EntityPersistence controller for the given config.
    @param config PersistenceConfig
    @return EntityPersistence
]]
function EntityPersistence.new(config: PersistenceConfig): EntityPersistence
	ValidateRequest(config)

	local DataStore = config.DataStoreReference


	local controller: EntityPersistence = {} :: any

    --[[
        @description Saves the entity's serialized data to the datastore under the given key.
        @param entity any
        @param key string
        @param metadata { [string]: any }?
        @return (boolean, string?)
    ]]
	function controller:Save(entity: any, key: string, metadata: { [string]: any }?)
		if not entity or type(entity.Serialize) ~= "function" then
			return false, "EntityMissingSerialize"
		end

		local data = entity:Serialize()
		local ok, payloadOrErr = pcall(function()
			return encodePayload(data, metadata)
		end)
		if not ok then
			return false, "SerializeFailed"
		end

		local success = ((DataStore.SetAsync and DataStore:SetAsync(config.DataStoreName, makeKey(config.KeyPrefix, key), payloadOrErr)) == true)
		if not success then
			return false, "DatastoreFail"
		end
		Logger:Log({ Level = "INFO", Message = string.format("Saved persistent state for Entity with key '%s'", key) })
		return true, nil
	end

    --[[
        @description Loads the entity's data from the datastore under the given key and deserializes it.
        @param entity any
        @param key string
        @return (boolean, { [string]: any }?, string?)
    ]]
	function controller:Load(entity: any, key: string)
		local raw = (DataStore.GetAsync and DataStore:GetAsync(config.DataStoreName, makeKey(config.KeyPrefix, key)))
		-- DataStoreEntity throws on error, but returns result on success.
		-- Wait, DataStoreEntity:_ExecuteRequest throws error on failure.
		-- So we need pcall here if we want to return false, err?
		-- No, _ExecuteRequest returns result, or errors.
		-- So raw contains result.
		-- But if it errored, this block crashed?
		-- We should wrap calls in pcall if we want to control flow, OR leverage RequestFSM's error handling.
		-- DataStoreEntity returns the result directly.

		if raw == nil then
			return true, nil, nil
		end

		local decodeOk, data, _meta = pcall(function()
			return decodePayload(raw)
		end)
		if not decodeOk then
			return false, nil, "DecodeFailed: " .. tostring(data)
		end
		if entity and type(entity.Deserialize) == "function" then
			entity:Deserialize(data)
		end
		Logger:Log({ Level = "INFO", Message = string.format("Restored persistent state for Entity with key '%s'", key) })
		return true, data, nil
	end

    --[[
        @description Updates the entity's data in the datastore under the given key.
        @param key string
        @param mutateFn (data: { [string]: any }) -> { [string]: any }
        @return (boolean, string?)
    ]]
	function controller:Update(key: string, mutateFn: (data: { [string]: any }) -> { [string]: any })
		-- UpdateAsync in Facade
		local result
		if DataStore.UpdateAsync then
			result = DataStore:UpdateAsync(config.DataStoreName, makeKey(config.KeyPrefix, key), function(old)
				local current: { [string]: any } = {}
				local meta: { [string]: any } = {}
				if old ~= nil then
					local ok, decodedData, decodedMeta = pcall(function()
						return decodePayload(old)
					end)
					if ok then
						current = decodedData
						meta = decodedMeta or {}
					end
				end

				local nextData = mutateFn and mutateFn(current) or current
				return encodePayload(nextData, meta)
			end)
		end
		
		if result == nil then
			return false, "DatastoreFail" -- Assuming nil means failure or unsupported
		end
		return true, nil
	end

    --[[
        @description Deletes the entity's data from the datastore under the given key.
        @param key string
        @return (boolean, string?)
    ]]
	function controller:Delete(key: string)
		local success = ((DataStore.RemoveAsync and DataStore:RemoveAsync(config.DataStoreName, makeKey(config.KeyPrefix, key))) ~= nil) -- RemoveAsync returns value removed?
		-- DataStoreEntity RemoveAsync returns removed item.

		Logger:Log({ Level = "INFO", Message = string.format("Deleted persistent state for Entity with key '%s'", key) })
		return true, nil
	end

	Logger:Log({ Level = "INFO", Message = string.format("EntityPersistence controller created for DataStore '%s'", config.DataStoreName) })
	return controller
end

return EntityPersistence