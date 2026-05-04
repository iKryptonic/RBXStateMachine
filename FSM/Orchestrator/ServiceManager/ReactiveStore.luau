--!strict


local ReactiveStore = {}
ReactiveStore.__index = ReactiveStore

type StoreSubscription = {
	Key: string?,
	Handler: (key: string, newVal: any, oldVal: any) -> (),
	Id: number,
}

local _nextSubId = 0


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


function ReactiveStore:Get(key: string): any
	return self._data[key]
end
--[=[
	@description Updates module state through `ReactiveStore.Set`.
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


function ReactiveStore:GetVersion(): number
	return self._version
end


function ReactiveStore:IsDirty(key: string): boolean
	return self._dirtyKeys[key] == true
end


function ReactiveStore:ClearDirty(key: string?)
	if key then
		self._dirtyKeys[key] = nil
	else
		table.clear(self._dirtyKeys)
	end
end


function ReactiveStore:GetSnapshot(): { [string]: any }
	return table.clone(self._data)
end


function ReactiveStore:Destroy()
	table.clear(self._subscribers)
	table.clear(self._wildcardSubscribers)
	table.clear(self._data)
	table.clear(self._dirtyKeys)
end


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
