--!strict
--[=[
	@module ReactiveStore
	@description Defines the `ReactiveStore` module and its exported API.
]=]

local ReactiveStore = {}
ReactiveStore.__index = ReactiveStore

type StoreSubscription = {
	Key: string?,
	Handler: (key: string, newVal: any, oldVal: any) -> (),
	Id: number,
}

local _nextSubId = 0
--[=[
	@description Implements `ReactiveStore.new`.
	@param initialData { [string]: any }? -- `initialData` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ReactiveStore.new(initialData: { [string]: any }?): any
	local self = setmetatable({}, ReactiveStore)
	self._data = initialData and table.clone(initialData) or {}
	self._subscribers = {} :: { StoreSubscription }
	self._wildcardSubscribers = {} :: { StoreSubscription }
	self._dirtyKeys = {} :: { [string]: boolean }
	self._version = 0
	self._batchDepth = 0
	self._batchedChanges = {} :: { { key: string, old: any, new: any } }
	return self
end
--[=[
	@description Returns the data produced by `ReactiveStore.Get`.
	@param key string -- `key` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:Get(key: string): any
	return self._data[key]
end
--[=[
	@description Updates module state through `ReactiveStore.Set`.
	@param key string -- `key` input parameter.
	@param value any -- `value` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:Set(key: string, value: any)
	local old = self._data[key]
	if old == value then return end

	self._data[key] = value
	self._version += 1
	self._dirtyKeys[key] = true

	if self._batchDepth > 0 then
		table.insert(self._batchedChanges, { key = key, old = old, new = value })
		return
	end

	self:_Notify(key, value, old)
end
--[=[
	@description Implements `ReactiveStore.BatchUpdate`.
	@param fn () -> () -- `fn` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:BatchUpdate(fn: () -> ())
	self._batchDepth += 1
	fn()
	self._batchDepth -= 1

	if self._batchDepth == 0 then
		local changes = self._batchedChanges
		self._batchedChanges = {}
		for _, change in ipairs(changes) do
			self:_Notify(change.key, change.new, change.old)
		end
	end
end
--[=[
	@description Implements `ReactiveStore.Subscribe`.
	@param key string? -- `key` input parameter.
	@param handler (key: string, newVal: any, oldVal: any) -> () -- `handler` input parameter.
	@return () -> () -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:Subscribe(key: string?, handler: (key: string, newVal: any, oldVal: any) -> ()): () -> ()
	_nextSubId += 1
	local sub: StoreSubscription = {
		Key = key,
		Handler = handler,
		Id = _nextSubId,
	}

	if key then
		table.insert(self._subscribers, sub)
	else
		table.insert(self._wildcardSubscribers, sub)
	end

	return function()
		local list = key and self._subscribers or self._wildcardSubscribers
		for i, s in ipairs(list) do
			if s.Id == sub.Id then
				table.remove(list, i)
				break
			end
		end
	end
end
--[=[
	@description Returns the data produced by `ReactiveStore.GetVersion`.
	@param none nil -- This function does not accept explicit parameters.
	@return number -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:GetVersion(): number
	return self._version
end
--[=[
	@description Returns whether `ReactiveStore` is dirty.
	@param key string -- `key` input parameter.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:IsDirty(key: string): boolean
	return self._dirtyKeys[key] == true
end
--[=[
	@description Implements `ReactiveStore.ClearDirty`.
	@param key string? -- `key` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:ClearDirty(key: string?)
	if key then
		self._dirtyKeys[key] = nil
	else
		table.clear(self._dirtyKeys)
	end
end
--[=[
	@description Returns the data produced by `ReactiveStore.GetSnapshot`.
	@param none nil -- This function does not accept explicit parameters.
	@return { [string]: any } -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:GetSnapshot(): { [string]: any }
	return table.clone(self._data)
end
--[=[
	@description Implements `ReactiveStore.Destroy`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:Destroy()
	table.clear(self._subscribers)
	table.clear(self._wildcardSubscribers)
	table.clear(self._data)
	table.clear(self._dirtyKeys)
end
--[=[
	@description Implements `ReactiveStore._Notify`.
	@param key string -- `key` input parameter.
	@param newVal any -- `newVal` input parameter.
	@param oldVal any -- `oldVal` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ReactiveStore:_Notify(key: string, newVal: any, oldVal: any)
	-- Key-specific subscribers
	for _, sub in ipairs(self._subscribers) do
		if sub.Key == key then
			task.spawn(sub.Handler, key, newVal, oldVal)
		end
	end
	-- Wildcard subscribers
	for _, sub in ipairs(self._wildcardSubscribers) do
		task.spawn(sub.Handler, key, newVal, oldVal)
	end
end

return ReactiveStore
