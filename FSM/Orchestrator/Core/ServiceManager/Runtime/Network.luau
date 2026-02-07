--!strict

-- Runtime/Network.luau
-- Network state helpers (circuit breaker + disconnected status)

local Network = {}

function Network.SetDisconnected(this: any, isDisconnected: boolean, reason: string?)
	this.Network.IsDisconnected = isDisconnected
	this.Network.LastError = reason
	if isDisconnected then
		this.Ping = nil
	end
	this:UpdateSideBar()
end

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

function Network.RecordSuccess(this: any)
	this.Network.Failures = 0
	this.Network.CircuitOpenUntil = 0
	if this.Network.IsDisconnected then
		Network.SetDisconnected(this, false, nil)
		this:Toast("Connection restored.", "Success")
	end
end

return Network
