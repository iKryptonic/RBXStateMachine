--!strict
-- DoorJobExample.lua
-- Example implementation of an DoorJob using the StateMachine and DoorEntity.
local DoorJob = shared.StateMachine and (shared.StateMachine :: any).DoorJob

--[[
	@summary Registers states and transitions for the DoorJob.
	@return ()
]]
function DoorJob:RegisterStates()

	-- STATE: VALIDATE
	-- Check if we can actually open this door
	self:AddState("Validate", function(fsm)
		-- We can read properties from the entity directly if we added getters,
		-- but usually FSMs track logic state in Context.
		-- Here, let's assume we check a Context variable or database.

		if fsm.Context.IsSealedForcefield then
			fsm:Fail("Door is sealed by forcefield")
			return
		end

		if not fsm.Context.DesiredState then
			fsm:Fail("No desired state provided")
			return
		end

		fsm:Log
		{ 
			Level = "INFO", 
			Message = "Validation passed, proceeding to open door." 
		}
		fsm.State = "CreatingMessage"
	end, { "CreatingMessage" })

	self:AddState("CreatingMessage", function(fsm)
		-- Create a message GUI to inform the user
		local messageGui = Instance.new("BillboardGui")
		messageGui.Size = UDim2.new(0, 200, 0, 50)
		messageGui.Adornee = fsm.DoorEntity.Instance:FindFirstChild("DoorPart")
		messageGui.AlwaysOnTop = true

		local textLabel = Instance.new("TextLabel")
		textLabel.Size = UDim2.new(1, 0, 1, 0)
		textLabel.BackgroundTransparency = 1
		textLabel.TextColor3 = Color3.new(1, 1, 1)
		textLabel.TextScaled = true
		textLabel.Text = "Processing..."
		textLabel.Parent = messageGui

		messageGui.Parent = workspace.CurrentCamera

		local Hint = Instance.new("Hint")
		fsm.Context.Hint = Hint

		fsm:Manage(Hint);
		fsm:Manage(messageGui)
		fsm:Log
		{
			Level = "INFO", 
			Message = tostring(fsm.State) .. " Door" 
		}
		fsm.State = fsm.Context.DesiredState == "Open" and "Opening" or "Closing"
	end, { "Opening", "Closing" })

	-- STATE: OPENING
	self:AddState("Opening", function(fsm)
		fsm.Context.Hint.Text = "Door is opening..."

		if not fsm.DoorEntity.IsOpen then
			fsm.Context.Hint.Parent = workspace;
			local OpenDoorResult = fsm.DoorEntity:Open()
			
			if not OpenDoorResult then
				fsm.State = "Failed"
			end
		end

		fsm.WaitSpan = 0.5
		fsm.State = (fsm.StateDuration < 5 and fsm.State or "Completed")
	end, { "Completed", "Failed", "Opening" })

	self:AddState("Closing", function(fsm)
		fsm.Context.Hint.Text = "Door is closing..."

		if fsm.DoorEntity.IsOpen then
			fsm.Context.Hint.Parent = workspace;
			local CloseDoorResult = fsm.DoorEntity:Close()
			
			if not CloseDoorResult then
				fsm.State = "Failed"
			end
		end

		fsm.WaitSpan = 0.5
		fsm.State = (fsm.StateDuration < 5 and fsm.State or "Completed")
	end, { "Completed", "Failed", "Closing" })

	-- STATE: COMPLETED
	self:AddState("Completed", function(fsm)
		fsm:Log
		{
			Level = "INFO", 
			Message = "Door state set to " .. tostring(fsm.Context.DesiredState) .. " Successfully" 
		}
	end)

	-- STATE: FAILED
	self:AddState("Failed", function(fsm, reason)
		fsm:Log
		{ 
			Level = "ERROR",
			Message = "Failed to " .. tostring(fsm.Context.DesiredState) .. " Door. Reason: " .. tostring(reason) 
		}
	end)
end

--[[
	@summary Cleans up the job when it is destroyed.
	@return ()
]]
function DoorJob:OnCleanup()
	-- reset the status light to neutral.
	if self.DoorEntity and self.DoorEntity.Instance then
		self.DoorEntity:Reset()
	end
end

return DoorJob