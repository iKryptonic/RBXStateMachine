--!strict
-- @Name DashFSM
-- @Author iKrypto
-- @Description Client-side FSM managing dash lifecycle.
--   States: Ready → ValidateDash → ValidateStamina → DeductStamina → ApplyImpulse → PlaySound → TriggerAnimation → WriteOverlay → DashActive → ClearOverlay → Cooldown → Ready

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
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
	terminalStates = { "Completed", "Failed" },
	initialState = "Ready",
}

local IMPULSE = 200
local IMPULSE_DURATION = 0.35
local ACTIVE_DURATION = 0.4
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
	if not charEntity or not charEntity.Instance then
		return nil
	end
	return charEntity.Instance:FindFirstChild("HumanoidRootPart") :: BasePart?
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
	}, { "ValidateDash" })

	self:AddState("ValidateDash", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			local charEntity = getCharacterEntity(fsm)
			local rootPart = getRootPart(fsm)
			print(string.format("[DashFSM] ValidateDash: dir=%s entity=%s root=%s",
				tostring(direction), tostring(charEntity ~= nil), tostring(rootPart ~= nil)))
			if not direction or not rootPart or not charEntity then
				fsm.State = "Ready"
				return
			end

			fsm.Context._charEntity = charEntity
			fsm.Context._rootPart = rootPart
			fsm.State = "ValidateStamina"
		end,
	}, { "ValidateStamina", "Ready" })

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
	}, { "DeductStamina", "Ready" })

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
	}, { "ApplyImpulse", "Ready" })

	self:AddState("ApplyImpulse", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			local rootPart = fsm.Context._rootPart
			print(string.format("[DashFSM] ApplyImpulse: dir=%s root=%s", tostring(direction), tostring(rootPart ~= nil)))
			if not direction or not rootPart or not rootPart.Parent then
				print("[DashFSM] ApplyImpulse BAIL: missing root or direction")
				fsm.State = "Ready"
				return
			end

			local impulseDir = getImpulseDirection(rootPart, direction)
			if not impulseDir then
				print("[DashFSM] ApplyImpulse BAIL: no impulse direction")
				fsm.State = "Ready"
				return
			end

			-- Freeze WalkSpeed to prevent Humanoid controller from fighting the impulse
			local humanoid = rootPart.Parent and rootPart.Parent:FindFirstChildOfClass("Humanoid")
			if humanoid then
				fsm.Context._savedWalkSpeed = humanoid.WalkSpeed
				humanoid.WalkSpeed = 0
			end

			-- Use AssemblyLinearVelocity directly (matches legacy dash behavior)
			local vel = impulseDir * IMPULSE
			rootPart.AssemblyLinearVelocity = Vector3.new(vel.X, rootPart.AssemblyLinearVelocity.Y, vel.Z)

			print(string.format("[DashFSM] ApplyImpulse: velocity=%s", tostring(vel)))
			fsm.State = "PlaySound"
		end,
	}, { "PlaySound", "Ready" })

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
	}, { "TriggerAnimation" })

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
	}, { "WriteOverlay" })

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
	}, { "DashActive", "Ready" })

	self:AddState("DashActive", {
		OnEnter = function(_, fsm)
			fsm.Context._dashStartTime = os.clock()
		end,
		OnHeartbeat = function(_, fsm, _dt)
			local elapsed = os.clock() - (fsm.Context._dashStartTime or os.clock())
			if elapsed >= ACTIVE_DURATION then
				fsm.State = "ClearOverlay"
				return
			end
			-- Sustain velocity each frame (matches legacy 8-tick loop)
			local rootPart = fsm.Context._rootPart
			local direction = fsm.Context._dashDirection
			if rootPart and rootPart.Parent and direction then
				local impulseDir = getImpulseDirection(rootPart, direction)
				if impulseDir then
					local vel = impulseDir * IMPULSE
					rootPart.AssemblyLinearVelocity = Vector3.new(vel.X, rootPart.AssemblyLinearVelocity.Y, vel.Z)
				end
			end
		end,
	}, { "ClearOverlay" })

	self:AddState("ClearOverlay", {
		OnEnter = function(_, fsm)
			local charEntity = fsm.Context._charEntity or getCharacterEntity(fsm)
			if charEntity then
				charEntity.ActionOverlay = "None"
			end
			-- Restore WalkSpeed
			local rootPart = fsm.Context._rootPart
			if rootPart and rootPart.Parent then
				local humanoid = rootPart.Parent:FindFirstChildOfClass("Humanoid")
				if humanoid and fsm.Context._savedWalkSpeed then
					humanoid.WalkSpeed = fsm.Context._savedWalkSpeed
				end
			end
			fsm.State = "Cooldown"
		end,
	}, { "Cooldown" })

	self:AddState("Cooldown", {
		OnEnter = function(_, fsm)
			fsm:ScheduleTransition(COOLDOWN, "Ready")
		end,
	}, { "Ready" })

	self:AddState("Completed", function() end, {})
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
