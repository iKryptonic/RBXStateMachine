--!strict
-- @Name LocomotionFSM
-- @Author Copilot
-- @Description Client-side FSM that derives locomotion state from physics.
--   Writes LocomotionState to CharacterEntity for ServiceManager observability.

local LocomotionFSM = {
	Name = "LocomotionFSM",
	className = "LocomotionFSM",
	validStates = { "Idle", "Walking", "Running", "Airborne", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Idle",
}

local WALK_THRESHOLD = 2
local RUN_THRESHOLD = 22

local function getCharacterParts(fsm: any): (any?, any?, any?)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then return nil, nil, nil end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if not charEntity then return nil, nil, nil end
	local character = charEntity.Instance
	if not character then return nil, nil, nil end
	return charEntity, character:FindFirstChildOfClass("Humanoid"), character:FindFirstChild("HumanoidRootPart")
end

local function isAirborne(humanoid: any): boolean
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.FallingDown
end

local function getHorizontalSpeed(rootPart: any): number
	return (rootPart.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
end

local function writeState(fsm: any, state: string)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then return end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if charEntity then charEntity.LocomotionState = state end
end

function LocomotionFSM:RegisterStates()
	self:AddState("Idle", {
		OnEnter = function(_, fsm) writeState(fsm, "Idle") end,
		Transitions = {
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				return hum and root and isAirborne(hum)
			end, TargetState = "Airborne" },
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) > RUN_THRESHOLD
			end, TargetState = "Running" },
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) > WALK_THRESHOLD
			end, TargetState = "Walking" },
		},
	}, { "Walking", "Running", "Airborne" })

	self:AddState("Walking", {
		OnEnter = function(_, fsm) writeState(fsm, "Walking") end,
		Transitions = {
			{ Condition = function(fsm)
				local _, hum = getCharacterParts(fsm)
				return hum and isAirborne(hum)
			end, TargetState = "Airborne" },
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) > RUN_THRESHOLD
			end, TargetState = "Running" },
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) <= WALK_THRESHOLD
			end, TargetState = "Idle" },
		},
	}, { "Idle", "Running", "Airborne" })

	self:AddState("Running", {
		OnEnter = function(_, fsm) writeState(fsm, "Running") end,
		Transitions = {
			{ Condition = function(fsm)
				local _, hum = getCharacterParts(fsm)
				return hum and isAirborne(hum)
			end, TargetState = "Airborne" },
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) <= WALK_THRESHOLD
			end, TargetState = "Idle" },
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				return hum and root and not isAirborne(hum) and getHorizontalSpeed(root) <= RUN_THRESHOLD and getHorizontalSpeed(root) > WALK_THRESHOLD
			end, TargetState = "Walking" },
		},
	}, { "Idle", "Walking", "Airborne" })

	self:AddState("Airborne", {
		OnEnter = function(_, fsm) writeState(fsm, "Airborne") end,
		Transitions = {
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				if not hum or isAirborne(hum) then return false end
				return root and getHorizontalSpeed(root) > RUN_THRESHOLD
			end, TargetState = "Running" },
			{ Condition = function(fsm)
				local _, hum, root = getCharacterParts(fsm)
				if not hum or isAirborne(hum) then return false end
				return root and getHorizontalSpeed(root) > WALK_THRESHOLD
			end, TargetState = "Walking" },
			{ Condition = function(fsm)
				local _, hum = getCharacterParts(fsm)
				return hum and not isAirborne(hum)
			end, TargetState = "Idle" },
		},
	}, { "Idle", "Walking", "Running" })
end

return LocomotionFSM
