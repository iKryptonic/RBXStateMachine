--!strict
-- @Name LogsPageEntity
-- @Author iKrypto (AI Assistant)
-- @Description Logs Page entity with filter state and log buffer management.

local BasePageEntity = require(script.Parent.BasePageEntity)

local LogsPageEntity = BasePageEntity.Extend({
	Name = "LogsPageEntity",
	Schema = {
		-- Data State (extends base Search, Page, PageSize)
		Filters = { Type = "table", Persist = false }, -- { [level]: boolean } e.g. { INFO = true, WARN = true, ERROR = true }
		LastBufferHash = { Type = "string", Persist = false }, -- For diffing optimization
	}
})

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function LogsPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add logs-specific cached GUI elements
	baseContext.Viewport = nil
	baseContext.Content = nil
	baseContext.FilterButtons = {} -- Cache filter toggle buttons
	baseContext.ClearButton = nil
	
	return baseContext
end

--[[
	@description Initializes logs entity state.
	@return ()
]]
function LogsPageEntity:Initialize()
	-- Call base initialization
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize data state
	self.Filters = {
		DEBUG = false,
		INFO = true,
		WARN = true,
		ERROR = true
	}
	self.LastBufferHash = ""
	self.Search = ""
	
	self:Log({ Level = "INFO", Message = "LogsPageEntity initialized" })
end

--[[
	@description Applies entity state changes to logs GUI.
	@param changes { [string]: any }
	@return ()
]]
function LogsPageEntity:ApplyChanges(changes: { [string]: any })
	-- Call base to handle visibility and scroll
	BasePageEntity.ApplyChanges(self, changes)
	
	-- Handle filter changes (update button visual state)
	if changes.Filters ~= nil then
		for level, button in pairs(self.FilterButtons) do
			if self.Filters[level] ~= nil and button:IsA("TextButton") then
				-- Update button appearance based on filter state
				button.BackgroundTransparency = self.Filters[level] and 0 or 0.5
			end
		end
	end
	
	-- Handle search or filter changes (trigger re-render)
	if changes.Search ~= nil or changes.Filters ~= nil then
		self:Log({ Level = "DEBUG", Message = "Logs filters or search changed, re-render needed" })
	end
end

--[[
	@description Toggles a log level filter.
	@param level string -- "DEBUG", "INFO", "WARN", "ERROR"
	@return ()
]]
function LogsPageEntity:ToggleFilter(level: string)
	if self.Filters[level] ~= nil then
		self.Filters[level] = not self.Filters[level]
	end
end

--[[
	@description Sets all filters to a specific state.
	@param enabled boolean
	@return ()
]]
function LogsPageEntity:SetAllFilters(enabled: boolean)
	self.Filters = {
		DEBUG = enabled,
		INFO = enabled,
		WARN = enabled,
		ERROR = enabled
	}
end

--[[
	@description Checks if a log entry matches current filters.
	@param logEntry { Level: string }
	@return boolean
]]
function LogsPageEntity:MatchesFilters(logEntry: any): boolean
	if not logEntry or not logEntry.Level then
		return false
	end
	
	return self.Filters[logEntry.Level] == true
end

--[[
	@description Cleanup handler.
	@return ()
]]
function LogsPageEntity:Cleanup()
	-- Clear GUI references
	self.Viewport = nil
	self.Content = nil
	self.FilterButtons = {}
	self.ClearButton = nil
	
	-- Call base cleanup
	BasePageEntity.Cleanup(self)
	
	self:Log({ Level = "INFO", Message = "LogsPageEntity cleanup complete" })
end

return LogsPageEntity
