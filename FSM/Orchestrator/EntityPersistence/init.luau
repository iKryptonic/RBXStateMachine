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

local Types = require(script.Parent.Types);
local HttpService = game:GetService("HttpService")

local EntityPersistence = {}
--[[ 
    -- @summary Creates a new EntityPersistence controller for the given config.
    -- @param config Types.PersistenceConfig
    -- @return Types.EntityPersistence
]]
local function makeKey(prefix: string?, key: string): string
	if prefix and prefix ~= "" then
		return prefix .. ":" .. key
	end
	return key
end

--[[
    @summary Encodes data and metadata into a JSON payload for storage.
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
    @summary Decodes a JSON payload into data and metadata.
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
    @summary Creates a new EntityPersistence controller for the given config.
    @param config PersistenceConfig
    @return EntityPersistence
]]
function EntityPersistence.new(config: Types.PersistenceConfig): Types.EntityPersistence
	assert(config and config.DataStoreName, "EntityPersistence.new requires DataStoreName")
	assert(config and config.DataStoreHandler, "EntityPersistence.new requires DataStoreHandler")

	local ds = config.DataStoreHandler.get(config.DataStoreName, config.Scope)
	if config.EnableRetry ~= nil then
		ds:EnableRetry(config.EnableRetry)
	end
	if config.RetryConfig then
		ds:SetRetryConfig(config.RetryConfig)
	end

	local controller: Types.EntityPersistence = {} :: any

    --[[
        @summary Saves the entity's serialized data to the datastore under the given key.
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
			return false, "SerializeFailed: " .. tostring(payloadOrErr)
		end

		local success, _, err = ds:SetAsync(makeKey(config.KeyPrefix, key), payloadOrErr)
		if not success then
			return false, err or "DatastoreFail"
		end
		return true, nil
	end

    --[[
        @summary Loads the entity's data from the datastore under the given key and deserializes it.
        @param entity any
        @param key string
        @return (boolean, { [string]: any }?, string?)
    ]]
	function controller:Load(entity: any, key: string)
		local ok, raw, err = ds:GetAsync(makeKey(config.KeyPrefix, key))
		if not ok then
			return false, nil, err or "DatastoreFail"
		end
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
		return true, data, nil
	end

    --[[
        @summary Updates the entity's data in the datastore under the given key.
        @param key string
        @param mutateFn (data: { [string]: any }) -> { [string]: any }
        @return (boolean, string?)
    ]]
	function controller:Update(key: string, mutateFn: (data: { [string]: any }) -> { [string]: any })
		local success, _, err = ds:UpdateAsync(makeKey(config.KeyPrefix, key), function(old)
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
		if not success then
			return false, err or "DatastoreFail"
		end
		return true, nil
	end

    --[[
        @summary Deletes the entity's data from the datastore under the given key.
        @param key string
        @return (boolean, string?)
    ]]
	function controller:Delete(key: string)
		local success, _, err = ds:RemoveAsync(makeKey(config.KeyPrefix, key))
		if not success then
			return false, err or "DatastoreFail"
		end
		return true, nil
	end

	return controller
end

return EntityPersistence
