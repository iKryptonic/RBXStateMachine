--!strict
-- @Name Signal
-- @Author iKrypto (inspired by FastSignal)
-- @Description High-performance signal implementation to replace BindableEvents.

local Signal = {}
Signal.__index = Signal

-- @description Creates a new Signal.
-- @returns A new Signal.
function Signal.new(): any
	local self = setmetatable({
		_handlers = {},
	}, Signal)
	return (self :: any)
end

-- @description Connects a handler to the signal.
-- @param handler The handler to connect.
-- @returns A connection object.
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

-- @description Connects a handler to the signal that will only fire once.
-- @param handler The handler to connect.
-- @returns A connection object.
function Signal:Once(handler: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

-- @description Fires the signal with the given arguments.
-- @param ... The arguments to fire the signal with.
-- @returns void
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

-- @description Waits for the signal to fire and returns the arguments.
-- @returns The arguments that the signal was fired with.
function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

-- @description Destroys the signal and all its connections.
-- @returns void
function Signal:Destroy()
	for _, conn in ipairs(self._handlers) do
		conn._signal = nil -- Break reference
	end
	table.clear(self._handlers)
end

return Signal
