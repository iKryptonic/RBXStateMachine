--!strict
-- @Name FSMsPageFSM
-- @Author iKrypto (AI Assistant)
-- @Description FSMs Page FSM managing state machine display.

local BasePageFSM = require(script.Parent.BasePageFSM)

local FSMsPageFSM = BasePageFSM.Extend({
	className = "FSMsPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "Rendering",
		"ShowingDetails", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 10
})

function FSMsPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
end

function FSMsPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing FSMs Page UI..." })
end

function FSMsPageFSM:OnCleanup()
	BasePageFSM.OnCleanup(self)
end

return FSMsPageFSM
