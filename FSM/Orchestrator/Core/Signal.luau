--!strict


local Signal = {}
Signal.__index = Signal


function Signal.new(): any
	local self = setmetatable({
		_handlers = {},
	}, Signal)
	return (self :: any)
end


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


function Signal:Once(handler: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end
--[=[
	@description Dispatches an event to every currently connected handler. The handler list is snapshotted before iteration so listeners may disconnect themselves or destroy the signal during this emission without skipping other callbacks. Each handler is resumed asynchronously with `task.spawn`.
	@param ... any -- Payload values forwarded to every active connection for this fire.
	@reads self._handlers
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


function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end


function Signal:Destroy()
	for _, conn in ipairs(self._handlers) do
		conn._signal = nil -- Break reference
	end
	table.clear(self._handlers)
end

return Signal
