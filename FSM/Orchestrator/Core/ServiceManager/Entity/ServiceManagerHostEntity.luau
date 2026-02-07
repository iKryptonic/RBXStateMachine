--!strict
-- @Name ServiceManagerHostEntity
-- @Author iKrypto
-- @Description Server-side entity that exposes diagnostic endpoints and handles remote commands for the ServiceManager.

local RunService = game:GetService("RunService")

-- The Entity Definition
local ServiceManagerHostEntity = {
	Definition = {
		Name = "ServiceManagerHostEntity",
		Schema = {
			-- Schema can be expanded if we want to replicate specific status vars automatically
			-- For now, we mainly use this entity as a controller/manager
			Uptime = { Type = "number", Persist = false },
			Status = { Type = "string", Persist = false },
		}
	}
}

function ServiceManagerHostEntity:GetContext(params: any)
	return {
		Orchestrator = params.Context and params.Context.Orchestrator
	}
end

function ServiceManagerHostEntity:ApplyChanges(changes: { [string]: any })
	-- Visual updates if any (e.g. overhead UI on a physical part? likely none for this system entity)
end

function ServiceManagerHostEntity:OnCleanup()
    -- Cleanup callbacks if necessary (NetworkManager usually handles replacements, but good practice to allow unregistering)
end


function ServiceManagerHostEntity:RegisterServerCallbacks()
    local Orchestrator = self.Orchestrator 
    if not Orchestrator then 
        self:Log({ Level = "ERROR", Message = "Orchestrator context missing in ServiceManagerHostEntity" })
        return 
    end

    local Core = Orchestrator.Core or (Orchestrator.Factory and Orchestrator.Factory.Core) -- Access core if available, or assume Orchestrator has what we need
    -- Note: We might need to access internals. If Orchestrator doesn't expose them, we might need to pass them in Context.
    -- Assuming Orchestrator has references or we use the global 'shared.fsm' if compliant, but prefer passed context.
    
    -- We need access to Factory, Scheduler, Logger.
    local Factory = Orchestrator.Factory
    local Scheduler = Orchestrator.Scheduler
    local Logger = Orchestrator.Logger
    
    -- Helper to fail safe
    local function SafeCall(fn)
        return function(...)
            local s, r = pcall(fn, ...)
            if not s then
                 Logger:Log({ Level = "ERROR", Message = "ServiceManager Callback Error: " .. tostring(r) })
                 return "Internal Server Error"
            end
            return r
        end
    end

    local ServiceManagerCallbacks = {
        ["GetSyncData"] = function(player, ...: any)
            local tsData = nil
            if Scheduler and Scheduler.GetSyncData then
                tsData = Scheduler:GetSyncData()
            end

            local fsmData = {
                StateMachines = {},
                Entities = {},
                Logs = Logger.History,
                History = Orchestrator.History,
                Settings = { Debug = true } -- Placeholder settings
            }

            if Factory and Factory.Registry then
                for id, stateMachine in pairs(Factory.Registry.GetAllStateMachines()) do
                    fsmData.StateMachines[id] = {
                        Name = stateMachine.Name,
                        State = stateMachine.State,
                        Priority = stateMachine.Priority,
                        Context = stateMachine.Context,
                        ValidStates = stateMachine.validStates,
                        Graph = {
                            Transitions = stateMachine._transitions or {},
                            CurrentState = stateMachine.State
                        }
                    }
                end

                for id, entity in pairs(Factory.Registry.GetAllEntities()) do
                    local props = entity._privateProperties or {}
                    fsmData.Entities[id] = {
                        Name = entity.Name or props.Name,
                        IsValid = props.IsValid,
                        OwnerId = props.OwnerId,
                        Data = props.Data
                    };
                end
            end

            return {
                Scheduler = tsData,
                FSM = fsmData
            }
        end,
        ["UpdateSettings"] = function(player, ...: any)
            local section, key, val = ...
            if Scheduler and Scheduler.Settings then
                if section and Scheduler.Settings[section] then
                    Scheduler.Settings[section][key] = val
                else
                    Scheduler.Settings[key] = val
                end
            end
            return "Settings updated."
        end,
        ["FSM"] = function(player, ...)
            local action, id = ...
            if action == "CancelStateMachine" then
                Orchestrator.CancelStateMachine(id)
            elseif action == "RetryStateMachine" then
                Orchestrator.RetryStateMachine(id)
            end
            return "OK"
        end,
        ["ConsoleCommand"] = function(player, cmd)
            if cmd == "ps" or cmd == "stateMachines" then
                local out = ""
                if Factory and Factory.Registry then
                    for id, stateMachine in pairs(Factory.Registry.GetAllStateMachines()) do out = out .. string.format("%s [%s] - %s\n", id, stateMachine.Name or "?", stateMachine.State or "?") end
                end
                if out == "" then out = "No active stateMachines." end
                return out
            elseif cmd == "clearlogs" then 
                 Logger.History = {}; 
                 return "Logs cleared."
            end
            
            -- Forward to Scheduler if not handled
            if Scheduler then
                local tsOut = nil
                if cmd == "ps" or cmd == "tasks" then
                    local out = ""
                    for taskName in pairs(Scheduler.Tasks) do
                        out = out .. tostring(taskName) .. "\n"
                    end
                    if out == "" then out = "No active tasks." end
                    tsOut = out
                end
                if tsOut then return tsOut end
            end
            return "Unknown command (or not handled by FSM/Scheduler)."
        end,
        ["Scheduler"] = function(player, ...: any)
            local action, p1, p2, p3, p4, p5, p6 = ...
            -- Enforce Scheduler security check if available
            if Scheduler and Scheduler.CheckAdmin and not Scheduler:CheckAdmin(player) then
                return "Unauthorized"
            end
            if Scheduler then
                if action == "Schedule" then Scheduler:Schedule(p1)
                elseif action == "Deschedule" then Scheduler:Deschedule(p1)
                elseif action == "ExecuteTask" then Scheduler:ExecuteTask(p1)
                elseif action == "ResetTask" then Scheduler:ResetTask(p1)
                elseif action == "ConsoleCommand" then
                    local cmd = p1
                    if cmd == "ps" then
                        local out = ""
                        for taskName in pairs(Scheduler.Tasks) do
                            out = out .. tostring(taskName) .. "\n"
                        end
                        if out == "" then out = "No active tasks." end
                        return out
                    elseif cmd == "stats" then
                        return "Tasks: " .. tostring(Scheduler:GetTaskCount())
                    elseif cmd == "clearlogs" then
                        Scheduler.Logger.OutputBuffer = {}
                        return "Logs flushed."
                    elseif cmd == "help" then
                        return "Available commands: help, ps, stats, clearlogs"
                    end
                    return "Unknown server command."
                elseif action == "ScheduleTestTask" then
                    Scheduler:Schedule({
                        TaskName = p1,
                        TaskExecutionDelay = p2,
                        IsRecurringTask = p3,
                        Priority = p4,
                        Event = p5,
                        TaskAction = function() print("[SERVER TEST]: " .. tostring(p6)) end
                    })
                end
            end
            return "Unknown command (or not handled by Scheduler)."
        end,
    }

    for CallbackName, CallbackHandler in pairs(ServiceManagerCallbacks) do
        Orchestrator.RegisterServerRequestCallback(CallbackName, SafeCall(CallbackHandler))
    end
end

function ServiceManagerHostEntity:Initialize()
    self.Status = "Initializing"
    
    if RunService:IsServer() then
         self:RegisterServerCallbacks()
         self:Log({ Level = "INFO", Message = "ServiceManager Host Callbacks Registered" })
    end
    
    self.Status = "Running"
    
    -- Keep alive loop or periodic stats update if needed
    self:Manage(RunService.Heartbeat:Connect(function(dt)
        self.Uptime = (self.Uptime or 0) + dt
    end))
end

return ServiceManagerHostEntity
