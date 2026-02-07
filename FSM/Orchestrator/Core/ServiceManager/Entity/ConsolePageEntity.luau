--!strict
-- @Name ConsolePageEntity
-- @Author iKrypto
-- @Description Console Page entity managing CLI state, scroll, and command history.
-- Migrated from legacy ConsolePage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local ConsolePageEntity = BasePageEntity.Extend({
	Name = "ConsolePageEntity",
	Schema = {
		-- Console State
		LineCount = { Type = "number", Persist = false },
		ScrollY = { Type = "number", Persist = false },
		FollowTail = { Type = "boolean", Persist = false },
		CommandHistory = { Type = "table", Persist = false },
		HistoryIndex = { Type = "number", Persist = false },
		SuggestionIndex = { Type = "number", Persist = false },
		Initialized = { Type = "boolean", Persist = false },
	}
})

-- Console constants
local CONSOLE_MAX_LIMIT = 500

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function ConsolePageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add console-specific cached GUI elements
	baseContext.InputBox = nil
	baseContext.Viewport = nil
	baseContext.Content = nil
	baseContext.ListLayout = nil
	baseContext.SuggestionsFrame = nil
	baseContext.ScrollTrack = nil
	baseContext.ScrollThumb = nil
	baseContext.Registry = nil
	
	return baseContext
end

--[[
	@description Initializes console entity state.
	@return ()
]]
function ConsolePageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize console state
	self.LineCount = 0
	self.ScrollY = 0
	self.FollowTail = true
	self.CommandHistory = {}
	self.HistoryIndex = 0
	self.SuggestionIndex = 1
	self.Initialized = false
	
	-- Initialize GUI references
	self.InputBox = nil
	self.Viewport = nil
	self.Content = nil
	self.ListLayout = nil
	self.SuggestionsFrame = nil
	self.ScrollTrack = nil
	self.ScrollThumb = nil
	
	-- Command registry
	self.Registry = {}
	
	-- Scroll helper functions (set by FSM)
	self._updateVisuals = nil
	self._getContentHeight = nil
	self._getViewportHeight = nil
	self._setScroll = nil
	
	self:Log({ Level = "INFO", Message = "ConsolePageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function ConsolePageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	if changes.ScrollY ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("Scroll position: %.1f", self.ScrollY) })
	end
	
	if changes.LineCount ~= nil then
		-- Enforce max line limit
		if self.LineCount > CONSOLE_MAX_LIMIT and self.Content then
			local excess = self.LineCount - CONSOLE_MAX_LIMIT
			local children = self.Content:GetChildren()
			local removed = 0
			for _, child in ipairs(children) do
				if child:IsA("TextLabel") and removed < excess then
					child:Destroy()
					removed += 1
				end
			end
			self.LineCount = self.LineCount - removed
		end
	end
end

--[[
	@description Adds a command to history.
	@param command string
	@return ()
]]
function ConsolePageEntity:AddToHistory(command: string)
	self.CommandHistory = self.CommandHistory or {}
	table.insert(self.CommandHistory, command)
	self.HistoryIndex = #self.CommandHistory + 1
end

--[[
	@description Navigates command history up.
	@return string?
]]
function ConsolePageEntity:HistoryUp(): string?
	if not self.CommandHistory or #self.CommandHistory == 0 then
		return nil
	end
	
	self.HistoryIndex = math.max(1, self.HistoryIndex - 1)
	return self.CommandHistory[self.HistoryIndex]
end

--[[
	@description Navigates command history down.
	@return string?
]]
function ConsolePageEntity:HistoryDown(): string?
	if not self.CommandHistory or #self.CommandHistory == 0 then
		return nil
	end
	
	self.HistoryIndex = math.min(#self.CommandHistory + 1, self.HistoryIndex + 1)
	if self.HistoryIndex > #self.CommandHistory then
		return ""
	end
	return self.CommandHistory[self.HistoryIndex]
end

--[[
	@description Resets history index to end.
	@return ()
]]
function ConsolePageEntity:ResetHistoryIndex()
	self.HistoryIndex = #(self.CommandHistory or {}) + 1
end

--[[
	@description Cleanup handler.
	@return ()
]]
function ConsolePageEntity:Cleanup()
	self.InputBox = nil
	self.Viewport = nil
	self.Content = nil
	self.ListLayout = nil
	self.SuggestionsFrame = nil
	self.ScrollTrack = nil
	self.ScrollThumb = nil
	self.Registry = nil
	self.CommandHistory = {}
	self._updateVisuals = nil
	self._getContentHeight = nil
	self._getViewportHeight = nil
	self._setScroll = nil
	
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "ConsolePageEntity cleanup complete" })
end

return ConsolePageEntity
