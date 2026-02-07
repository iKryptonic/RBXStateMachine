--!strict
-- @Name HistoryPageFSM
-- @Author iKrypto (AI Assistant)
-- @Description History Page FSM managing history display and filtering.

local BasePageFSM = require(script.Parent.BasePageFSM)

local HistoryPageFSM = BasePageFSM.Extend({
	className = "HistoryPageFSM",
	validStates = {
		"Initializing", "Idle", "DataFetching", "FilteringSorting",
		"Rendering", "ShowingDetails", "Transitioning", "Destroyed"
	},
	terminalStates = { "Destroyed" },
	InitialState = "Initializing",
	Priority = 10
})

function HistoryPageFSM:RegisterStates()
	BasePageFSM.RegisterStates(self)
	
	self:AddState("FilteringSorting", {
		OnEnter = function(fsm)
			-- Apply filters and sort
			fsm:ChangeState({ Name = "Rendering" })
		end
	})
	
	self:AddState("ShowingDetails", {
		OnEnter = function(fsm)
			-- Display detailed entry view
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

function HistoryPageFSM:OnInitializeUI(entity: any)
	self:Log({ Level = "INFO", Message = "Initializing History Page UI..." })
end

function HistoryPageFSM:OnCleanup()
	BasePageFSM.OnCleanup(self)
end

return HistoryPageFSM
