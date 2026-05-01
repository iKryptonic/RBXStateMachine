--!strict
--[[
    @module Signal
    @author iKrypto
    @version 3.0
    @description High-performance signal implementation replacing BindableEvents.
    
    Features:
        - FIFO handler execution order (first connected = first fired)
        - Snapshot-on-fire for safe disconnection during iteration
        - Once() for single-fire connections
        - Wait() for yielding until next fire
        - Proper cleanup via Destroy()
    
    Usage:
        local Signal = require(path.to.Signal)
        local signal = Signal.new()
        
        local conn = signal:Connect(function(value)
            print("Got:", value)
        end)
        
        signal:Fire("hello")
        conn:Disconnect()
        signal:Destroy()
]]

local Signal = {}
Signal.__index = Signal

--[[
    @description Creates a new Signal instance.
    @return Signal
]]
function Signal.new()
    local self = setmetatable({
        _handlers = {} :: { any },
        _destroyed = false,
    }, Signal)
    return self
end

--[[
    @description Connects a handler function to this signal.
    Handlers are invoked in FIFO order (first connected = first called).
    Each handler runs in its own coroutine via task.spawn.
    
    @param handler (...any) -> () -- The callback function
    @return Connection -- An object with a :Disconnect() method
]]
function Signal:Connect(handler: (...any) -> ()): any
    assert(not self._destroyed, "Cannot connect to a destroyed Signal")
    assert(type(handler) == "function", "Signal:Connect expects a function, got " .. type(handler))

    local connection = {
        _handler = handler,
        _signal = self,
        Connected = true,
    }

    function connection.Disconnect(conn: any)
        if not conn.Connected then return end
        conn.Connected = false

        local signal = conn._signal
        if not signal then return end

        local handlers = signal._handlers
        local index = table.find(handlers, conn)
        if index then
            table.remove(handlers, index)
        end
        conn._signal = nil
    end

    table.insert(self._handlers, connection)
    return connection
end

--[[
    @description Connects a handler that automatically disconnects after one invocation.
    
    @param handler (...any) -> () -- The callback function
    @return Connection
]]
function Signal:Once(handler: (...any) -> ()): any
    assert(not self._destroyed, "Cannot connect to a destroyed Signal")

    local connection
    connection = self:Connect(function(...)
        connection:Disconnect()
        handler(...)
    end)
    return connection
end

--[[
    @description Fires the signal, invoking all connected handlers with the given arguments.
    Handlers execute in FIFO order. A snapshot is taken before iteration so
    Disconnect/Destroy calls during firing are safe.
    
    @param ... any -- Arguments passed to each handler
]]
function Signal:Fire(...: any)
    if self._destroyed then return end

    local handlers = self._handlers
    local count = #handlers
    if count == 0 then return end

    -- Snapshot for safe iteration (handlers may disconnect during fire)
    local snapshot = table.move(handlers, 1, count, 1, table.create(count))

    -- FIFO order: iterate 1 → N
    for i = 1, count do
        local conn = snapshot[i]
        if conn and conn.Connected and conn._handler then
            task.spawn(conn._handler, ...)
        end
    end
end

--[[
    @description Yields the current thread until the signal fires.
    Returns the arguments that the signal was fired with.
    
    @return ...any -- The arguments from the next Fire() call
]]
function Signal:Wait(): ...any
    assert(not self._destroyed, "Cannot wait on a destroyed Signal")

    local thread = coroutine.running()
    self:Once(function(...)
        task.spawn(thread, ...)
    end)
    return coroutine.yield()
end

--[[
    @description Returns true if this signal has been destroyed.
    @return boolean
]]
function Signal:IsDestroyed(): boolean
    return self._destroyed
end

--[[
    @description Returns the number of currently connected handlers.
    @return number
]]
function Signal:GetConnectionCount(): number
    return #self._handlers
end

--[[
    @description Destroys the signal, disconnecting all handlers and preventing future use.
]]
function Signal:Destroy()
    if self._destroyed then return end
    self._destroyed = true

    for _, conn in ipairs(self._handlers) do
        conn.Connected = false
        conn._signal = nil
    end
    table.clear(self._handlers)
end

return Signal
