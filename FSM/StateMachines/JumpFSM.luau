--!strict
-- @Name JumpFSM
-- @Author Copilot
-- @Description Client-side FSM managing double jump lifecycle.
--   States: Grounded → InAir → Flipping → Cooldown → Grounded
--   Replaces imperative DoubleJumpController with observable state machine.

local Debris = game:GetService("Debris")

local JumpFSM = {
	Name = "JumpFSM",
	className = "JumpFSM",
	validStates = { "Grounded", "InAir", "Flipping", "Cooldown", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Grounded",
}

local UPWARD_VELOCITY = 55
local JUMP_SOUND_ID = "rbxassetid://541909814"
local LAND_SOUND_ID = "rbxassetid://1248511833"
local FLIP_FRAMES = 12
local FLIP_ANGLE_STEP = 30
local COOLDOWN_DURATION = 1

local function getCharacterParts(fsm: any): (BasePart?, Humanoid?, BasePart?)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then return nil, nil, nil end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if not charEntity or not charEntity.Instance then return nil, nil, nil end
	local character = charEntity.Instance
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local torso = character:FindFirstChild("Torso")
	return rootPart :: BasePart?, humanoid :: Humanoid?, torso :: BasePart?
end

local function isAirborne(humanoid: Humanoid): boolean
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.FallingDown
end

function JumpFSM:RegisterStates()
	self:AddState("Grounded", {
		Transitions = {
			{
				Condition = function(fsm)
					local _, humanoid = getCharacterParts(fsm)
					if not humanoid then return false end
					return isAirborne(humanoid)
				end,
				TargetState = "InAir",
			},
		},
	}, { "InAir" })

	self:AddState("InAir", {
		OnEnter = function(_, fsm)
			fsm.Context._flipRequested = false
		end,
		Transitions = {
			{
				Condition = function(fsm)
					return fsm.Context._flipRequested == true
				end,
				TargetState = "Flipping",
			},
			{
				Condition = function(fsm)
					local _, humanoid = getCharacterParts(fsm)
					if not humanoid then return false end
					return not isAirborne(humanoid)
				end,
				TargetState = "Grounded",
			},
		},
	}, { "Flipping", "Grounded" })

	self:AddState("Flipping", {
		OnEnter = function(_, fsm)
			local rootPart, humanoid = getCharacterParts(fsm)
			if not rootPart or not humanoid then
				fsm.State = "Grounded"
				return
			end

			-- Sound
			local sound = Instance.new("Sound")
			sound.SoundId = JUMP_SOUND_ID
			sound.Volume = 0.5
			sound.Parent = rootPart
			sound:Play()
			Debris:AddItem(sound, 2)

			-- FrontFlip animation
			local onAnimate = fsm.Context._onAnimate
			if onAnimate then
				task.spawn(function()
					onAnimate("FrontFlip", 0.1, 0.15)
				end)
			end

			-- Sustained upward force during flip
			local bv = Instance.new("BodyVelocity")
			bv.MaxForce = Vector3.new(0, math.huge, 0)
			bv.Velocity = Vector3.new(0, UPWARD_VELOCITY, 0)
			bv.Parent = rootPart

			-- RootJoint.C0 rotation for visual flip
			task.spawn(function()
				local rootJoint = rootPart:FindFirstChild("RootJoint")
				if not rootJoint then
					bv:Destroy()
					return
				end

				local origC0 = rootJoint.C0
				for i = 1, FLIP_FRAMES do
					rootJoint.C0 = origC0 * CFrame.Angles(math.rad(-FLIP_ANGLE_STEP * i), 0, 0)
					task.wait()
				end
				rootJoint.C0 = origC0
				bv:Destroy()
			end)
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, humanoid = getCharacterParts(fsm)
					if not humanoid then return true end
					return not isAirborne(humanoid)
				end,
				TargetState = "Cooldown",
			},
		},
		-- Fallback timeout if we never land (e.g. void)
		Timeout = 3,
		OnTimeout = "Cooldown",
	}, { "Cooldown" })

	self:AddState("Cooldown", {
		OnEnter = function(_, fsm)
			local rootPart = getCharacterParts(fsm)
			if rootPart and rootPart.Parent then
				local sound = Instance.new("Sound")
				sound.SoundId = LAND_SOUND_ID
				sound.Volume = 0.35
				sound.PlaybackSpeed = 0.9
				sound.Parent = rootPart
				sound:Play()
				Debris:AddItem(sound, 2)

				local onAnimate = fsm.Context._onAnimate
				if onAnimate then
					onAnimate("SummonGroundCast")
				end
			end
		end,
		Timeout = COOLDOWN_DURATION,
		OnTimeout = "Grounded",
	}, { "Grounded" })
end

-- Public API: request a double jump flip
function JumpFSM.TryDoubleJump(fsm: any): boolean
	if fsm.State ~= "InAir" then
		return false
	end
	fsm.Context._flipRequested = true
	return true
end

return JumpFSM
