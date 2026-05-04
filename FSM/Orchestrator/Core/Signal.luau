--!strict


--[=[
	@module Signal
	@description Lightweight, Roblox-compatible signal implementation. Supports persistent connections, one-shot listeners, asynchronous fire, coroutine-yielding wait, and full teardown. Handler snapshotting on `Fire` makes it safe to disconnect or destroy the signal from within a handler.
]=]

local Signal = {}
Signal.__index = Signal


--[=[
	@description Creates a new Signal instance backed by an empty `_handlers` array. The returned object uses `Signal` as its metatable.
	@return Signal -- New Signal with no connected handlers.
]=]

function Signal.new(): any
	local self = setmetatable({
		_handlers = {},
	}, Signal)
	return (self :: any)
end


--[=[
	@description Appends a connection object to `self._handlers` and returns it. The connection exposes a `Disconnect` method that removes itself from the handler list and nils its back-references, making it safe to call more than once.
	@param handler (...any) -> () -- Callback invoked with the payload of each subsequent `Fire`.
	@return Connection -- Connection object with a `Disconnect()` method.
	@writes self._handlers
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
	@description Connects a handler that automatically disconnects itself the first time it fires. Internally wraps the provided handler in a `Connect` call; the returned connection can still be used to cancel the subscription before it fires.
	@param handler (...any) -> () -- Callback invoked at most once with the next fire's payload.
	@return Connection -- Connection that will self-disconnect on first invocation.
	@writes self._handlers
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


--[=[
	@description Suspends the calling coroutine until the next `Fire`. Uses `Once` to register a one-shot listener that resumes the thread via `task.spawn`, then yields with `coroutine.yield`. Returns all values passed to the matching `Fire` call.
	@return ...any -- Payload values forwarded from the next `Fire` call on this signal.
	@reads self._handlers
	@writes self._handlers
]=]

function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end


--[=[
	@description Severs all handler connections and clears the handler table. Iterates `_handlers`, nils the `_signal` back-reference on each entry to break cycles, then calls `table.clear`. Connections that were already stored by callers become inert after this call.
	@writes self._handlers
]=]

function Signal:Destroy()
	for _, conn in ipairs(self._handlers) do
		conn._signal = nil -- Break reference
	end
	table.clear(self._handlers)
end

return Signal
