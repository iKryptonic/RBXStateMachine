--!strict
-- @Name EntitiesPageEntity
-- @Author iKrypto
-- @Description Entities Page entity managing entity listing, selection, and filtering.
-- Migrated from legacy EntitiesPage.luau controller pattern.

local BasePageEntity = require(script.Parent.BasePageEntity)

local EntitiesPageEntity = BasePageEntity.Extend({
	Name = "EntitiesPageEntity",
	Schema = {
		-- Data State
		SelectedEntity = { Type = "string", Persist = false },
		ShowArchived = { Type = "boolean", Persist = false },
		SortMode = { Type = "string", Persist = false }, -- "Name" | "Status"
	}
})

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ... } }
	@return { [string]: any }
]]
function EntitiesPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	
	-- Add entities-specific cached GUI elements
	baseContext.EntityList = nil
	baseContext.MetadataPanel = nil
	baseContext.ActiveSection = nil
	baseContext.ArchivedSection = nil
	baseContext.EntityCards = {}
	
	return baseContext
end

--[[
	@description Initializes entities entity state.
	@return ()
]]
function EntitiesPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	-- Initialize data state
	self.SelectedEntity = nil
	self.ShowArchived = false
	self.SortMode = "Name"
	self.Search = ""
	self.Page = 1
	self.PageSize = 10
	
	-- Initialize GUI references
	self.EntityList = nil
	self.MetadataPanel = nil
	self.ActiveSection = nil
	self.ArchivedSection = nil
	self.EntityCards = {}
	
	self:Log({ Level = "INFO", Message = "EntitiesPageEntity initialized" })
end

--[[
	@description Applies entity state changes to GUI.
	@param changes { [string]: any }
	@return ()
]]
function EntitiesPageEntity:ApplyChanges(changes: { [string]: any })
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
	
	-- Handle selection change
	if changes.SelectedEntity ~= nil then
		self:Log({ Level = "DEBUG", Message = string.format("Entity selected: %s", tostring(self.SelectedEntity)) })
	end
end

--[[
	@description Selects an entity by ID.
	@param entityId string?
	@return ()
]]
function EntitiesPageEntity:SelectEntity(entityId: string?)
	self.SelectedEntity = entityId
end

--[[
	@description Clears current selection.
	@return ()
]]
function EntitiesPageEntity:ClearSelection()
	self.SelectedEntity = nil
end

--[[
	@description Toggles show archived state.
	@return ()
]]
function EntitiesPageEntity:ToggleShowArchived()
	self.ShowArchived = not self.ShowArchived
end

--[[
	@description Sets sort mode.
	@param mode string
	@return ()
]]
function EntitiesPageEntity:SetSortMode(mode: string)
	if mode == "Name" or mode == "Status" then
		self.SortMode = mode
	end
end

--[[
	@description Cleanup handler.
	@return ()
]]
function EntitiesPageEntity:Cleanup()
	self.EntityList = nil
	self.MetadataPanel = nil
	self.ActiveSection = nil
	self.ArchivedSection = nil
	self.EntityCards = {}
	
	BasePageEntity.Cleanup(self)
	self:Log({ Level = "INFO", Message = "EntitiesPageEntity cleanup complete" })
end

return EntitiesPageEntity
