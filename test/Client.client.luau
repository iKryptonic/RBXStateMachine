--!strict
-- Test client bootstrap for the RBXStateMachine project.
-- Connects to the Orchestrator and launches the ServiceManager dashboard.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Orchestrator = require(ReplicatedStorage:WaitForChild("Orchestrator", 30))
Orchestrator:RegisterComponents()
Orchestrator:StartServiceManager()

print("[Client] ServiceManager started")
