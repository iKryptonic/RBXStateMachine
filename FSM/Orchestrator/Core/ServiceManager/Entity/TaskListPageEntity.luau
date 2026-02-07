--!strict
-- @Name TaskListPageEntity
-- @Author iKrypto
-- @Description TaskList Page entity managing task listing, selection, and sorting.
-- Migrated from legacy TaskListPage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local TaskListPageEntity = BasePageEntity.Extend({
	Name = "TaskListPageEntity",
	Schema = {
		-- Data State
		SelectedTask = { Type = "string", Persist = false },
		ShowArchived = { Type = "boolean", Persist = false },
		SortMode = { Type = "string", Persist = false }, -- "Name" | "Priority" | "Event"
	}
})

-- Sort modes for cycling
local SORT_MODES = { "Name", "Priority", "Event" }

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function TaskListPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add task-specific cached GUI elements
	baseContext.TaskList = nil
	baseContext.MetadataPanel = nil
	baseContext.ActiveSection = nil
	baseContext.ArchivedSection = nil
	baseContext.SortButton = nil
	baseContext.TaskCards = {}
	
	return baseContext
end

--[[
	@description Initializes task list entity state.
	@return ()
]]
function TaskListPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize data state
	self.SelectedTask = nil
	self.ShowArchived = true -- Default to showing archived
	self.SortMode = "Name"
	self.Search = ""
	
	-- Initialize GUI references
	self.TaskList = nil
	self.MetadataPanel = nil
	self.ActiveSection = nil
	self.ArchivedSection = nil
	self.SortButton = nil
	self.TaskCards = {}
	
	self:Log({ Level = "INFO", Message = "TaskListPageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function TaskListPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	-- Handle archived visibility toggle
	if changes.ShowArchived ~= nil then
		if self.ActiveSection and self.ArchivedSection then
			if self.ShowArchived then
				self.ActiveSection.Size = UDim2.new(1, 0, 0.5, -5)
				self.ArchivedSection.Visible = true
			else
				self.ActiveSection.Size = UDim2.new(1, 0, 1, 0)
				self.ArchivedSection.Visible = false
			end
		end
	end
	
	-- Handle sort mode change
	if changes.SortMode ~= nil then
		if self.SortButton then
			self.SortButton.Text = "SORT: " .. string.upper(self.SortMode)
		end
	end
	
	-- Handle selection change
	if changes.SelectedTask ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("Task selected: %s", tostring(self.SelectedTask)) })
	end
end

--[[
	@description Selects a task by name.
	@param taskName string?
	@return ()
]]
function TaskListPageEntity:SelectTask(taskName: string?)
	self.SelectedTask = taskName
end

--[[
	@description Clears current selection.
	@return ()
]]
function TaskListPageEntity:ClearSelection()
	self.SelectedTask = nil
end

--[[
	@description Toggles show archived state.
	@return ()
]]
function TaskListPageEntity:ToggleShowArchived()
	self.ShowArchived = not self.ShowArchived
end

--[[
	@description Sets sort mode.
	@param mode string
	@return ()
]]
function TaskListPageEntity:SetSortMode(mode: string)
	if mode == "Name" or mode == "Priority" or mode == "Event" then
		self.SortMode = mode
	end
end

--[[
	@description Cycles to next sort mode.
	@return ()
]]
function TaskListPageEntity:CycleSortMode()
	local currentIdx = table.find(SORT_MODES, self.SortMode) or 1
	self.SortMode = SORT_MODES[(currentIdx % #SORT_MODES) + 1]
end

--[[
	@description Cleanup handler.
	@return ()
]]
function TaskListPageEntity:Cleanup()
	self.TaskList = nil
	self.MetadataPanel = nil
	self.ActiveSection = nil
	self.ArchivedSection = nil
	self.SortButton = nil
	self.TaskCards = {}
	
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "TaskListPageEntity cleanup complete" })
end

return TaskListPageEntity
