local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local OrchestratorModule = ReplicatedStorage:WaitForChild("Orchestrator", 30)

if not OrchestratorModule then
	warn("[FSM Client] Orchestrator module not found in ReplicatedStorage after 30s timeout.")
	return
end

local Orchestrator = require(OrchestratorModule)
Orchestrator:RegisterComponents()

-- Explicitly attach the Service Manager GUI to the LocalPlayer
-- This can be deferred or triggered by a developer keybind/command
Orchestrator:AttachServiceManager()