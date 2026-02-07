--!strict
--[[
	@Name ServiceProxy
	@Author iKrypto
	@Description Creates proxy tables that transparently route service calls
	to local services (client mode) or to the server bridge (server mode).
	Uses metatables so page controllers don't need to handle mode differences.
]]

local RS = game:GetService("ReplicatedStorage")

local ServiceProxy = {}

--[[
	@description Creates a mode-aware proxy for the named service.
	In client mode, calls are routed to the real local service.
	In server mode, calls are forwarded via Orchestrator.Request with
	circuit breaker protection.
	@param this any -- ServiceManager instance (provides Mode, Orchestrator, ServerData, Network).
	@param serviceName string -- The service key ("Scheduler" or "FSM").
	@return any -- A proxy table with __index routing.
]]
function ServiceProxy.Create(this: any, serviceName: string): any
	local proxy = {}
	local meta: any = {}

	local function route(action: string, ...)
		local args = table.pack(...)
		if this.Mode == "client" then
			local realService = (this.Orchestrator and this.Orchestrator[serviceName]) or shared[serviceName]
			if serviceName == "Scheduler" and this.Orchestrator and this.Orchestrator.Scheduler then
				realService = this.Orchestrator.Scheduler
			end
			if realService and realService[action] then
				return realService[action](realService, table.unpack(args, 1, args.n))
			end
		else
			if this.Orchestrator and this.Orchestrator.Request then
				if this.Network.CircuitOpenUntil and os.clock() < this.Network.CircuitOpenUntil then
					return nil
				end
				local ok, result = pcall(function()
					return this.Orchestrator.Request(serviceName, action, table.unpack(args, 1, args.n))
				end)
				if ok then
					this:RecordNetworkSuccess()
					return result
				else
					this:RecordNetworkFailure(tostring(result))
					return nil
				end
			end
		end
		return nil
	end

	meta.__index = function(_, key): any
		-- Route specific functions
		if serviceName == "Scheduler" then
			local actions = { "Schedule", "Deschedule", "ExecuteTask", "ResetTask", "ScheduleTestTask", "ConsoleCommand" }
			if table.find(actions, key) then
				return function(_, ...) return route(key, ...) end
			end
		elseif serviceName == "FSM" then
			local actions = { "CancelStateMachine", "FinishStateMachine", "RetryStateMachine" }
			if table.find(actions, key) then
				return function(_, ...) route(key, ...) end
			end
		end

		-- Proxy PerformanceManager for Server Mode
		if key == "PerformanceManager" and this.Mode == "server" then
			return this.ServerData[serviceName].PerformanceManager
		end

		if key == "UpdateSetting" then
			return function(_, section, setting, value)
				if this.Mode == "client" then
					local realService = (this.Orchestrator and this.Orchestrator[serviceName]) or shared[serviceName]
					if serviceName == "Scheduler" and this.Orchestrator and this.Orchestrator.Scheduler then
						realService = this.Orchestrator.Scheduler
					end
					if realService and realService.Settings then
						if section then
							realService.Settings[section][setting] = value
						else
							realService.Settings[setting] = value
						end
						this:Toast("Updated Local Setting", "Success")
					else
						this:Toast("Service Not Found Locally", "Error")
					end
				else
					-- Server Mode: Route via Remote
					if this.Orchestrator and this.Orchestrator.Request then
						task.spawn(function()
							local success, err = pcall(function()
								this.Orchestrator.Request("UpdateSettings", section, setting, value)
							end)
							if success then
								this:RecordNetworkSuccess()
								this:Toast("Updated Server Setting", "Success")
							else
								this:RecordNetworkFailure(tostring(err))
								this:Toast("Update Failed: " .. tostring(err), "Error")
							end
						end)
					else
						this:Toast("Server Remote Not Found", "Error")
					end
					-- Optimistic local update
					local sData = this.ServerData[serviceName]
					if sData and sData.Settings then
						if section then
							sData.Settings[section][setting] = value
						else
							sData.Settings[setting] = value
						end
					end
				end
			end
		end

		-- Fallback to local or server-fetched data
		if this.Mode == "client" then
			local realService = (this.Orchestrator and this.Orchestrator[serviceName]) or shared[serviceName]
			if serviceName == "Scheduler" and this.Orchestrator and this.Orchestrator.Scheduler then
				realService = this.Orchestrator.Scheduler
			end
			return realService and realService[key]
		else
			local serviceData = this.ServerData[serviceName]
			if serviceData then
				if serviceData[key] then
					return serviceData[key]
				end
				-- Specific fallbacks for nested data
				if serviceName == "Scheduler" and serviceData.Tasks and serviceData.Tasks[key] then
					return serviceData.Tasks[key]
				end
				if serviceName == "FSM" and serviceData.StateMachines and serviceData.StateMachines[key] then
					return serviceData.StateMachines[key]
				end
			end
		end
		return nil
	end

	return setmetatable(proxy, meta)
end

return ServiceProxy
