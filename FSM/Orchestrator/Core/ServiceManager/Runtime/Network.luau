--!strict
--[[
	@Name Network
	@Author iKrypto
	@Description Network state helpers providing circuit breaker logic and
	disconnection tracking for the ServiceManager polling loop.
]]

local Network = {}

--[[
	@description Sets the network disconnected state and updates the sidebar UI.
	Clears ping when entering disconnected state.
	@param this any -- ServiceManager instance.
	@param isDisconnected boolean -- Whether the connection is lost.
	@param reason string? -- Optional human-readable error reason.
	@return ()
]]
function Network.SetDisconnected(this: any, isDisconnected: boolean, reason: string?)
	this.Network.IsDisconnected = isDisconnected
	this.Network.LastError = reason
	if isDisconnected then
		this.Ping = nil
	end
	this:UpdateSideBar()
end

--[[
	@description Records a network failure, increments the failure counter, and
	opens the circuit breaker (5s cooldown) after 3 consecutive failures.
	@param this any -- ServiceManager instance.
	@param err string? -- Optional error message.
	@return ()
]]
function Network.RecordFailure(this: any, err: string?)
	this.Network.Failures += 1
	this.Network.LastError = err
	if this.Network.Failures >= 3 then
		this.Network.CircuitOpenUntil = os.clock() + 5
		if not this.Network.IsDisconnected then
			Network.SetDisconnected(this, true, err)
			this:Toast("Connection unstable. Pausing sync for 5s.", "Warning")
		end
	end
end

--[[
	@description Records a successful network call, resets failure counter,
	and closes the circuit breaker if it was open.
	@param this any -- ServiceManager instance.
	@return ()
]]
function Network.RecordSuccess(this: any)
	this.Network.Failures = 0
	this.Network.CircuitOpenUntil = 0
	if this.Network.IsDisconnected then
		Network.SetDisconnected(this, false, nil)
		this:Toast("Connection restored.", "Success")
	end
end

return Network
