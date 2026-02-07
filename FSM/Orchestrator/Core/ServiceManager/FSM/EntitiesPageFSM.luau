--!strict
-- @Name EntitiesPageFSM
-- @Author iKrypto (AI Assistant)
-- @Description Entities Page FSM managing entity display.

local BasePageFSM = require(script.Parent.BasePageFSM)

local EntitiesPageFSM = BasePageFSM.Extend({
	className = "EntitiesPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ShowingDetails", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 10
})

function EntitiesPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
end

function EntitiesPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing Entities Page UI..." })
end

function EntitiesPageFSM:OnCleanup()
	BasePageFSM.OnCleanup(self)
end

return EntitiesPageFSM
