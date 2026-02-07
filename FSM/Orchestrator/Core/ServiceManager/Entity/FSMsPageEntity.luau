--!strict
-- @Name FSMsPageEntity
-- @Author iKrypto
-- @Description FSMs Page entity managing FSM listing, selection, and filtering.
-- Migrated from legacy FSMsPage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local FSMsPageEntity = BasePageEntity.Extend({
	Name = "FSMsPageEntity",
	Schema = {
		-- Data State
		SelectedStateMachine = { Type = "string", Persist = false },
		ShowArchived = { Type = "boolean", Persist = false },
		SortMode = { Type = "string", Persist = false }, -- "Name" | "State"
	}
})

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function FSMsPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add FSM-specific cached GUI elements
	baseContext.StateMachineList = nil
	baseContext.MetadataPanel = nil
	baseContext.ActiveSection = nil
	baseContext.FailedSection = nil
	baseContext.ArchivedSection = nil
	baseContext.FSMCards = {}
	
	return baseContext
end

--[[
	@description Initializes FSMs entity state.
	@return ()
]]
function FSMsPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize data state
	self.SelectedStateMachine = nil
	self.ShowArchived = false
	self.SortMode = "Name"
	self.Search = ""
	self.Page = 1
	self.PageSize = 10
	
	-- Initialize GUI references
	self.StateMachineList = nil
	self.MetadataPanel = nil
	self.ActiveSection = nil
	self.FailedSection = nil
	self.ArchivedSection = nil
	self.FSMCards = {}
	
	self:Log({ Level = "INFO", Message = "FSMsPageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function FSMsPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
	
	-- Handle archived visibility toggle
	if changes.ShowArchived ~= nil then
		if self.ActiveSection and self.FailedSection and self.ArchivedSection then
			if self.ShowArchived then
				self.ActiveSection.Size = UDim2.new(1, 0, 0.4, -5)
				self.FailedSection.Visible = true
				self.FailedSection.Size = UDim2.new(1, 0, 0.3, -5)
				self.ArchivedSection.Visible = true
				self.ArchivedSection.Size = UDim2.new(1, 0, 0.3, -5)
			else
				self.ActiveSection.Size = UDim2.new(1, 0, 1, 0)
				self.FailedSection.Visible = false
				self.ArchivedSection.Visible = false
			end
		end
	end
	
	-- Handle selection change
	if changes.SelectedStateMachine ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("FSM selected: %s", tostring(self.SelectedStateMachine)) })
	end
end

--[[
	@description Selects a state machine by ID.
	@param smId string?
	@return ()
]]
function FSMsPageEntity:SelectStateMachine(smId: string?)
	self.SelectedStateMachine = smId
end

--[[
	@description Clears current selection.
	@return ()
]]
function FSMsPageEntity:ClearSelection()
	self.SelectedStateMachine = nil
end

--[[
	@description Toggles show archived state.
	@return ()
]]
function FSMsPageEntity:ToggleShowArchived()
	self.ShowArchived = not self.ShowArchived
end

--[[
	@description Sets sort mode.
	@param mode string
	@return ()
]]
function FSMsPageEntity:SetSortMode(mode: string)
	if mode == "Name" or mode == "State" then
		self.SortMode = mode
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function FSMsPageEntity:Cleanup()
	self.StateMachineList = nil
	self.MetadataPanel = nil
	self.ActiveSection = nil
	self.FailedSection = nil
	self.ArchivedSection = nil
	self.FSMCards = {}
	
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "FSMsPageEntity cleanup complete" })
end

return FSMsPageEntity
