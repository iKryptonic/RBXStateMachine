--!strict
-- Test server bootstrap for the RBXStateMachine project.
-- Creates example entities/FSMs to exercise the framework E2E.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Orchestrator = require(ReplicatedStorage:WaitForChild("Orchestrator"))
Orchestrator:RegisterComponents()

-- TrafficLight perpetual FSM (visualizer demo)
local trafficFsm = Orchestrator.CreateStateMachine({
	StateMachineClass = "TrafficLightFSM",
	StateMachineId = "TrafficLight_Demo",
	Context = { Cycles = 0 },
})
if trafficFsm then
	print("[Server] TrafficLight demo FSM started:", trafficFsm.Id)
end

print("[Server] Orchestrator ready")
