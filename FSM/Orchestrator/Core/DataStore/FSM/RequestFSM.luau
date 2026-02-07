--!strict
-- @Name RequestFSM
-- @Author iKrypto
-- @Description Transient FSM representing a single DataStore operation. Visualization + Logic.

local RequestFSM = {
	Definition = {
		Name = "RequestFSM",
		ValidStates = { "Queued", "Processing", "Retrying", "Success", "Failed" },
		TerminalStates = { "Success", "Failed" },
		InitialState = "Queued",
		Priority = 2 -- High priority for responsive data handling
	}
}

function RequestFSM:RegisterStates()
	local Orchestrator = self.Context.Orchestrator
	-- Lazy load behavior to avoid circular dependency issues at module level if any
	local RetryBehavior = require(script.Parent.RetryBehavior).Create(Orchestrator)

	self:AddState("Queued", {
		OnEnter = function(fsm)
			-- Immediate transition to processing for now, 
			-- but could wait for a "TokenBucket" signal here for rate limiting integration.
			fsm:ChangeState({ Name = "Processing" })
		end
	})

	self:AddState("Processing", {
		OnEnter = function(fsm)
			-- Execute the Behavior Tree
			-- context is shared with FSM
			local status = RetryBehavior(fsm.Context)
			-- BT handles transitions to Success/Retrying/Failed
		end
	})

	self:AddState("Retrying", {
		OnEnter = function(fsm)
			-- WaitSpan is handled by BaseStateMachine prior to ChangeState or we can do it here manually
			-- Here we just wait for the transition back to processing
			-- The "WaitSpan" set by BT determines the delay *before* entering this state? 
			-- No, BaseStateMachine:ChangeState uses WaitSpan to delay the *transition*.
			-- So if we are IN this state, we just want to go back to Processing.
			
			-- Logic: The BT set fsm.WaitSpan then called ChangeState("Retrying").
			-- So we arrive here *after* the delay.
			-- We should immediately try Processing again.
			
			fsm:ChangeState({ Name = "Processing" })
		end
	})

	self:AddState("Success", {
		OnEnter = function(fsm)
			-- Pass result back to caller via resolving a Promise or Callback
			if fsm.Context.OnSuccess then
				fsm.Context.OnSuccess(fsm.Context.Result)
			end
		end
	})
	
	self:AddState("Failed", {
		OnEnter = function(fsm)
			if fsm.Context.OnFailure then
				fsm.Context.OnFailure(fsm.Context.LastError)
			end
		end
	})
end

return RequestFSM
