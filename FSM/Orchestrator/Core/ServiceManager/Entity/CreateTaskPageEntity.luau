--!strict
-- @Name CreateTaskPageEntity
-- @Author iKrypto
-- @Description CreateTask Page entity for task creation form state.
-- This is a minimal entity as the form UI is wired externally via ServiceManager.HookCreateTaskUI.
-- Migrated from legacy CreateTaskPage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local CreateTaskPageEntity = BasePageEntity.Extend({
	Name = "CreateTaskPageEntity",
	Schema = {
		-- Form state (if needed in future)
		FormData = { Type = "table", Persist = false },
	}
})

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function CreateTaskPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	return baseContext
end

--[[
	@description Initializes create task entity state.
	@return ()
]]
function CreateTaskPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize form state (minimal)
	self.FormData = {}
	
	self:Log({ Level = "INFO", Message = "CreateTaskPageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function CreateTaskPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
end

--[[
	@description Cleanup handler.
	@return ()
]]
function CreateTaskPageEntity:Cleanup()
	self.FormData = {}
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "CreateTaskPageEntity cleanup complete" })
end

return CreateTaskPageEntity
