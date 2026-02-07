--!strict
--[[
	@Name CreateTaskPage
	@Author iKrypto
	@Description Static "Create Task" form page controller.
	The form UI is wired externally via ServiceManager.HookCreateTaskUI;
	this module only provides the page scaffolding.
	
	@deprecated This legacy controller is retained for regression testing only.
	Use the new FSM/Entity pattern: FSM/CreateTaskPageFSM.luau + Entity/CreateTaskPageEntity.luau
]]

local CreateTaskPage = {}

--[[
	@description Creates the CreateTask page table with an empty UpdateFunction.
	The actual form binding is performed by ServiceManager.HookCreateTaskUI.
	@param ServiceManager any -- The root ServiceManager instance.
	@return { Container: Instance, Tab: Instance, Constants: {}, Connections: {}, UpdateFunction: (any) -> () }
]]
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
