--!strict
--[=[
	@module ConnectionBag
	@description Defines the `ConnectionBag` module and its exported API.
]=]

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
--[=[
	@description Implements `ConnectionBag.new`.
	@param none nil -- This function does not accept explicit parameters.
	@return ConnectionBagInstance -- Return value produced by the implementation, if any.
]=]

function ConnectionBag.new(): ConnectionBagInstance
	local self = setmetatable({
		_items = {} :: { any },
		_count = 0,
	}, ConnectionBag)
	return self :: any
end
--[=[
	@description Implements `ConnectionBag.Add`.
	@param item any -- `item` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ConnectionBag:Add(item: any): any
	if item == nil then return item end
	table.insert(self._items, item)
	self._count += 1
	return item
end
--[=[
	@description Implements `ConnectionBag.AddTween`.
	@param tween Tween -- `tween` input parameter.
	@return Tween -- Return value produced by the implementation, if any.
]=]

function ConnectionBag:AddTween(tween: Tween): Tween
	self:Add(tween)
	return tween
end
--[=[
	@description Implements `ConnectionBag.AddThread`.
	@param thread thread -- `thread` input parameter.
	@return thread -- Return value produced by the implementation, if any.
]=]

function ConnectionBag:AddThread(thread: thread): thread
	self:Add(thread)
	return thread
end
--[=[
	@description Implements `ConnectionBag.DisconnectAll`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
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
	@description Implements `ConnectionBag.Count`.
	@param none nil -- This function does not accept explicit parameters.
	@return number -- Return value produced by the implementation, if any.
]=]

function ConnectionBag:Count(): number
	return self._count
end
--[=[
	@description Returns whether `ConnectionBag` is empty.
	@param none nil -- This function does not accept explicit parameters.
	@return boolean -- Return value produced by the implementation, if any.
]=]

function ConnectionBag:IsEmpty(): boolean
	return self._count == 0
end

return ConnectionBag
