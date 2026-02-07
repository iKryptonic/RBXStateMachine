--!strict
-- @Name PerformancePageFSM
-- @Author iKrypto (AI Assistant)
-- @Description Performance Page FSM managing graph updates and tooltip interactions.

local BasePageFSM = require(script.Parent.BasePageFSM)

local PerformancePageFSM = BasePageFSM.Extend({
	className = "PerformancePageFSM",
	validStates = {
		"Initializing", "Idle", "SamplingData", "UpdatingGraph",
		"ShowingTooltip", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 5
})

function PerformancePageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("SamplingData", {
		OnEnter = function(fsm)
			-- Collect frame stats from scheduler
			fsm:ChangeState({ Name = "UpdatingGraph" })
		end
	})
	
	self:AddState("UpdatingGraph", {
		OnEnter = function(fsm)
			-- Render performance bars/heatmap
			fsm:ChangeState({ Name = "Idle" })
		end
	})
	
	self:AddState("ShowingTooltip", {
		OnEnter = function(fsm)
			-- Display task details on hover
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

function PerformancePageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing Performance Page UI..." })
	-- Setup graph container, pause button, mode toggle
end

function PerformancePageFSM:OnIdleUpdate(entity: any, dt: number)
	-- Periodically sample performance data if not paused
	if not entity.IsGraphPaused then
		-- Request data fetch every N seconds
	end
end

function PerformancePageFSM:OnCleanup()
	BasePageFSM.OnCleanup(self)
end

return PerformancePageFSM
