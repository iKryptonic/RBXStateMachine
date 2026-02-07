--!strict
-- @Name ModeToggleFSM
-- @Author iKrypto
-- @Description State Machine for managing client/server mode transitions.

local ModeToggleFSM = {
	Definition = {
		Name = "ModeToggleFSM",
		ValidStates = { "Client", "Server", "SwitchingToClient", "SwitchingToServer" },
		InitialState = "Client",
		Priority = 7  -- High priority for mode changes
	}
}

--[[
	@description Registers Client, Server, SwitchingToServer, and SwitchingToClient states.
	Switching states clear all cached data, reset sync state, show a loading overlay,
	and trigger an immediate fetch when switching to server mode.
]]
function ModeToggleFSM:RegisterStates()
	
	-- State: Client
	self:AddState("Client", {
		OnEnter = function(fsm)
			fsm.Context.CurrentMode = "client"
			
			-- Update sidebar entity if available
			if fsm.Context.SidebarEntity then
				fsm.Context.SidebarEntity.Mode = "client"
			end
		end,
		OnHeartbeat = function(fsm, dt)
			-- Check for mode toggle request
			if fsm.Context.TargetMode == "server" then
				fsm:ChangeState({ Name = "SwitchingToServer" })
			end
		end
	})
	
	-- State: Server
	self:AddState("Server", {
		OnEnter = function(fsm)
			fsm.Context.CurrentMode = "server"
			
			-- Update sidebar entity if available
			if fsm.Context.SidebarEntity then
				fsm.Context.SidebarEntity.Mode = "server"
			end
		end,
		OnHeartbeat = function(fsm, dt)
			-- Check for mode toggle request
			if fsm.Context.TargetMode == "client" then
				fsm:ChangeState({ Name = "SwitchingToClient" })
			end
		end
	})
	
	-- State: SwitchingToServer
	self:AddState("SwitchingToServer", {
		OnEnter = function(fsm)
			local sm = fsm.Context.ServiceManager
			if not sm then return end
			
			fsm.Logger:Log({ Level = "INFO", Message = "[ModeToggleFSM] Switching to server mode" })
			
			-- Set switching flag
			sm.ContextSwitching = true
			sm.ContextSwitchDeadline = os.clock() + 2.0
			
			-- Clear sync state
			sm.HasInitialSync = false
			sm.ReplicationMode = nil
			sm.Ping = nil
			
			-- Clear server data snapshots
			if sm.ServerData and sm.ServerData.Scheduler then
				sm.ServerData.Scheduler.Tasks = {}
				sm.ServerData.Scheduler.History = {}
				sm.ServerData.Scheduler.Settings = {}
				sm.ServerData.Scheduler.Logger = { History = {} }
				sm.ServerData.Scheduler.LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 }
				sm.ServerData.Scheduler.PerformanceManager.Stats = {}
			end
			
			if sm.ServerData and sm.ServerData.FSM then
				sm.ServerData.FSM.StateMachines = {}
				sm.ServerData.FSM.Entities = {}
				sm.ServerData.FSM.Settings = {}
				sm.ServerData.FSM.History = {}
				sm.ServerData.FSM.Logs = { History = {} }
			end
			
			-- Clear cached data
			sm.ArchivedEntities = {}
			sm.ArchivedFSMs = {}
			sm.ArchivedTasks = {}
			sm.LastClientTasks = {}
			sm.LastStateMachines = {}
			sm.LastEntities = {}
			
			-- Show loading overlay
			if fsm.Context.SetLoadingOverlay then
				fsm.Context.SetLoadingOverlay(sm, true, "SWITCHING TO SERVER...")
			end
			
			-- Transition complete
			fsm.Context.TargetMode = nil
			fsm:ChangeState({ Name = "Server" })
			
			-- Trigger immediate fetch if ConnectionFSM available
			if fsm.Context.ConnectionFSM then
				task.defer(function()
					fsm.Context.ConnectionFSM:PerformFetch()
				end)
			end
		end
	})
	
	-- State: SwitchingToClient
	self:AddState("SwitchingToClient", {
		OnEnter = function(fsm)
			local sm = fsm.Context.ServiceManager
			if not sm then return end
			
			fsm.Logger:Log({ Level = "INFO", Message = "[ModeToggleFSM] Switching to client mode" })
			
			-- Set switching flag
			sm.ContextSwitching = true
			sm.ContextSwitchDeadline = os.clock() + 2.0
			
			-- Clear sync state
			sm.HasInitialSync = false
			sm.ReplicationMode = nil
			sm.Ping = nil
			
			-- Clear server data snapshots (same as switching to server)
			if sm.ServerData and sm.ServerData.Scheduler then
				sm.ServerData.Scheduler.Tasks = {}
				sm.ServerData.Scheduler.History = {}
				sm.ServerData.Scheduler.Settings = {}
				sm.ServerData.Scheduler.Logger = { History = {} }
				sm.ServerData.Scheduler.LastFrameStats = { FrameTime = 0, TaskCount = 0, Budget = 0 }
				sm.ServerData.Scheduler.PerformanceManager.Stats = {}
			end
			
			if sm.ServerData and sm.ServerData.FSM then
				sm.ServerData.FSM.StateMachines = {}
				sm.ServerData.FSM.Entities = {}
				sm.ServerData.FSM.Settings = {}
				sm.ServerData.FSM.History = {}
				sm.ServerData.FSM.Logs = { History = {} }
			end
			
			-- Clear cached data
			sm.ArchivedEntities = {}
			sm.ArchivedFSMs = {}
			sm.ArchivedTasks = {}
			sm.LastClientTasks = {}
			sm.LastStateMachines = {}
			sm.LastEntities = {}
			
			-- Show loading overlay
			if fsm.Context.SetLoadingOverlay then
				fsm.Context.SetLoadingOverlay(sm, true, "SWITCHING TO CLIENT...")
			end
			
			-- Transition complete
			fsm.Context.TargetMode = nil
			fsm:ChangeState({ Name = "Client" })
		end
	})
end

return ModeToggleFSM
