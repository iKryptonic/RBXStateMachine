--!strict
-- @Name CharacterSetupFSM
-- @Author Copilot
-- @Description Foundation client FSM for deterministic character bootstrap and teardown.

local CharacterSetupFSM = {
	Name = "CharacterSetupFSM",
	className = "CharacterSetupFSM",
	validStates = { "Validating", "DisablingDefaults", "AwaitingEntities", "InitControllers", "InitFSMs", "BindingEvents", "Active", "TearingDown", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Validating",
}

local sharedAny = shared :: any

-- TODO: Prefer fsm:GetOrchestrator() / fsm:GetEntity() now that Orchestrator injects itself into Context.
local function getOrchestrator()
	local lower = sharedAny.fsm
	if lower ~= nil then
		return lower.Orchestrator or lower
	end

	local upper = sharedAny.FSM
	if upper ~= nil and upper.Orchestrator then
		return upper.Orchestrator
	end

	return nil
end

local function destroyManaged(value: any)
	if value == nil then
		return
	end
	if typeof(value) == "RBXScriptConnection" then
		value:Disconnect()
		return
	end
	if typeof(value) == "Instance" then
		value:Destroy()
		return
	end
	if type(value) == "function" then
		value()
		return
	end
	if type(value) == "table" then
		if type(value.Cancel) == "function" and value.IsActive then
			value:Cancel()
			return
		end
		if type(value.Destroy) == "function" then
			value:Destroy()
			return
		end
		for _, child in pairs(value) do
			destroyManaged(child)
		end
	end
end

local function restoreDefaults(fsm: any)
	local defaultAnimate = fsm.Context._defaultAnimate
	if defaultAnimate and defaultAnimate.Parent and fsm.Context._defaultAnimateWasDisabled == false then
		defaultAnimate.Disabled = false
	end

	local humanoid = fsm.Context.Humanoid
	local animator = fsm.Context._removedAnimator
	if humanoid and animator and animator.Parent == nil then
		animator.Parent = humanoid
	end
end

local function getCharacterModel(fsm: any): Model?
	local character = fsm.Context.Character or fsm.Context.Instance
	if character and character:IsA("Model") then
		return character
	end
	return nil
end

local function getRequiredParts(character: Model)
	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
	local limbs = {
		RightArm = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand"),
		LeftArm = character:FindFirstChild("Left Arm") or character:FindFirstChild("LeftHand"),
		RightLeg = character:FindFirstChild("Right Leg") or character:FindFirstChild("RightLowerLeg"),
		LeftLeg = character:FindFirstChild("Left Leg") or character:FindFirstChild("LeftLowerLeg"),
	}

	return {
		Humanoid = character:FindFirstChildOfClass("Humanoid"),
		RootPart = character:FindFirstChild("HumanoidRootPart"),
		Torso = torso,
		Head = character:FindFirstChild("Head"),
		Limbs = limbs,
	}
end

local function safeInvoke(factory: any, fsm: any, ...: any): any
	if type(factory) ~= "function" then
		return nil
	end

	local ok, result = pcall(factory, fsm, ...)
	if not ok then
		fsm:Log({ Level = "WARN", Message = string.format("CharacterSetupFSM callback failed: %s", tostring(result)) })
		return nil
	end
	return result
end

function CharacterSetupFSM:RegisterStates()
	self:AddState("Validating", {
		OnEnter = function(_, fsm)
			local character = getCharacterModel(fsm)
			if not character then
				fsm:Fail("CharacterSetupFSM requires a Character model in Context.Character or Context.Instance")
				return
			end

			local parts = getRequiredParts(character)
			local missing = {}
			if not parts.Humanoid then table.insert(missing, "Humanoid") end
			if not parts.RootPart then table.insert(missing, "HumanoidRootPart") end
			if not parts.Torso then table.insert(missing, "Torso") end
			if not parts.Head then table.insert(missing, "Head") end
			for limbName, limb in pairs(parts.Limbs) do
				if not limb then
					table.insert(missing, limbName)
				end
			end

			if #missing > 0 then
				fsm:Fail("Character missing required parts: " .. table.concat(missing, ", "))
				return
			end

			fsm.Context.Character = character
			fsm.Context.Humanoid = parts.Humanoid
			fsm.Context.RootPart = parts.RootPart
			fsm.Context.Torso = parts.Torso
			fsm.Context.Head = parts.Head
			fsm.Context.Limbs = parts.Limbs
			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM validated %s", character:GetFullName()) })
			fsm.State = "DisablingDefaults"
		end,
	}, { "DisablingDefaults", "Failed" })

	self:AddState("DisablingDefaults", {
		OnEnter = function(_, fsm)
			local character = fsm.Context.Character
			local humanoid = fsm.Context.Humanoid
			local defaultAnimate = character and character:FindFirstChild("Animate")
			if defaultAnimate and defaultAnimate:IsA("LocalScript") then
				fsm.Context._defaultAnimate = defaultAnimate
				fsm.Context._defaultAnimateWasDisabled = defaultAnimate.Disabled
				defaultAnimate.Disabled = true
			end

			local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
			if animator then
				fsm.Context._removedAnimator = animator
				animator.Parent = nil
			end

			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM disabled defaults for %s", tostring(fsm.CharacterEntityId or character.Name)) })
			fsm.State = "AwaitingEntities"
		end,
	}, { "AwaitingEntities", "Failed" })

	self:AddState("AwaitingEntities", {
		OnEnter = function(_, fsm)
			fsm.Context._awaitStartedAt = os.clock()
			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM awaiting entities for %s", tostring(fsm.CharacterEntityId or "unknown")) })
			fsm:ScheduleTransition(10, "Failed", { "Timed out waiting for CharacterEntity/PlayerEntity" })
		end,
		OnHeartbeat = function(_, fsm)
			local orchestrator = getOrchestrator()
			if not orchestrator then
				return
			end

			local charEntity = if typeof(fsm.CharacterEntityId) == "string" then orchestrator.GetEntity(fsm.CharacterEntityId) else nil
			local playerEntity = if typeof(fsm.PlayerEntityId) == "string" then orchestrator.GetEntity(fsm.PlayerEntityId) else nil
			if charEntity and playerEntity then
				fsm:CancelScheduledTransition()
				fsm.Context.CharacterEntity = charEntity
				fsm.Context.PlayerEntity = playerEntity
				fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM resolved entities for %s", tostring(fsm.CharacterEntityId)) })
				fsm.State = "InitControllers"
			end
		end,
	}, { "InitControllers", "Failed" })

	self:AddState("InitControllers", {
		OnEnter = function(_, fsm)
			local bundle = safeInvoke(fsm.Context.CreateControllerBundle, fsm) or {}
			fsm.Context.ReferenceAnimationPlayer = bundle.ReferenceAnimationPlayer
			fsm.Context.RenderRouter = bundle.RenderRouter
			fsm.Context.DashController = bundle.DashController
			fsm.Context.DoubleJumpController = bundle.DoubleJumpController
			fsm.Context.HitReactController = bundle.HitReactController
			fsm.Context.InputRouter = bundle.InputRouter
			fsm.Context.InventoryGui = bundle.InventoryGui
			fsm.Context.TargetingSystem = bundle.TargetingSystem
			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM initialized controller bundle for %s", tostring(fsm.CharacterEntityId)) })
			fsm.State = "InitFSMs"
		end,
	}, { "InitFSMs", "Failed" })

	self:AddState("InitFSMs", {
		OnEnter = function(_, fsm)
			local bundle = safeInvoke(fsm.Context.CreateFSMBundle, fsm) or {}
			fsm.Context.LocomotionFSM = bundle.LocomotionFSM
			fsm.Context.ActionFSM = bundle.ActionFSM
			fsm.Context.DashFSM = bundle.DashFSM
			fsm.Context.JumpFSM = bundle.JumpFSM
			fsm.Context.InputFSM = bundle.InputFSM
			fsm.Context.InputModeFSM = bundle.InputModeFSM
			fsm.Context.AnimationStateFSM = bundle.AnimationStateFSM
			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM initialized FSM bundle for %s", tostring(fsm.CharacterEntityId)) })
			fsm.State = "BindingEvents"
		end,
	}, { "BindingEvents", "Failed" })

	self:AddState("BindingEvents", {
		OnEnter = function(_, fsm)
			fsm.Context.Connections = safeInvoke(fsm.Context.BindEvents, fsm) or {}
			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM bound events for %s", tostring(fsm.CharacterEntityId)) })
			fsm.State = "Active"
		end,
	}, { "Active", "Failed" })

	self:AddState("Active", {
		OnEnter = function(_, fsm)
			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM active for %s", tostring(fsm.CharacterEntityId)) })
		end,
		OnHeartbeat = function(_, fsm)
			local character = fsm.Context.Character
			local humanoid = fsm.Context.Humanoid
			if not character or character.Parent == nil then
				fsm.State = "TearingDown"
				return
			end
			if humanoid and humanoid.Health <= 0 then
				fsm.State = "TearingDown"
			end
		end,
	}, { "TearingDown", "Failed" })

	self:AddState("TearingDown", {
		OnEnter = function(_, fsm)
			safeInvoke(fsm.Context.OnPreTeardown, fsm)
			destroyManaged(fsm.Context.Connections)
			destroyManaged({
				fsm.Context.InputRouter,
				fsm.Context.TargetingSystem,
				fsm.Context.InventoryGui,
				fsm.Context.RenderRouter,
				fsm.Context.ReferenceAnimationPlayer,
				fsm.Context.DashController,
				fsm.Context.DoubleJumpController,
				fsm.Context.HitReactController,
				fsm.Context.LocomotionFSM,
				fsm.Context.ActionFSM,
				fsm.Context.DashFSM,
				fsm.Context.JumpFSM,
				fsm.Context.InputFSM,
				fsm.Context.InputModeFSM,
				fsm.Context.AnimationStateFSM,
			})
			safeInvoke(fsm.Context.RestoreDefaults, fsm)
			restoreDefaults(fsm)
			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM tore down %s", tostring(fsm.CharacterEntityId)) })
			fsm.State = "Completed"
		end,
	}, { "Completed" })

	self:AddState("Completed", {
		OnEnter = function(_, fsm)
			fsm:Log({ Level = "INFO", Message = string.format("CharacterSetupFSM completed for %s", tostring(fsm.CharacterEntityId)) })
		end,
	}, {})

	self:AddState("Failed", {
		OnEnter = function(_, fsm, reason)
			fsm:Log({ Level = "ERROR", Message = string.format("CharacterSetupFSM failed for %s: %s", tostring(fsm.CharacterEntityId), tostring(reason or "unknown error")) })
			destroyManaged(fsm.Context.Connections)
			safeInvoke(fsm.Context.RestoreDefaults, fsm)
			restoreDefaults(fsm)
		end,
	}, {})
end

return CharacterSetupFSM
