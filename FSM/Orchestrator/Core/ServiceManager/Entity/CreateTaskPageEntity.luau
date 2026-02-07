--!strict
-- @Name CreateTaskPageEntity
-- @Author iKrypto (AI Assistant)
-- @Description CreateTask Page entity managing task creation form state.

local BasePageEntity = require(script.Parent.BasePageEntity)

local CreateTaskPageEntity = BasePageEntity.Extend({
	Name = "CreateTaskPageEntity",
	Schema = {
		-- Form Data State
		TaskName = { Type = "string", Persist = false },
		Delay = { Type = "number", Persist = false },
		IsRecurring = { Type = "boolean", Persist = false },
		Priority = { Type = "number", Persist = false },
		Event = { Type = "string", Persist = false },
		
		-- Visual State
		ShowValidationError = { Type = "boolean", Persist = false },
		ValidationMessage = { Type = "string", Persist = false },
	}
})

function CreateTaskPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	baseContext.NameInput = nil
	baseContext.DelayInput = nil
	baseContext.RecurringToggle = nil
	baseContext.PriorityInput = nil
	baseContext.EventDropdown = nil
	baseContext.SubmitButton = nil
	baseContext.ErrorLabel = nil
	return baseContext
end

function CreateTaskPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	self.TaskName = ""
	self.Delay = 0
	self.IsRecurring = false
	self.Priority = 5
	self.Event = "Heartbeat"
	self.ShowValidationError = false
	self.ValidationMessage = ""
	
	self:Log({ Level = "INFO", Message = "CreateTaskPageEntity initialized" })
end

function CreateTaskPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	if changes.ShowValidationError ~= nil or changes.ValidationMessage ~= nil then
		if self.ErrorLabel then
			self.ErrorLabel.Visible = self.ShowValidationError
			self.ErrorLabel.Text = self.ValidationMessage
		end
	end
end

function CreateTaskPageEntity:ValidateForm(): (boolean, string)
	if self.TaskName == "" or self.TaskName:match("^%s*$") then
		return false, "Task name is required"
	end
	
	if self.Delay < 0 then
		return false, "Delay must be non-negative"
	end
	
	if self.Priority < 1 or self.Priority > 10 then
		return false, "Priority must be between 1 and 10"
	end
	
	return true, ""
end

function CreateTaskPageEntity:ShowError(message: string)
	self.ShowValidationError = true
	self.ValidationMessage = message
end

function CreateTaskPageEntity:HideError()
	self.ShowValidationError = false
	self.ValidationMessage = ""
end

function CreateTaskPageEntity:ResetForm()
	self.TaskName = ""
	self.Delay = 0
	self.IsRecurring = false
	self.Priority = 5
	self.Event = "Heartbeat"
	self:HideError()
end

function CreateTaskPageEntity:Cleanup()
	self.NameInput = nil
	self.DelayInput = nil
	self.RecurringToggle = nil
	self.PriorityInput = nil
	self.EventDropdown = nil
	self.SubmitButton = nil
	self.ErrorLabel = nil
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "CreateTaskPageEntity cleanup complete" })
end

return CreateTaskPageEntity
