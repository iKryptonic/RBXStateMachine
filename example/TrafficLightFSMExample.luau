--!strict
-- TrafficLightFSM.luau
-- Perpetual loop FSM used as a visualizer test fixture.
-- Cycles Red -> Green -> Yellow -> Red forever, with occasional self-loops
-- (Yellow blinking) to exercise self-loop arc rendering in the FSM graph.

local TrafficLightFSM = {
	Name = "TrafficLightFSM",
	ValidStates = { "Red", "Green", "Yellow", "Blink", "Maintenance" },
	TerminalStates = {},
	InitialState = "Red",
}

function TrafficLightFSM:RegisterStates()
	self:AddState("Red", function(fsm)
		fsm.Context.Cycles = (fsm.Context.Cycles or 0) + 1
		fsm:ScheduleTransition(4, "Green")
	end, { "Green", "Maintenance" })

	self:AddState("Green", function(fsm)
		fsm:ScheduleTransition(5, "Yellow")
	end, { "Yellow", "Maintenance" })

	self:AddState("Yellow", function(fsm)
		-- Use a per-cycle "blinked" flag so each Yellow visit only blinks once.
		-- After blinking once this cycle, the next Yellow entry goes to Red.
		local cycles = fsm.Context.Cycles or 0
		if cycles % 3 == 0 and not fsm.Context._blinkedThisCycle then
			fsm.Context._blinkedThisCycle = true
			fsm:ScheduleTransition(2, "Blink")
		else
			fsm.Context._blinkedThisCycle = false
			fsm:ScheduleTransition(3, "Red")
		end
	end, { "Red", "Blink", "Maintenance" })

	self:AddState("Blink", function(fsm)
		fsm:ScheduleTransition(2, "Yellow")
	end, { "Yellow", "Blink", "Maintenance" })

	self:AddState("Maintenance", function(fsm)
		-- Manual stop state — sticks here until externally reset
	end, { "Red" })
end

return TrafficLightFSM
