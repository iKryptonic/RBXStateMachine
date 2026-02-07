--!strict
-- @Name HistoryPageEntity
-- @Author iKrypto (AI Assistant)
-- @Description History Page entity managing task history filtering and pagination.

local BasePageEntity = require(script.Parent.BasePageEntity)

local HistoryPageEntity = BasePageEntity.Extend({
	Name = "HistoryPageEntity",
	Schema = {
		-- Data State
		SelectedEntry = { Type = "string", Persist = false },
		Filters = { Type = "table", Persist = false }, -- { Completed: bool, Failed: bool, Cancelled: bool }
		SortMode = { Type = "string", Persist = false }, -- "Time" | "Duration"
	}
})

function HistoryPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	baseContext.HistoryCards = {}
	baseContext.DetailPanel = nil
	return baseContext
end

function HistoryPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	self.SelectedEntry = nil
	self.Filters = { Completed = true, Failed = true, Cancelled = true }
	self.SortMode = "Time"
	
	self:Log({ Level = "INFO", Message = "HistoryPageEntity initialized" })
end

function HistoryPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
end

function HistoryPageEntity:ToggleFilter(filterName: string)
	if self.Filters[filterName] ~= nil then
		local newFilters = table.clone(self.Filters)
		newFilters[filterName] = not newFilters[filterName]
		self.Filters = newFilters
	end
end

function HistoryPageEntity:Cleanup()
	self.HistoryCards = {}
	self.DetailPanel = nil
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "HistoryPageEntity cleanup complete" })
end

return HistoryPageEntity
