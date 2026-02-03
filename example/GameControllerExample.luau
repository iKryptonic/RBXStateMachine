-- GameControllerExample.lua
-- Example controller script demonstrating how to instantiate and run a job.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Orchestrator = require(ReplicatedStorage:WaitForChild("Orchestrator"))
Orchestrator:RegisterComponents()

-- Setup a dummy door model for testing
local doorModel = workspace.Door1 

-- Create the entity wrapper for the door
local Door1 = Orchestrator.CreateEntity({
	EntityClass = "DoorEntity",
	EntityId = "Door1",
	Context = {
		Name = doorModel.Name,
		Instance = doorModel,
		OwnerId = script.Name
	}
})

if not Door1 then warn("Failed to create Door1 entity.") return end
-- Create the Job
-- We pass a single table with the Job's Class, a unique ID, and arguments for the constructor
local openJob = Orchestrator.CreateStateMachine({
	StateMachineClass = "DoorJob",
	StateMachineId = script.Name .. " DoorJob " .. tick(),
	Context = { 
		DoorEntity = Door1,
		DesiredState = "Open"
	}
})

if not openJob then warn("Failed to create DoorJob.") return end

-- Hook up events (Optional)
openJob.Completed:Connect(function()
	print("Success: Door is now open.")

	task.wait(1)

	local closeJob = Orchestrator.CreateStateMachine({
		StateMachineClass = "DoorJob",
		StateMachineId = script.Name .. " DoorJob " .. tick(),
		Context = { 
			DoorEntity = Door1,
			DesiredState = "Close"
		}
	})

	if not closeJob then return end

	closeJob:Start { State = "Validate" }

	-- Hook up events (Optional)
	closeJob.Completed:Wait();

	print("Success: Door is now closed.")
end)

openJob.Failed:Connect(function(reason)
	warn("Access Denied:", reason)
end)

-- Start the Logic
openJob:Start { State = "Validate" }