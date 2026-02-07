--!strict

-- Runtime/Pages/CreateTaskPage.luau
-- Static "Create Task" form page controller.

local CreateTaskPage = {}

function CreateTaskPage.Create(ServiceManager: any)
	return {
		Container = ServiceManager.GUI.BodyContainer:WaitForChild("CreateTaskView"):WaitForChild("Container"),
		Tab = ServiceManager.GUI.TabContainer:WaitForChild("CreateTask"),
		Constants = {},
		Connections = {},
		UpdateFunction = function(_this) end, -- Static form; wired via ServiceManager.HookCreateTaskUI
	}
end

return CreateTaskPage
