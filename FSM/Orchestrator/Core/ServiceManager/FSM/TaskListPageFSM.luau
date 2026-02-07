--!strict
-- @Name TaskListPageFSM
-- @Author iKrypto (AI Assistant)
-- @Description TaskList Page FSM managing task display and interaction workflow.

local BasePageFSM = require(script.Parent.BasePageFSM)

local TaskListPageFSM = BasePageFSM.Extend({
	className = "TaskListPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ShowingDetails", "ExecutingAction", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 5
})

function TaskListPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("ShowingDetails", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity
			fsm:Log({ Level = "DEBUG", Message = string.format("Showing details for task: %s", tostring(entity.SelectedTask)) })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
	
	self:AddState("ExecutingAction", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = "Executing task action..." })
			-- Pause/Resume/Kill task logic
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

function TaskListPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing TaskList Page UI..." })
	-- Setup toolbar, search box, sort dropdown, archive toggle
	-- Setup active/archived sections
	-- Hook task card click events
end

function TaskListPageFSM:OnFetchData(entity: any)
	-- Fetch tasks from Scheduler service
end

function TaskListPageFSM:OnRenderUI(entity: any)
	-- Render filtered and sorted task cards
	-- Apply search filter and sort mode
end

function TaskListPageFSM:OnCleanup()
	BasePageFSM.OnCleanup(self)
end

return TaskListPageFSM
