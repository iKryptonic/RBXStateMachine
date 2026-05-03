--!strict
--[=[
	@module Signal
	@description Defines the `Signal` module and its exported API.
]=]

local Signal = {}
Signal.__index = Signal
--[=[
	@description Implements `Signal.new`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function Signal.new(): any
	local self = setmetatable({
		_handlers = {},
	}, Signal)
	return (self :: any)
end
--[=[
	@description Implements `Signal.Connect`.
	@param handler (...any) -> () -- `handler` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Signal:Connect(handler: (...any) -> ()): any
	local connection = {
		_handler = handler,
		_signal = self,
		Disconnect = function(conn: any)
			local signal = conn._signal
			if not signal then return end
			local handlers = signal._handlers
			local index = table.find(handlers, conn)
			if index then
				table.remove(handlers, index)
			end
			conn._handler = nil
			conn._signal = nil
		end,
	}
	table.insert(self._handlers, connection)
	return (connection :: any)	
end
--[=[
	@description Implements `Signal.Once`.
	@param handler (...any) -> () -- `handler` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Signal:Once(handler: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end
--[=[
	@description Implements `Signal.Fire`.
	@param ... any -- `...` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function Signal:Fire(...: any)
	-- Snapshot the handler list so that Disconnect/Destroy during firing is safe
	local handlers = self._handlers
	local snapshot = table.move(handlers, 1, #handlers, 1, table.create(#handlers))
	for i = #snapshot, 1, -1 do
		local conn = snapshot[i]
		if conn and conn._handler then
			task.spawn(conn._handler, ...)
		end
	end
end
--[=[
	@description Implements `Signal.Wait`.
	@param none nil -- This function does not accept explicit parameters.
	@return ...any -- Return value produced by the implementation, if any.
]=]

function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end
--[=[
	@description Implements `Signal.Destroy`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function Signal:Destroy()
	for _, conn in ipairs(self._handlers) do
		conn._signal = nil -- Break reference
	end
	table.clear(self._handlers)
end

return Signal
