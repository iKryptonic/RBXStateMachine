--!strict
-- @Name PerformancePageEntity
-- @Author iKrypto
-- @Description Performance Page entity managing graph state, filters, and metrics.
-- Migrated from legacy PerformancePage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local PerformancePageEntity = BasePageEntity.Extend({
	Name = "PerformancePageEntity",
	Schema = {
		-- Data State
		SelectedTask = { Type = "string", Persist = false },
		SortMode = { Type = "string", Persist = false }, -- "Name" | "Avg" | "Max" | "Count"
		IsGraphPaused = { Type = "boolean", Persist = false },
		GraphMode = { Type = "string", Persist = false }, -- "Standard" | "Heatmap"
		Filters = { Type = "table", Persist = false },
		GraphHistory = { Type = "table", Persist = false },
	}
})

-- Sort modes for cycling
local SORT_MODES = { "Name", "Avg", "Max", "Count" }
local GRAPH_MODES = { "Standard", "Heatmap" }

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function PerformancePageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add performance-specific cached GUI elements
	baseContext.GlobalStats = nil
	baseContext.StatsLabels = nil
	baseContext.GraphContainer = nil
	baseContext.TaskList = nil
	baseContext.MetadataPanel = nil
	baseContext.PauseButton = nil
	baseContext.ModeButton = nil
	baseContext.SortButton = nil
	baseContext.Tooltip = nil
	
	return baseContext
end

--[[
	@description Initializes performance entity state.
	@return ()
]]
function PerformancePageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize data state
	self.SelectedTask = nil
	self.SortMode = "Name"
	self.IsGraphPaused = false
	self.GraphMode = "Standard"
	self.Filters = { Active = true, Inactive = true }
	self.GraphHistory = {}
	self.Search = ""
	self.Page = 1
	self.PageSize = 10
	
	-- Initialize GUI references
	self.GlobalStats = nil
	self.StatsLabels = nil
	self.GraphContainer = nil
	self.TaskList = nil
	self.MetadataPanel = nil
	self.PauseButton = nil
	self.ModeButton = nil
	self.SortButton = nil
	self.Tooltip = nil
	
	self:Log({ Level = "INFO", Message = "PerformancePageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function PerformancePageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	-- Handle graph pause state
	if changes.IsGraphPaused ~= nil then
		if self.PauseButton then
			self.PauseButton.Text = self.IsGraphPaused and "RESUME" or "PAUSE"
		end
	end
	
	-- Handle graph mode change
	if changes.GraphMode ~= nil then
		if self.ModeButton then
			self.ModeButton.Text = "VIEW: " .. string.upper(self.GraphMode)
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
function PerformancePageEntity:SelectTask(taskName: string?)
	self.SelectedTask = taskName
end

--[[
	@description Clears current selection.
	@return ()
]]
function PerformancePageEntity:ClearSelection()
	self.SelectedTask = nil
end

--[[
	@description Toggles graph pause state.
	@return ()
]]
function PerformancePageEntity:ToggleGraphPaused()
	self.IsGraphPaused = not self.IsGraphPaused
end

--[[
	@description Cycles graph mode between Standard and Heatmap.
	@return ()
]]
function PerformancePageEntity:CycleGraphMode()
	local currentIdx = table.find(GRAPH_MODES, self.GraphMode) or 1
	self.GraphMode = GRAPH_MODES[(currentIdx % #GRAPH_MODES) + 1]
end

--[[
	@description Sets sort mode.
	@param mode string
	@return ()
]]
function PerformancePageEntity:SetSortMode(mode: string)
	if table.find(SORT_MODES, mode) then
		self.SortMode = mode
	end
end

--[[
	@description Cycles to next sort mode.
	@return ()
]]
function PerformancePageEntity:CycleSortMode()
	local currentIdx = table.find(SORT_MODES, self.SortMode) or 1
	self.SortMode = SORT_MODES[(currentIdx % #SORT_MODES) + 1]
end

--[[
	@description Toggles a filter by name.
	@param filterName string
	@return ()
]]
function PerformancePageEntity:ToggleFilter(filterName: string)
	if self.Filters[filterName] ~= nil then
		self.Filters[filterName] = not self.Filters[filterName]
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function PerformancePageEntity:Cleanup()
	self.GlobalStats = nil
	self.StatsLabels = nil
	self.GraphContainer = nil
	self.TaskList = nil
	self.MetadataPanel = nil
	self.PauseButton = nil
	self.ModeButton = nil
	self.SortButton = nil
	self.Tooltip = nil
	self.GraphHistory = {}
	
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "PerformancePageEntity cleanup complete" })
end

return PerformancePageEntity
