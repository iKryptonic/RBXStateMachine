--!strict
-- @Name ConnectionStateMachine
-- @Author iKrypto
-- @Description Manages the network connection state and synchronization strategy for the ServiceManager.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local ConnectionStateMachine = {
	Definition = {
		Name = "ConnectionStateMachine",
		InitialState = "Disconnected",
		Schema = {
			-- State Properties
			LastSync = { Type = "number", Persist = false },
			Ping = { Type = "number", Persist = false },
			FetchId = { Type = "number", Persist = false },
			CircuitOpenUntil = { Type = "number", Persist = false },
			Failures = { Type = "number", Persist = false },
			LastError = { Type = "string", Persist = false },
		},
		ValidStates = { "Disconnected", "Connecting", "Connected", "Polling" }
	}
}

-- Helpers
local function defaultTween(instance: Instance, tweenProperties: {[string]: any}, durationSeconds: number?): any
	local info = TweenInfo.new(durationSeconds or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(instance :: any, info, tweenProperties)
	tween:Play()
	return tween
end

-- Methods

function ConnectionStateMachine:ShouldConnect()
	local SM = self.Context.ServiceManager
	return SM and SM.Mode == "server"
end

function ConnectionStateMachine:IsConnected()
	-- Check if we have successful initial sync
	return self.Context.ServiceManager.HasInitialSync
end

function ConnectionStateMachine:ConnectionFailed()
	return self.Failures > 3 -- Example threshold
end

function ConnectionStateMachine:UsePolling()
	return self.Context.ServiceManager.ReplicationMode == "poll"
end

function ConnectionStateMachine:UseEvent()
	return self.Context.ServiceManager.ReplicationMode == "event"
end

function ConnectionStateMachine:StartSyncListener()
	local SM = self.Context.ServiceManager
	SM.Network.IsDisconnected = false
end

function ConnectionStateMachine:StopSyncListener()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

function ConnectionStateMachine:StartPollingLoop()
	local SM = self.Context.ServiceManager
	SM.Network.IsDisconnected = false
	
	self._polling = true
	task.spawn(function()
		while self._polling and self.State == "Polling" do
			if SM.Mode == "server" then
				self:PerformFetch()
			end
			task.wait(SM.RefreshRate or 1)
		end
	end)
end

function ConnectionStateMachine:StopPollingLoop()
	self._polling = false
end

function ConnectionStateMachine:PerformFetch()
	local SM = self.Context.ServiceManager
	local Orchestrator = self.Context.Orchestrator
	
	if not Orchestrator or not Orchestrator.Request then return end
	
	-- Circuit Breaker
	if self.CircuitOpenUntil and os.clock() < self.CircuitOpenUntil then return end
	
	local start = os.clock()
	local success, result = pcall(function()
		return Orchestrator.Request("GetSyncData")
	end)
	
	if success and result then
		self.Failures = 0
		self.Ping = math.round((os.clock() - start) * 1000)
		SM.Ping = self.Ping
		SM.HasInitialSync = true
		
		-- Ingest Data
		if self.Context.ApplySyncData then
			self.Context.ApplySyncData(result)
		end
		
		-- Mode Switch Check: If server pushes us to event mode? 
		-- Usually client initiates mode, but if server has event, we prefer it.
		-- For now, stick to logic: if fetch works, we are happy in Polling or Connecting.
		
		-- Transition to appropriate state if we were just Connecting
		if self.State == "Connecting" then
			if SM.ReplicationMode == "poll" then
				self:ChangeState({ Name = "Polling" })
			else
				self:ChangeState({ Name = "Connected" })
			end
		end
		
	else
		self.Failures = (self.Failures or 0) + 1
		self.LastError = tostring(result)
		SM.Network.LastError = self.LastError
		
		if self.Failures > 3 then
			self.CircuitOpenUntil = os.clock() + 5
			SM.Network.CircuitOpenUntil = self.CircuitOpenUntil
			SM.Network.IsDisconnected = true
			if self.State ~= "Disconnected" then
				self:ChangeState({ Name = "Disconnected" })
			end
		end
	end
end

function ConnectionStateMachine:RegisterStates()
	
	-- STATE: Disconnected
	self:AddState("Disconnected", {
		OnHeartbeat = function(fsm, dt)
			if fsm:ShouldConnect() then
				fsm:ChangeState({ Name = "Connecting" })
			end
		end
	})

	-- STATE: Connecting
	self:AddState("Connecting", {
		OnEnter = function(fsm)
			fsm.Failures = 0
			-- Attempt Connection Logic Inline or via method
			-- Try to locate the event first (Event Mode preference)
			task.spawn(function()
				local remoteEvent = ReplicatedStorage:WaitForChild("OrchestratorEvent", 2)
				if remoteEvent then
					fsm.Context.ServiceManager.ReplicationMode = "event"
					-- Trigger initial fetch to get current state
					fsm:PerformFetch() 
				else
					-- Fallback to polling immediately if no event
					fsm.Context.ServiceManager.ReplicationMode = "poll"
					fsm:PerformFetch()
				end
			end)
		end,
		OnHeartbeat = function(fsm, dt)
			if fsm:IsConnected() then
				fsm:ChangeState({ Name = "Connected" })
			elseif fsm:ConnectionFailed() then
				fsm:ChangeState({ Name = "Disconnected" })
			end
		end
	})

	-- STATE: Connected
	self:AddState("Connected", {
		OnEnter = function(fsm)
			fsm:StartSyncListener()
		end,
		OnExit = function(fsm)
			fsm:StopSyncListener()
		end,
		OnHeartbeat = function(fsm, dt)
			-- Check for connection loss handled by timeouts/pings usually, 
			-- but here we rely on LastSync updates or active checks.
			-- For now, implicit check:
			if fsm:UsePolling() then
				fsm:ChangeState({ Name = "Polling" })
			end
			-- if ConnectionLost logic exists, add here
		end
	})

	-- STATE: Polling
	self:AddState("Polling", {
		OnEnter = function(fsm)
			fsm:StartPollingLoop()
		end,
		OnExit = function(fsm)
			fsm:StopPollingLoop()
		end,
		OnHeartbeat = function(fsm, dt)
			if fsm:UseEvent() then
				fsm:ChangeState({ Name = "Connected" })
			end
			-- if ConnectionLost logic exists, add here
		end
	})

end

function ConnectionStateMachine:OnCleanup()
	self:StopSyncListener()
	self:StopPollingLoop()
end

return ConnectionStateMachine
