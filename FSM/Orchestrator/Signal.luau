--!strict
-- @Name Signal
-- @Author iKrypto (inspired by FastSignal)
-- @Description High-performance signal implementation to replace BindableEvents.

local Types = require(script.Parent.Types)
local Signal = {}
Signal.__index = Signal

-- @summary Creates a new Signal.
-- @returns A new Signal.
function Signal.new(): Types.Signal
	local self = setmetatable({
		_handlers = {},
	}, Signal)
	return (self :: any) :: Types.Signal
end

-- @summary Connects a handler to the signal.
-- @param handler The handler to connect.
-- @returns A connection object.
function Signal:Connect(handler: (...any) -> ()): Types.Connection
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
		end,
	}
	table.insert(self._handlers, connection)
	return (connection :: any) :: Types.Connection
end

-- @summary Connects a handler to the signal that will only fire once.
-- @param handler The handler to connect.
-- @returns A connection object.
function Signal:Once(handler: (...any) -> ()): Types.Connection
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

-- @summary Fires the signal with the given arguments.
-- @param ... The arguments to fire the signal with.
-- @returns void
function Signal:Fire(...: any)
	-- Iterate backwards to allow disconnection during firing
	local handlers = self._handlers
	for i = #handlers, 1, -1 do
		local conn = handlers[i]
		task.spawn(conn._handler, ...)
	end
end

-- @summary Waits for the signal to fire and returns the arguments.
-- @returns The arguments that the signal was fired with.
function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

-- @summary Destroys the signal and all its connections.
-- @returns void
function Signal:Destroy()
	for _, conn in ipairs(self._handlers) do
		conn._signal = nil -- Break reference
	end
	table.clear(self._handlers)
end

return Signal
