--!strict
-- @Name DummyFSM (Test Fixture)
-- @Description Attaches behavior to shared.StateMachine.DummyFSM.

shared.__TestFlags = shared.__TestFlags or {}
shared.__TestFlags.DummyFSMLoaded = true

local DummyFSM = (shared.StateMachine and shared.StateMachine.DummyFSM)
if not DummyFSM then
	return {}
end

function DummyFSM:RegisterStates()
	self:AddState("Idle", function(fsm)
		if fsm.Entity and fsm.Entity.SetValue then
			fsm.Entity:SetValue(0.25, "DummyIdle")
		end
		fsm.State = "Done"
	end, { "Done" })

	self:AddState("Done", function(fsm)
		fsm:Finish()
	end)
end

return DummyFSM
