--!strict


local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers,"Helpers folder not found")
local ResourceHelpers = require(Helpers:WaitForChild("ResourceHelpers"))

local DashFSM = {
	Name = "DashFSM",
	className = "DashFSM",
	validStates = {
		"Ready",
		"ValidateDash",
		"ValidateStamina",
		"DeductStamina",
		"ApplyImpulse",
		"PlaySound",
		"TriggerAnimation",
		"WriteOverlay",
		"DashActive",
		"ClearOverlay",
		"Cooldown",
		"Completed",
		"Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Ready",
}

local IMPULSE = 75
local IMPULSE_DURATION = 0.1
local ACTIVE_DURATION = 0.25
local COOLDOWN = 0.75
local DASH_STAMINA_COST = 15
local DASH_SOUND_ID = "rbxassetid://541909814"

local DIRECTION_MAP = {
	W = "Dashing",
	A = "DashLeft",
	S = "DashEnd",
	D = "DashRight",
}

local function getCharacterEntity(fsm: any): any?
	return fsm:GetEntity(fsm.CharacterEntityId)
end

local function getRootPart(fsm: any): BasePart?
	local charEntity = getCharacterEntity(fsm)
	if charEntity and charEntity.Instance then
		local root = charEntity.Instance:FindFirstChild("HumanoidRootPart")
		if root then return root :: BasePart? end
	end
	-- Fallback: get from LocalPlayer.Character directly
	local Players = game:GetService("Players")
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		return localPlayer.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return nil
end

local function getImpulseDirection(rootPart: BasePart, direction: string): Vector3?
	local lookVector = rootPart.CFrame.LookVector
	local rightVector = rootPart.CFrame.RightVector
	if direction == "W" then
		return lookVector
	elseif direction == "S" then
		return -lookVector
	elseif direction == "A" then
		return -rightVector
	elseif direction == "D" then
		return rightVector
	end
	return nil
end


function DashFSM:RegisterStates()


	self:AddState("Ready", {
		OnEnter = function(_, fsm)
			fsm.Context._dashDirection = nil
			fsm.Context._charEntity = nil
			fsm.Context._rootPart = nil
		end,
	}, {"ValidateDash" })


	self:AddState("ValidateDash", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			local charEntity = getCharacterEntity(fsm)
			local rootPart = getRootPart(fsm)
			if not direction or not rootPart or not charEntity then
				fsm.State = "Ready"
				return
			end

			fsm.Context._charEntity = charEntity
			fsm.Context._rootPart = rootPart
			fsm.State = "ValidateStamina"
		end,
	}, {"ValidateStamina","Ready" })


	self:AddState("ValidateStamina", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity or getCharacterEntity(fsm)
			local stamina = tonumber(charEntity and charEntity.Stamina) or 0
			if not charEntity or stamina < DASH_STAMINA_COST then
				fsm.State = "Ready"
				return
			end
			fsm.State = "DeductStamina"
		end,
	}, {"DeductStamina","Ready" })


	self:AddState("DeductStamina", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			if not charEntity then
				fsm.State = "Ready"
				return
			end

			if not ResourceHelpers.deductStamina(charEntity, DASH_STAMINA_COST) then
				fsm.State = "Ready"
				return
			end
			pcall(function()
				charEntity:UpdateEntity()
			end)
			fsm.State = "ApplyImpulse"
		end,
	}, {"ApplyImpulse","Ready" })


	self:AddState("ApplyImpulse", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			local rootPart = fsm.Context._rootPart
			if not direction or not rootPart or not rootPart.Parent then
				fsm.State = "Ready"
				return
			end

			local impulseDir = getImpulseDirection(rootPart, direction)
			if not impulseDir then
				fsm.State = "Ready"
				return
			end

			-- BodyVelocity impulse (matches legacy DashController)
			local bodyVelocity = Instance.new("BodyVelocity")
			bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
			bodyVelocity.Velocity = impulseDir * IMPULSE
			bodyVelocity.Parent = rootPart
			Debris:AddItem(bodyVelocity, IMPULSE_DURATION)
			fsm.State = "PlaySound"
		end,
	}, {"PlaySound","Ready" })


	self:AddState("PlaySound", {
		OnEnter = function(_, fsm)
			local rootPart = fsm.Context._rootPart
			if rootPart and rootPart.Parent then
				local sound = Instance.new("Sound")
				sound.SoundId = DASH_SOUND_ID
				sound.Volume = 0.5
				sound.Parent = rootPart
				sound:Play()
				Debris:AddItem(sound, 2)
			end
			fsm.State = "TriggerAnimation"
		end,
	}, {"TriggerAnimation" })


	self:AddState("TriggerAnimation", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			local onAnimate = fsm.Context._onAnimate
			local animationName = DIRECTION_MAP[direction] or "Dashing"
			if onAnimate then
				onAnimate(animationName)
			end
			fsm.State = "WriteOverlay"
		end,
	}, {"WriteOverlay" })


	self:AddState("WriteOverlay", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity
			local direction = fsm.Context._dashDirection
			if not charEntity or not direction then
				fsm.State = "Ready"
				return
			end

			charEntity.ActionOverlay = "Dash_" .. direction
			fsm.State = "DashActive"
		end,
	}, {"DashActive","Ready" })


	self:AddState("DashActive", {
		OnEnter = function(_, fsm)
			fsm:ScheduleTransition(ACTIVE_DURATION,"ClearOverlay")
		end,
	}, {"ClearOverlay" })


	self:AddState("ClearOverlay", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity or getCharacterEntity(fsm)
			if charEntity then
				charEntity.ActionOverlay = "None"
			end
			fsm.State = "Cooldown"
		end,
	}, {"Cooldown" })


	self:AddState("Cooldown", {
		OnEnter = function(_, fsm)
			fsm:ScheduleTransition(COOLDOWN,"Ready")
		end,
	}, {"Ready" })
	--[=[
	@state Completed
	@description Terminal success sink reserved for explicit shutdown of the dash FSM. Normal dash requests clear the overlay and return to `Ready` after cooldown instead of terminating here.
		Transitions: none.
		Writes: none.
]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink reserved for future hard dash errors. Current validation failures fall back to `Ready`, so `OnEnter` is a no-op.
		Transitions: none.
		Writes: none.
]=]

	self:AddState("Failed", function() end, {})
end


function DashFSM.TryDash(fsm: any, direction: string): boolean
	if fsm.State ~= "Ready" then
		return false
	end
	fsm.Context._dashDirection = direction
	fsm.State = "ValidateDash"
	return true
end

return DashFSM
