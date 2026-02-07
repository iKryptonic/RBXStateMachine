--!strict
-- DoorEntity.lua
-- Entity class for Door objects, handling visual and domain logic.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DoorEntity = {
	Name = "DoorEntity",
	Replication = {
		Enabled = true,
		RateLimit = 60,
	},
	Schema = {
		IsOpen = { Type = "boolean", Replicate = true, Description = "True = Open, False = Closed" },
		Locked = { Type = "boolean", Replicate = true, Description = "Part is locked" },
		Color  = { Type = "Color3", Replicate = true,  Description = "Status light color" },
		_lockUI = { Type = "Instance" },
		_hinge = { Type = "BasePart" },
		_door = { Type = "BasePart" },
		_closedCFrame = { Type = "CFrame" },
		_statusLight = { Type = "BasePart" },
	},
}

--[[
	@description Initializes this entity's context (cached parts, initial state).
	@param params { [any]: any }
	@return ()
]]
function DoorEntity:GetContext(params: {[any]: any})
	-- Cache parts and initial state
	local _hinge = self.Instance:WaitForChild("Hinge", 5)
	local _door = self.Instance:WaitForChild("DoorPart", 5)
	local _statusLight = self.Instance:WaitForChild("StatusLight", 5)
	local _lockUI = self.Instance:WaitForChild("LockUI", 5)
	local IsOpen = self.IsOpen or false
	local Locked = self.Locked or true

	if not _hinge then
		warn("DoorEntity: Hinge not found on " .. self.Instance:GetFullName())
		return
	end

	return self {
		_hinge = _hinge,
		_door = _door,
		_statusLight = _statusLight,
		_lockUI = _lockUI,
		_closedCFrame = _hinge.CFrame,
		IsOpen = IsOpen,
		Locked = Locked
	}
end

-- Visual Logic
-- This only runs when the FSM calls :UpdateEntity()
--[[
	@description Applies pending property changes to the door model (visual updates).
	@param changes { [string]: any }
	@return ()
]]
function DoorEntity:ApplyChanges(changes)
	if not RunService:IsClient() then return end;
	local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	-- HANDLE MOVEMENT
	if changes.IsOpen ~= nil and self._hinge then
		local targetCFrame
		if changes.IsOpen then
			-- Rotate 90 degrees to Open
			targetCFrame = self._closedCFrame * CFrame.Angles(0, math.rad(90), 0)
		else
			-- Return to Closed
			targetCFrame = self._closedCFrame
		end

		local Tween = TweenService:Create(self._hinge, tweenInfo, { CFrame = targetCFrame })

		Tween:Play();

		-- Optional: Play Sound 
		local sound = changes.IsOpen and self._hinge:FindFirstChild("OpenSound") 
			or self._hinge:FindFirstChild("CloseSound")
		if sound then sound:Play() end
	end

	-- HANDLE STATUS LIGHTS
	if changes.Color then
		if self._statusLight then
			self._statusLight.Color = changes.Color
			self._statusLight.Material = Enum.Material.Neon
		end
	end

	-- HANDLE LOCK UI
	if changes.Locked ~= nil then
		local gui = self.Instance:FindFirstChild("LockUI")
		if gui then gui.Enabled = changes.Locked end
	end
end

-- Domain Logic
-- Encapsulates the business rules for the entity
--[[
	@description Opens the door and commits changes.
	@return boolean
]]
function DoorEntity:Open()
	self.IsOpen = true
	self.Color = Color3.fromRGB(0, 255, 0) -- Turn light Green
	self.Locked = false
	return self:UpdateEntity()
end

--[[
	@description Closes the door and commits changes.
	@return boolean
]]
function DoorEntity:Close()
	self.IsOpen = false
	self.Color = Color3.fromRGB(255, 0, 0) -- Turn light Red
	self.Locked = true
	return self:UpdateEntity()
end

--[[
	@description Resets the door to a neutral state and commits changes.
	@return boolean
]]
function DoorEntity:Reset()
	self.Color = Color3.fromRGB(255, 255, 0) -- Yellow
	return self:UpdateEntity()
end

return DoorEntity