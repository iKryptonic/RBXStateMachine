--!strict

local MockEntity = {}

local function shallowClone(source: any): any
	if type(source) ~= "table" then
		return source
	end

	local clone = {}
	for key, value in pairs(source) do
		clone[key] = value
	end
	return clone
end

local function resolveLockBehavior(self: any, behavior: any, lockId: string): boolean
	if type(behavior) == "function" then
		local ok, result = pcall(behavior, lockId, self)
		if ok then
			return result == true
		end
		return false
	end
	if type(behavior) == "boolean" then
		return behavior
	end
	return true
end

local function createMetatable()
	return {
		__index = function(self: any, key: any)
			local method = MockEntity[key]
			if method ~= nil then
				return method
			end

			local rawValue = rawget(self, key)
			if rawValue ~= nil then
				return rawValue
			end

			if key == "Data" then
				return rawget(self, "_data")
			elseif key == "Pending" then
				return rawget(self, "_pending")
			elseif key == "Context" then
				return rawget(self, "_context")
			elseif key == "Logs" then
				return rawget(self, "_logs")
			end

			local pendingKeys = rawget(self, "_pendingKeys")
			local pending = rawget(self, "_pending")
			if pendingKeys ~= nil and pendingKeys[key] then
				return pending[key]
			end

			local data = rawget(self, "_data")
			if data ~= nil and data[key] ~= nil then
				return data[key]
			end

			local context = rawget(self, "_context")
			if context ~= nil and context[key] ~= nil then
				return context[key]
			end

			return nil
		end,
		__newindex = function(self: any, key: any, value: any)
			if type(key) == "string" and string.sub(key, 1, 1) == "_" then
				rawset(self, key, value)
				return
			end

			local pending = rawget(self, "_pending")
			local pendingKeys = rawget(self, "_pendingKeys")
			pending[key] = value
			pendingKeys[key] = true
		end,
	}
end

function MockEntity.new(entityClass: any, entityId: string, initialData: any?): any
	local entity = {
		EntityId = entityId,
		ClassName = entityClass,
		_data = shallowClone(initialData or {}),
		_pending = {},
		_pendingKeys = {},
		_context = {},
		_logs = {},
		_lockBehavior = true,
		_releaseBehavior = nil,
		_updateBehavior = nil,
	}
	return setmetatable(entity, createMetatable())
end

function MockEntity:SetLockBehavior(behavior: any, releaseBehavior: any?)
	if type(behavior) == "table" then
		self._lockBehavior = behavior.Acquire or behavior.acquire or true
		self._releaseBehavior = behavior.Release or behavior.release
		return self
	end

	self._lockBehavior = behavior
	if releaseBehavior ~= nil then
		self._releaseBehavior = releaseBehavior
	end
	return self
end

function MockEntity:SetReleaseBehavior(behavior: any)
	self._releaseBehavior = behavior
	return self
end

function MockEntity:SetUpdateBehavior(behavior: any)
	self._updateBehavior = behavior
	return self
end

function MockEntity:SetCharacter(instance: any)
	self._data.Instance = instance
	return self
end

function MockEntity:SetInstance(instance: any)
	self._data.Instance = instance
	return self
end

function MockEntity:AcquireLock(lockId: string): boolean
	return resolveLockBehavior(self, self._lockBehavior, lockId)
end

function MockEntity:ReleaseLock(lockId: string): boolean
	local behavior = self._releaseBehavior
	if type(behavior) == "function" then
		local ok, result = pcall(behavior, lockId, self)
		if ok then
			return result ~= false
		end
		return false
	end
	if type(behavior) == "boolean" then
		return behavior
	end
	return true
end

function MockEntity:UpdateEntity(lockId: string?): boolean
	for key in pairs(self._pendingKeys) do
		self._data[key] = self._pending[key]
	end
	if type(self._updateBehavior) == "function" then
		local ok, result = pcall(self._updateBehavior, lockId, self)
		if not ok then
			table.clear(self._pending)
			table.clear(self._pendingKeys)
			return false
		end
		table.clear(self._pending)
		table.clear(self._pendingKeys)
		return result ~= false
	end
	if type(self._updateBehavior) == "boolean" then
		local result = self._updateBehavior
		table.clear(self._pending)
		table.clear(self._pendingKeys)
		return result
	end
	if type(self._updateBehavior) == "table" and type(self._updateBehavior.Commit) == "function" then
		local ok, result = pcall(self._updateBehavior.Commit, self._updateBehavior, lockId, self)
		table.clear(self._pending)
		table.clear(self._pendingKeys)
		return ok and result ~= false
	end
	if type(self._updateBehavior) == "table" and type(self._updateBehavior.Commit) == "boolean" then
		local result = self._updateBehavior.Commit
		table.clear(self._pending)
		table.clear(self._pendingKeys)
		return result
	end
	if self._updateBehavior ~= nil and type(self._updateBehavior) == "table" and self._updateBehavior.Return ~= nil then
		local result = self._updateBehavior.Return
		table.clear(self._pending)
		table.clear(self._pendingKeys)
		return result ~= false
	end
	if self._updateBehavior ~= nil and type(self._updateBehavior) == "boolean" then
		local result = self._updateBehavior
		table.clear(self._pending)
		table.clear(self._pendingKeys)
		return result
	end
	if self._updateBehavior ~= nil and type(self._updateBehavior) ~= "nil" then
		local result = self._updateBehavior
		table.clear(self._pending)
		table.clear(self._pendingKeys)
		return result ~= false
	end
	
	table.clear(self._pending)
	table.clear(self._pendingKeys)
	return true
end

function MockEntity:SetContext(key: any, value: any)
	self._context[key] = value
	return value
end

function MockEntity:GetContext(key: any?)
	if key == nil then
		return self._context
	end
	return self._context[key]
end

function MockEntity:Log(entry: any)
	table.insert(self._logs, shallowClone(entry))
	return entry
end

function MockEntity:GetLogs()
	return self._logs
end

return MockEntity
