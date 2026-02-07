--!strict
-- @Name CreateTaskPageFSM
-- @Author iKrypto
-- @Description CreateTask Page FSM for task creation form.
-- This is a minimal FSM as the form UI is wired externally via ServiceManager.HookCreateTaskUI.
-- Migrated from legacy CreateTaskPage.luau controller pattern.

local BasePageFSM = require(script.Parent.BasePageFSM)

local CreateTaskPageFSM = BasePageFSM.Extend({
	className = "CreateTaskPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"Submitting", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 10
})

--[[
	@description Registers states for the create task page FSM.
	@return ()
]]
function CreateTaskPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("Submitting", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "DEBUG", Message = "Submitting task creation..." })
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

--[[
	@description Hook for initializing create task UI elements.
	Form binding is handled externally by ServiceManager.HookCreateTaskUI.
	@param entity any
	@return ()
]]
function CreateTaskPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing CreateTask Page UI..." })
	
	local container = entity.Container
	if not container then
		self:Log({ Level = "ERROR", Message = "CreateTask container not found" })
		return
	end
	
	-- Form binding is handled by ServiceManager.HookCreateTaskUI
	-- This FSM primarily provides the page scaffolding and state management
	
	self:Log({ Level = "INFO", Message = "CreateTask Page UI initialized (form wired externally)" })
end

--[[
	@description Hook for fetching data (minimal for this page).
	@param entity any
	@return ()
]]
function CreateTaskPageFSM:OnFetchData(entity: any)
	-- No data fetching needed for create task form
	self:Log({ Level = "DEBUG", Message = "CreateTask page has no data to fetch" })
end

--[[
	@description Hook for rendering create task UI (minimal).
	@param entity any
	@return ()
]]
function CreateTaskPageFSM:OnRenderUI(entity: any)
	-- Form rendering is handled by ServiceManager.HookCreateTaskUI
	self:Log({ Level = "DEBUG", Message = "CreateTask page render (form wired externally)" })
end

--[[
	@description Request render by flagging context.
	@return ()
]]
function CreateTaskPageFSM:RequestRender()
	if self.Context then
		self.Context._needsRender = true
	end
end

return CreateTaskPageFSM
