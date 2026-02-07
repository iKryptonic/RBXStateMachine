--!strict
-- @Name TaskListPageEntity
-- @Author iKrypto (AI Assistant)
-- @Description TaskList Page entity managing task selection, filtering, and sorting.

local BasePageEntity = require(script.Parent.BasePageEntity)

local TaskListPageEntity = BasePageEntity.Extend({
	Name = "TaskListPageEntity",
	Schema = {
		-- Data State
		SelectedTask = { Type = "string", Persist = false },
		ShowArchived = { Type = "boolean", Persist = false },
		SortMode = { Type = "string", Persist = false }, -- "Name" | "Priority" | "Status"
		
		-- Visual State
		MetadataPanelVisible = { Type = "boolean", Persist = false },
		ActiveSectionHeight = { Type = "number", Persist = false },
		ArchivedSectionVisible = { Type = "boolean", Persist = false },
	}
})

function TaskListPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	baseContext.ActiveSection = nil
	baseContext.ArchivedSection = nil
	baseContext.MetadataPanel = nil
	baseContext.TaskCards = {}
	return baseContext
end

function TaskListPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	self.SelectedTask = nil
	self.ShowArchived = false
	self.SortMode = "Priority"
	self.MetadataPanelVisible = false
	self.ActiveSectionHeight = 1.0
	self.ArchivedSectionVisible = false
	
	self:Log({ Level = "INFO", Message = "TaskListPageEntity initialized" })
end

function TaskListPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
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
	
	if changes.SelectedTask ~= nil then
		self.MetadataPanelVisible = (self.SelectedTask ~= nil)
	end
	
	if changes.MetadataPanelVisible ~= nil then
		if self.MetadataPanel then
			self.MetadataPanel.Visible = self.MetadataPanelVisible
		end
	end
end

function TaskListPageEntity:SelectTask(taskName: string?)
	self.SelectedTask = taskName
end

function TaskListPageEntity:ToggleArchived()
	self.ShowArchived = not self.ShowArchived
end

function TaskListPageEntity:SetSortMode(mode: string)
	if mode == "Name" or mode == "Priority" or mode == "Status" then
		self.SortMode = mode
	end
end

function TaskListPageEntity:Cleanup()
	self.ActiveSection = nil
	self.ArchivedSection = nil
	self.MetadataPanel = nil
	self.TaskCards = {}
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "TaskListPageEntity cleanup complete" })
end

return TaskListPageEntity
