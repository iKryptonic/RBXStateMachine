--!strict
-- @Name LocomotionFSM
-- @Author Copilot
-- @Description Client-side FSM that derives locomotion state from physics.
--   Replaces the imperative if/elseif status chain. Writes LocomotionState
--   to the CharacterEntity for ServiceManager observability.

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
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return charEntity, humanoid, rootPart
end

local function getLocomotionData(humanoid: any, rootPart: any): (string, number)
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.FallingDown then
		return "Airborne", 0
	end
	local vel = rootPart.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
	return "Grounded", vel.Magnitude
end

local function writeLocomotionState(fsm: any, state: string)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then return end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if charEntity then
		charEntity.LocomotionState = state
	end
end

function LocomotionFSM:RegisterStates()
	self:AddState("Idle", {
		OnEnter = function(_, fsm)
			writeLocomotionState(fsm, "Idle")
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, humanoid, rootPart = getCharacterParts(fsm)
					if not humanoid or not rootPart then return false end
					local kind, speed = getLocomotionData(humanoid, rootPart)
					if kind == "Airborne" then return true end
					if speed > RUN_THRESHOLD then return true end
					if speed > WALK_THRESHOLD then return true end
					return false
				end,
				TargetState = function(fsm)
					local _, humanoid, rootPart = getCharacterParts(fsm)
					if not humanoid or not rootPart then return "Idle" end
					local kind, speed = getLocomotionData(humanoid, rootPart)
					if kind == "Airborne" then return "Airborne" end
					if speed > RUN_THRESHOLD then return "Running" end
					return "Walking"
				end,
			},
		},
	}, { "Walking", "Running", "Airborne" })

	self:AddState("Walking", {
		OnEnter = function(_, fsm)
			writeLocomotionState(fsm, "Walking")
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, humanoid, rootPart = getCharacterParts(fsm)
					if not humanoid or not rootPart then return false end
					local kind, speed = getLocomotionData(humanoid, rootPart)
					if kind == "Airborne" then return true end
					if speed > RUN_THRESHOLD then return true end
					if speed <= WALK_THRESHOLD then return true end
					return false
				end,
				TargetState = function(fsm)
					local _, humanoid, rootPart = getCharacterParts(fsm)
					if not humanoid or not rootPart then return "Idle" end
					local kind, speed = getLocomotionData(humanoid, rootPart)
					if kind == "Airborne" then return "Airborne" end
					if speed > RUN_THRESHOLD then return "Running" end
					return "Idle"
				end,
			},
		},
	}, { "Idle", "Running", "Airborne" })

	self:AddState("Running", {
		OnEnter = function(_, fsm)
			writeLocomotionState(fsm, "Running")
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, humanoid, rootPart = getCharacterParts(fsm)
					if not humanoid or not rootPart then return false end
					local kind, speed = getLocomotionData(humanoid, rootPart)
					if kind == "Airborne" then return true end
					if speed <= RUN_THRESHOLD then return true end
					return false
				end,
				TargetState = function(fsm)
					local _, humanoid, rootPart = getCharacterParts(fsm)
					if not humanoid or not rootPart then return "Idle" end
					local kind, speed = getLocomotionData(humanoid, rootPart)
					if kind == "Airborne" then return "Airborne" end
					if speed > WALK_THRESHOLD then return "Walking" end
					return "Idle"
				end,
			},
		},
	}, { "Idle", "Walking", "Airborne" })

	self:AddState("Airborne", {
		OnEnter = function(_, fsm)
			writeLocomotionState(fsm, "Airborne")
		end,
		Transitions = {
			{
				Condition = function(fsm)
					local _, humanoid, rootPart = getCharacterParts(fsm)
					if not humanoid or not rootPart then return false end
					local kind, speed = getLocomotionData(humanoid, rootPart)
					if kind == "Grounded" then return true end
					return false
				end,
				TargetState = function(fsm)
					local _, humanoid, rootPart = getCharacterParts(fsm)
					if not humanoid or not rootPart then return "Idle" end
					local _, speed = getLocomotionData(humanoid, rootPart)
					if speed > RUN_THRESHOLD then return "Running" end
					if speed > WALK_THRESHOLD then return "Walking" end
					return "Idle"
				end,
			},
		},
	}, { "Idle", "Walking", "Running" })
end

return LocomotionFSM
