--!strict
--[=[
	@module ReactiveStore
	@description Reactive key-value store that notifies subscribers on value change,
	marks keys dirty for deferred flush, and supports atomic batched updates.
	Used by ServiceManager as the source-of-truth for nexus state such as the
	active mode, current subsystem, and live connection status.
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
	@description Creates a new `ReactiveStore`.
	Allocates `_data` from an optional shallow clone of `initialData`, initialises
	`_subscribers`, `_wildcardSubscribers`, `_dirtyKeys`, and `_batchedChanges`
	tables, and sets `_version = 0` and `_batchDepth = 0`.
	@param initialData { [string]: any }? -- Optional initial key-value pairs copied into the store at construction time.
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
	@description Returns the current stored value for `key`, or nil if absent.
	Read-only; does not affect version, dirty state, or subscriber notifications.
	@param key string -- The store key whose value to retrieve.
]=]

function ReactiveStore:Get(key: string): any
	return self._data[key]
end
--[=[
	@description Writes `value` to `key`. No-ops when the value is reference-equal to the current one.
	On a genuine change: stores the value in `_data`, increments `_version`, marks `key` dirty in
	`_dirtyKeys`. Inside a `BatchUpdate`, enqueues a change record and skips immediate notification;
	otherwise calls `_Notify` directly.
	@param key string -- The store key to write.
	@param value any -- The new value; notification fires only when it differs from the stored value.
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
--[=[
	@description Registers `handler` to be called whenever `key` changes.
	Passing nil subscribes to all key changes (wildcard). Handlers are spawned via `task.spawn`
	so a failing handler cannot block others. Stores the subscription in `_subscribers` (keyed)
	or `_wildcardSubscribers` (wildcard). Returns an unsubscribe function that removes this handler.
	@param key string? -- Key to watch, or nil for all keys.
	@param handler (key: string, newVal: any, oldVal: any) -> () -- Invoked with both old and new values.
]=]

function ReactiveStore:GetVersion(): number
	return self._version
end
--[=[
	@description Returns the monotonically increasing change counter.
	Increments once per successful `Set` call. Consumers can snapshot the version
	to detect whether any writes occurred between two checkpoints.
]=]

function ReactiveStore:IsDirty(key: string): boolean
	return self._dirtyKeys[key] == true
end
--[=[
	@description Returns true if `key` was written via `Set` since the last `ClearDirty` call.
	The dirty flag is set synchronously before notification, so it is safe to check inside a subscriber.
	@param key string -- The store key to test.
]=]

function ReactiveStore:ClearDirty(key: string?)
	if key then
		self._dirtyKeys[key] = nil
	else
		table.clear(self._dirtyKeys)
	end
end
--[=[
	@description Clears the dirty flag for `key`, or for every key when called without an argument.
	Typically called by the renderer after consuming dirty state to avoid redundant re-renders.
	@param key string? -- Key whose dirty flag to clear. Omit to clear all dirty flags at once.
]=]

function ReactiveStore:GetSnapshot(): { [string]: any }
	return table.clone(self._data)
end
--[=[
	@description Returns a shallow clone of the entire `_data` table.
	Mutating the snapshot does not affect the live store.
	Useful for diffing state or iterating all keys without holding a live reference.
]=]

function ReactiveStore:Destroy()
	table.clear(self._subscribers)
	table.clear(self._wildcardSubscribers)
	table.clear(self._data)
	table.clear(self._dirtyKeys)
end
--[=[
	@description Clears all subscribers, data, and dirty state. Disconnects all subscriptions.
	Called during ServiceManager teardown. The store must not be used after `Destroy`.
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
--[=[
	@description Internal notification dispatch. Spawns key-specific subscribers matching `key`,
	then all wildcard subscribers. Each handler runs in its own task so a crash in one
	does not block the others.
	@param key string -- The key that changed.
	@param newVal any -- The value now stored under `key`.
	@param oldVal any -- The value previously stored under `key`.
]=]

return ReactiveStore
