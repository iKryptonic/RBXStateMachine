local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OrchestratorModule = ReplicatedStorage:WaitForChild("Orchestrator", 30)
if not OrchestratorModule then
	warn("[FSM Client] Orchestrator module not found in ReplicatedStorage after 30s timeout.")
	return
end

local Orchestrator = require(OrchestratorModule)
Orchestrator:RegisterComponents()

-- Boot NexusOrchestrator GUI (v2)
local NexusOrchestratorModule = ReplicatedStorage:WaitForChild("NexusOrchestrator", 30)
if not NexusOrchestratorModule then
	warn("[FSM Client] NexusOrchestrator module not found in ReplicatedStorage after 30s timeout.")
	return
end

local NexusOrchestrator = require(NexusOrchestratorModule)
NexusOrchestrator.Initialize(Orchestrator)
NexusOrchestrator.Show()