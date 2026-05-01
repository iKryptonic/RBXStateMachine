local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local OrchestratorModule = ReplicatedStorage:WaitForChild("Orchestrator")

local Orchestrator = require(OrchestratorModule)
Orchestrator:RegisterComponents()

-- Boot NexusOrchestrator GUI (v2)
local NexusOrchestrator = require(ReplicatedStorage:WaitForChild("NexusOrchestrator"))
NexusOrchestrator.Initialize(Orchestrator)
NexusOrchestrator.Show()