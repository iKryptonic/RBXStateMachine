--!strict
-- @Name LogsPageEntity
-- @Author iKrypto
-- @Description Logs Page entity with filter state and log buffer management.
-- Migrated from legacy LogsPage.luau controller pattern.

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
	
	-- Initialize data state with both named and numeric keys for compatibility
	self.Filters = {
		-- Named keys (new pattern)
		DEBUG = false,
		INFO = true,
		WARN = true,
		ERROR = true,
		-- Numeric keys (legacy compatibility: 1=INFO, 2=WARN, 3=ERROR)
		[1] = true,
		[2] = true,
		[3] = true,
	}
	self.LastBufferHash = ""
	self.Search = ""
	
	-- Initialize GUI references
	self.FilterButtons = {}
	self.ClearButton = nil
	self.Viewport = nil
	self.Content = nil
	
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
		self.LastBufferHash = "" -- Force re-render
		self:Log({ Level = "DEBUG", Message = "Logs filters or search changed, re-render needed" })
	end
end

--[[
	@description Toggles a log level filter (supports both named and numeric keys).
	@param level string | number -- "DEBUG", "INFO", "WARN", "ERROR" or 1, 2, 3
	@return ()
]]
function LogsPageEntity:ToggleFilter(level: string | number)
	if self.Filters[level] ~= nil then
		self.Filters[level] = not self.Filters[level]
		
		-- Sync named/numeric keys if applicable
		if type(level) == "string" then
			local numericMap = { INFO = 1, WARN = 2, ERROR = 3 }
			if numericMap[level] then
				self.Filters[numericMap[level]] = self.Filters[level]
			end
		elseif type(level) == "number" then
			local nameMap = { [1] = "INFO", [2] = "WARN", [3] = "ERROR" }
			if nameMap[level] then
				self.Filters[nameMap[level]] = self.Filters[level]
			end
		end
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
		ERROR = enabled,
		[1] = enabled,
		[2] = enabled,
		[3] = enabled,
	}
end

--[[
	@description Checks if a log entry matches current filters.
	@param logEntry { Level: string?, Type: number? }
	@return boolean
]]
function LogsPageEntity:MatchesFilters(logEntry: any): boolean
	if not logEntry then
		return false
	end
	
	-- Check by named Level
	if logEntry.Level and self.Filters[logEntry.Level] ~= nil then
		return self.Filters[logEntry.Level] == true
	end
	
	-- Check by numeric Type
	if logEntry.Type and self.Filters[logEntry.Type] ~= nil then
		return self.Filters[logEntry.Type] == true
	end
	
	return true -- Default to visible
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
