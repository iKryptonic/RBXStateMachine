--!strict
-- @Name EntitiesPageEntity
-- @Author iKrypto (AI Assistant)
-- @Description Entities Page entity managing entity listing and selection.

local BasePageEntity = require(script.Parent.BasePageEntity)

local EntitiesPageEntity = BasePageEntity.Extend({
	Name = "EntitiesPageEntity",
	Schema = {
		SelectedEntity = { Type = "string", Persist = false },
	}
})

function EntitiesPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	baseContext.EntityCards = {}
	baseContext.DetailPanel = nil
	return baseContext
end

function EntitiesPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	self.SelectedEntity = nil
	
	self:Log({ Level = "INFO", Message = "EntitiesPageEntity initialized" })
end

function EntitiesPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
end

function EntitiesPageEntity:SelectEntity(entityId: string?)
	self.SelectedEntity = entityId
end

function EntitiesPageEntity:Cleanup()
	self.EntityCards = {}
	self.DetailPanel = nil
	BasePageEntity.Cleanup(self)
end

return EntitiesPageEntity
