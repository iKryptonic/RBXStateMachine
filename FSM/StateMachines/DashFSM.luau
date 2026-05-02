--!strict
-- @Name DashFSM
-- @Author Copilot
-- @Description Client-side FSM managing dash lifecycle.
--   States: Ready → Dashing → Cooldown → Ready
--   Replaces imperative DashController with observable state machine.

local Debris = game:GetService("Debris")

local DashFSM = {
	Name = "DashFSM",
	className = "DashFSM",
	validStates = { "Ready", "Dashing", "Cooldown", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Ready",
}

local IMPULSE = 75
local IMPULSE_DURATION = 0.1
local COOLDOWN = 0.75
local DASH_SOUND_ID = "rbxassetid://541909814"

local DIRECTION_MAP = {
	W = "Dashing",
	A = "DashLeft",
	S = "DashEnd",
	D = "DashRight",
}

local function getCharacterParts(fsm: any): (BasePart?, Humanoid?)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then return nil, nil end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if not charEntity or not charEntity.Instance then return nil, nil end
	local rootPart = charEntity.Instance:FindFirstChild("HumanoidRootPart")
	local humanoid = charEntity.Instance:FindFirstChildOfClass("Humanoid")
	return rootPart :: BasePart?, humanoid :: Humanoid?
end

function DashFSM:RegisterStates()
	self:AddState("Ready", {
		OnEnter = function(_, fsm)
			fsm.Context._dashDirection = nil
		end,
	}, { "Dashing" })

	self:AddState("Dashing", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection
			if not direction then
				fsm.State = "Ready"
				return
			end

			local rootPart, _ = getCharacterParts(fsm)
			if not rootPart or not rootPart.Parent then
				fsm.State = "Ready"
				return
			end

			local orchestrator = (shared :: any).fsm
			local charEntity = orchestrator and orchestrator.GetEntity(fsm.CharacterEntityId)
			if charEntity then
				local staminaCost = 15
				if (charEntity.Stamina or 0) < staminaCost then
					fsm.State = "Ready"
					return
				end
				charEntity.Stamina = math.max(0, (charEntity.Stamina or 100) - staminaCost)
				pcall(function() charEntity:UpdateEntity() end)
			end

			-- Calculate impulse direction
			local lookVector = rootPart.CFrame.LookVector
			local rightVector = rootPart.CFrame.RightVector
			local impulseDir: Vector3
			if direction == "W" then
				impulseDir = lookVector
			elseif direction == "S" then
				impulseDir = -lookVector
			elseif direction == "A" then
				impulseDir = -rightVector
			elseif direction == "D" then
				impulseDir = rightVector
			else
				fsm.State = "Ready"
				return
			end

			-- Apply impulse
			local bodyVelocity = Instance.new("BodyVelocity")
			bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
			bodyVelocity.Velocity = impulseDir * IMPULSE
			bodyVelocity.Parent = rootPart
			Debris:AddItem(bodyVelocity, IMPULSE_DURATION)

			-- Sound
			local sound = Instance.new("Sound")
			sound.SoundId = DASH_SOUND_ID
			sound.Volume = 0.5
			sound.Parent = rootPart
			sound:Play()
			Debris:AddItem(sound, 2)

			-- Play animation via callback
			local onAnimate = fsm.Context._onAnimate
			local animationName = DIRECTION_MAP[direction] or "Dashing"
			if onAnimate then
				onAnimate(animationName)
			end

			-- Write observable state
			local orchestrator = (shared :: any).fsm
			if orchestrator then
				local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
				if charEntity then
					charEntity.ActionOverlay = "Dash_" .. direction
				end
			end
		end,
		Timeout = 0.25,
		OnTimeout = "Cooldown",
	}, { "Cooldown", "Ready" })

	self:AddState("Cooldown", {
		OnEnter = function(_, fsm)
			-- Clear overlay
			local orchestrator = (shared :: any).fsm
			if orchestrator then
				local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
				if charEntity then
					charEntity.ActionOverlay = "None"
				end
			end
		end,
		Timeout = COOLDOWN,
		OnTimeout = "Ready",
	}, { "Ready" })
end

-- Public API: request a dash (called from InputRouter)
function DashFSM.TryDash(fsm: any, direction: string): boolean
	if fsm.State ~= "Ready" then
		return false
	end
	fsm.Context._dashDirection = direction
	fsm.State = "Dashing"
	return true
end

return DashFSM
