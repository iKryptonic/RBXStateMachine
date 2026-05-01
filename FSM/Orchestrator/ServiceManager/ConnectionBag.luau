--!strict
-- @Name ServiceManager/ConnectionBag.luau
-- @Author iKrypto
-- @Description Lifecycle container for connections, tweens, and threads.
-- Subsystems own a bag and call :DisconnectAll() on Destroy() to prevent
-- leaks across drill-downs and subsystem switches.

local ConnectionBag = {}
ConnectionBag.__index = ConnectionBag

export type Disposable = {
	Disconnect: (any) -> ()?,
} | RBXScriptConnection

export type ConnectionBagInstance = {
	Add: (self: ConnectionBagInstance, item: any) -> any,
	AddTween: (self: ConnectionBagInstance, tween: Tween) -> Tween,
	AddThread: (self: ConnectionBagInstance, thread: thread) -> thread,
	DisconnectAll: (self: ConnectionBagInstance) -> (),
	Count: (self: ConnectionBagInstance) -> number,
	IsEmpty: (self: ConnectionBagInstance) -> boolean,
}

function ConnectionBag.new(): ConnectionBagInstance
	local self = setmetatable({
		_items = {} :: { any },
		_count = 0,
	}, ConnectionBag)
	return self :: any
end

--[=[
	Register any disposable for cleanup.
	Accepts: RBXScriptConnection, Tween (will Cancel), thread (will task.cancel),
	or any object exposing :Disconnect() / :Destroy() / :Cancel().
	@param item any — the disposable to register
	@return any — the same item, for chaining
	@reads nothing
	@writes _items, _count
]=]
function ConnectionBag:Add(item: any): any
	if item == nil then return item end
	table.insert(self._items, item)
	self._count += 1
	return item
end

--[=[
	Register a Tween whose Cancel will be called on cleanup.
	@param tween Tween
	@return Tween — the same tween
	@reads nothing
	@writes _items, _count
]=]
function ConnectionBag:AddTween(tween: Tween): Tween
	self:Add(tween)
	return tween
end

--[=[
	Register a thread whose task.cancel will be called on cleanup.
	@param thread thread
	@return thread — the same thread
	@reads nothing
	@writes _items, _count
]=]
function ConnectionBag:AddThread(thread: thread): thread
	self:Add(thread)
	return thread
end

--[=[
	Dispose of all registered items in reverse-add order.
	Safe to call multiple times.
	@reads _items
	@writes _items, _count
]=]
function ConnectionBag:DisconnectAll()
	-- Reverse iteration so tweens get cancelled before their connections
	for i = #self._items, 1, -1 do
		local item = self._items[i]
		pcall(function()
			if typeof(item) == "RBXScriptConnection" then
				item:Disconnect()
			elseif typeof(item) == "thread" then
				task.cancel(item)
			elseif typeof(item) == "Instance" and item:IsA("Tween") then
				item:Cancel()
				item:Destroy()
			elseif type(item) == "table" then
				if type(item.Disconnect) == "function" then
					item:Disconnect()
				elseif type(item.Destroy) == "function" then
					item:Destroy()
				elseif type(item.Cancel) == "function" then
					item:Cancel()
				end
			end
		end)
	end
	table.clear(self._items)
	self._count = 0
end

--[=[
	Number of items currently held by the bag.
	@return number
	@reads _count
]=]
function ConnectionBag:Count(): number
	return self._count
end

--[=[
	True if the bag has no items.
	@return boolean
	@reads _count
]=]
function ConnectionBag:IsEmpty(): boolean
	return self._count == 0
end

return ConnectionBag
