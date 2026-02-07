--!strict
-- @Name CreateTaskPageFSM
-- @Author iKrypto (AI Assistant)
-- @Description CreateTask Page FSM managing task creation workflow.

local BasePageFSM = require(script.Parent.BasePageFSM)

local CreateTaskPageFSM = BasePageFSM.Extend({
	className = "CreateTaskPageFSM",
	validStates = {
		"Initializing", "Idle", "ValidatingInput", "SubmittingTask",
		"ShowingFeedback", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 10
})

function CreateTaskPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("ValidatingInput", {
		OnEnter = function(fsm)
			local entity = fsm.Context.PageEntity
			local isValid, errorMsg = entity:ValidateForm()
			
			if isValid then
				entity:HideError()
				entity:UpdateEntity()
				fsm:ChangeState({ Name = "SubmittingTask" })
			else
				entity:ShowError(errorMsg)
				entity:UpdateEntity()
				fsm:ChangeState({ Name = "Idle" })
			end
		end
	})
	
	self:AddState("SubmittingTask", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = "Submitting task..." })
			
			local entity = fsm.Context.PageEntity
			local serviceManager = fsm.Context.ServiceManager
			
			if serviceManager and serviceManager.Services and serviceManager.Services.Scheduler then
				local scheduler = serviceManager.Services.Scheduler
				
				-- Submit task to scheduler
				local success = pcall(function()
					scheduler:Schedule({
						Name = entity.TaskName,
						Delay = entity.Delay,
						Priority = entity.Priority,
						Event = entity.Event,
						Recurring = entity.IsRecurring
					})
				end)
				
				if success then
					entity:ResetForm()
					entity:UpdateEntity()
					fsm:ChangeState({ Name = "ShowingFeedback" })
				else
					entity:ShowError("Failed to create task")
					entity:UpdateEntity()
					fsm:ChangeState({ Name = "Idle" })
				end
			else
				entity:ShowError("Scheduler not available")
				entity:UpdateEntity()
				fsm:ChangeState({ Name = "Idle" })
			end
		end
	})
	
	self:AddState("ShowingFeedback", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = "Task created successfully" })
			-- Display success toast/message
			fsm.WaitSpan = 1.5
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

function CreateTaskPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing CreateTask Page UI..." })
	
	-- Hook form input elements and submit button
	-- This is a placeholder - actual implementation would bind input events
end

function CreateTaskPageFSM:OnCleanup()
	BasePageFSM.OnCleanup(self)
end

return CreateTaskPageFSM
