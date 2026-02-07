--!strict
-- @Name TerminalViewFSM
-- @Author iKrypto
-- @Description State Machine for managing the ServiceManager Terminal UI visibility.

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local TerminalViewFSM = {
	Definition = {
		Name = "TerminalViewFSM",
		ValidStates = { "Closed", "Open", "Minimized" },
		InitialState = "Closed",
		Priority = 5 -- Medium priority, UI logic doesn't need to be frame-perfect render step generally, but animations might.
	}
}

--[[
	@description Registers the Closed and Open states, toggled by the IsTogglePressed
	context flag. Each state calls SetVisible to show/hide the terminal panel.
]]
function TerminalViewFSM:RegisterStates()
	-- Shared Transitions
	local function OpenTransition(fsm)
		return fsm.Context.IsTogglePressed
	end
	
	local function CloseTransition(fsm)
		return fsm.Context.IsTogglePressed
	end

	-- State: Closed
	self:AddState("Closed", {
		OnEnter = function(fsm)
			fsm.Context.IsTogglePressed = false
			-- Ensure UI is hidden
			if fsm.Context.SetVisible then
				fsm.Context.SetVisible(false)
			end
		end,
		OnHeartbeat = function(fsm, dt)
			-- Listen for toggle? Or relying on Input Connection in Entity.
			-- If Entity handles input and sets context flag, transition happens here.
			if fsm.Context.IsTogglePressed then
				fsm:ChangeState({ Name = "Open" })
			end
		end,
	})

	-- State: Open
	self:AddState("Open", {
		OnEnter = function(fsm)
			fsm.Context.IsTogglePressed = false
			-- Show UI
			if fsm.Context.SetVisible then
				fsm.Context.SetVisible(true)
			end
		end,
		OnHeartbeat = function(fsm, dt)
			if fsm.Context.IsTogglePressed then
				fsm:ChangeState({ Name = "Closed" })
			end
		end
	})

end

return TerminalViewFSM
