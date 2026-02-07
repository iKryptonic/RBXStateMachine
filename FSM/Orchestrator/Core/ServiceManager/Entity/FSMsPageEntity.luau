--!strict
-- @Name FSMsPageEntity
-- @Author iKrypto (AI Assistant)
-- @Description FSMs Page entity managing state machine listing and selection.

local BasePageEntity = require(script.Parent.BasePageEntity)

local FSMsPageEntity = BasePageEntity.Extend({
	Name = "FSMsPageEntity",
	Schema = {
		SelectedStateMachine = { Type = "string", Persist = false },
		ShowArchived = { Type = "boolean", Persist = false },
	}
})

function FSMsPageEntity:GetContext(params: any)
	local baseContext = BasePageEntity.GetContext(self, params)
	baseContext.FSMCards = {}
	baseContext.DetailPanel = nil
	return baseContext
end

function FSMsPageEntity:Initialize()
	if BasePageEntity.Initialize then
		BasePageEntity.Initialize(self)
	end
	
	self.SelectedStateMachine = nil
	self.ShowArchived = false
	
	self:Log({ Level = "INFO", Message = "FSMsPageEntity initialized" })
end

function FSMsPageEntity:ApplyChanges(changes: { [string]: any })
	BasePageEntity.ApplyChanges(self, changes)
end

function FSMsPageEntity:SelectFSM(fsmId: string?)
	self.SelectedStateMachine = fsmId
end

function FSMsPageEntity:Cleanup()
	self.FSMCards = {}
	self.DetailPanel = nil
	BasePageEntity.Cleanup(self)
end

return FSMsPageEntity
