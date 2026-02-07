--!strict
-- @Name HistoryPageEntity
-- @Author iKrypto
-- @Description History Page entity managing history listing, filtering, and selection.
-- Migrated from legacy HistoryPage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local HistoryPageEntity = BasePageEntity.Extend({
	Name = "HistoryPageEntity",
	Schema = {
		-- Data State
		SelectedEntry = { Type = "table", Persist = false },
		SortMode = { Type = "string", Persist = false }, -- "Time" | "Duration"
		Filters = { Type = "table", Persist = false },
		LastHash = { Type = "string", Persist = false },
	}
})

-- Sort modes for cycling
local SORT_MODES = { "Time", "Duration" }

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function HistoryPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add history-specific cached GUI elements
	baseContext.HistoryList = nil
	baseContext.Details = nil
	baseContext.DetailsContent = nil
	baseContext.SortButton = nil
	
	return baseContext
end

--[[
	@description Initializes history entity state.
	@return ()
]]
function HistoryPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize data state
	self.SelectedEntry = nil
	self.SortMode = "Time"
	self.Filters = { Completed = true, Failed = true, Cancelled = true }
	self.LastHash = ""
	self.Search = ""
	self.Page = 1
	self.PageSize = 8
	
	-- Initialize GUI references
	self.HistoryList = nil
	self.Details = nil
	self.DetailsContent = nil
	self.SortButton = nil
	
	self:Log({ Level = "INFO", Message = "HistoryPageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function HistoryPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	-- Handle sort mode change
	if changes.SortMode ~= nil then
		if self.SortButton then
			self.SortButton.Text = "SORT: " .. string.upper(self.SortMode)
		end
	end
	
	-- Handle selection change
	if changes.SelectedEntry ~= nil then
		local entryName = self.SelectedEntry and self.SelectedEntry.Name or "nil"
		self:Log({ Level = "DEBUG", Message = string.format("Entry selected: %s", entryName) })
	end
end

--[[
	@description Selects a history entry.
	@param entry table?
	@return ()
]]
function HistoryPageEntity:SelectEntry(entry: any)
	self.SelectedEntry = entry
end

--[[
	@description Clears current selection.
	@return ()
]]
function HistoryPageEntity:ClearSelection()
	self.SelectedEntry = nil
end

--[[
	@description Sets sort mode.
	@param mode string
	@return ()
]]
function HistoryPageEntity:SetSortMode(mode: string)
	if table.find(SORT_MODES, mode) then
		self.SortMode = mode
	end
end

--[[
	@description Cycles to next sort mode.
	@return ()
]]
function HistoryPageEntity:CycleSortMode()
	local currentIdx = table.find(SORT_MODES, self.SortMode) or 1
	self.SortMode = SORT_MODES[(currentIdx % #SORT_MODES) + 1]
end

--[[
	@description Toggles a filter by name.
	@param filterName string
	@return ()
]]
function HistoryPageEntity:ToggleFilter(filterName: string)
	if self.Filters[filterName] ~= nil then
		self.Filters[filterName] = not self.Filters[filterName]
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function HistoryPageEntity:Cleanup()
	self.HistoryList = nil
	self.Details = nil
	self.DetailsContent = nil
	self.SortButton = nil
	self.SelectedEntry = nil
	self.LastHash = ""
	
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "HistoryPageEntity cleanup complete" })
end

return HistoryPageEntity
