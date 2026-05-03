--!strict
--[=[
	@module ActionFSM
	@description Defines the `ActionFSM` state machine module and its exported API.
]=]

local ActionFSM = {
	Name = "ActionFSM",
	className = "ActionFSM",
	validStates = {
		"None",
		"MeleeWindup",
		"MeleeStrike",
		"MeleeRecovery",
		"Dashing",
		"Flipping",
		"HitReact",
		"Completed",
		"Failed",
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "None",
}

local function getCharEntity(fsm: any): any?
	local orchestrator = (shared :: any).fsm
	if not orchestrator then
		return nil
	end
	return orchestrator.GetEntity(fsm.CharacterEntityId)
end

local function writeActionOverlay(fsm: any, overlay: string)
	local charEntity = getCharEntity(fsm)
	if charEntity then
		charEntity.ActionOverlay = overlay
	end
end
--[=[
	@description Handles `RegisterStates` for `ActionFSM`.
	@param none nil -- This function does not accept explicit parameters.
	@return any -- Return value produced by the implementation, if any.
]=]

function ActionFSM:RegisterStates()
	--[=[
		@state None
		@description Handles the `None` state for `ActionFSM`.
	]=]

	self:AddState("None", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm, "None")
			fsm.Context._currentMove = nil
			fsm.Context._movePhases = nil
			fsm.Context._phaseIndex = nil
		end,
	}, { "MeleeWindup", "Dashing", "Flipping", "HitReact" })
	--[=[
		@state MeleeWindup
		@description Handles the `MeleeWindup` state for `ActionFSM`.
	]=]

	self:AddState("MeleeWindup", {
		OnEnter = function(_, fsm)
			local phases = fsm.Context._movePhases
			if not phases or #phases == 0 then
				fsm.State = "None"
				return
			end
			fsm.Context._phaseIndex = 1
			local phase = phases[1]
			writeActionOverlay(fsm, phase.Name or "MeleeWindup")

			-- Play animation via callback
			local onAnimate = fsm.Context._onAnimate
			if onAnimate then
				onAnimate(phase.Name, phase.Speed, 0.1)
			end
		end,
		Timeout = nil, -- set dynamically in OnEnter
		OnTimeout = "MeleeStrike",
	}, { "MeleeStrike", "None" })
	--[=[
		@state MeleeStrike
		@description Handles the `MeleeStrike` state for `ActionFSM`.
	]=]

	self:AddState("MeleeStrike", {
		OnEnter = function(_, fsm)
			local phases = fsm.Context._movePhases
			local idx = (fsm.Context._phaseIndex or 1) + 1
			fsm.Context._phaseIndex = idx

			if not phases or idx > #phases then
				-- No more phases, go to recovery
				fsm.State = "MeleeRecovery"
				return
			end

			local phase = phases[idx]
			writeActionOverlay(fsm, phase.Name or "MeleeStrike")

			local onAnimate = fsm.Context._onAnimate
			if onAnimate then
				onAnimate(phase.Name, phase.Speed, 0.1)
			end
		end,
	}, { "MeleeRecovery", "None" })
	--[=[
		@state MeleeRecovery
		@description Handles the `MeleeRecovery` state for `ActionFSM`.
	]=]

	self:AddState("MeleeRecovery", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm, "Recovery")
		end,
		Timeout = 0.1,
		OnTimeout = "None",
	}, { "None" })
	--[=[
		@state Dashing
		@description Handles the `Dashing` state for `ActionFSM`.
	]=]

	self:AddState("Dashing", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection or "W"
			writeActionOverlay(fsm, "Dash_" .. direction)
		end,
		Timeout = 0.25,
		OnTimeout = "None",
	}, { "None" })
	--[=[
		@state Flipping
		@description Handles the `Flipping` state for `ActionFSM`.
	]=]

	self:AddState("Flipping", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm, "Flipping")
		end,
		Timeout = 0.4,
		OnTimeout = "None",
	}, { "None" })
	--[=[
		@state HitReact
		@description Handles the `HitReact` state for `ActionFSM`.
	]=]

	self:AddState("HitReact", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm, "HitReact")

			-- Apply knockback impulse (merged from HitReactController)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator and orchestrator.GetEntity(fsm.CharacterEntityId)
			if charEntity and charEntity.IsBlocking then
				return -- no knockback while blocking
			end
			local character = charEntity and charEntity.Instance
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if rootPart and rootPart:IsA("BasePart") then
				local knockDirection = -rootPart.CFrame.LookVector
				local bodyVelocity = Instance.new("BodyVelocity")
				bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
				bodyVelocity.Velocity = knockDirection * 25
				bodyVelocity.Parent = rootPart
				task.delay(0.15, function()
					if bodyVelocity.Parent then
						bodyVelocity:Destroy()
					end
				end)
			end
		end,
		Timeout = 0.2,
		OnTimeout = "None",
	}, { "None" })
	--[=[
		@state Completed
		@description Handles the `Completed` terminal state for `ActionFSM`.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
		@state Failed
		@description Handles the `Failed` terminal state for `ActionFSM`.
	]=]

	self:AddState("Failed", function() end, {})
end
--[=[
	@description Handles `RequestMelee` for `ActionFSM`.
	@param fsm any -- `fsm` input parameter.
	@param phases { { Name: string, Speed: number, Duration: number } } -- `phases` input parameter.
	@param onAnimate (string, number?, number?) -> () -- `onAnimate` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ActionFSM.RequestMelee(
	fsm: any,
	phases: { { Name: string, Speed: number, Duration: number } },
	onAnimate: (string, number?, number?) -> ()
)
	if fsm.State ~= "None" then
		return false
	end
	fsm.Context._movePhases = phases
	fsm.Context._onAnimate = onAnimate

	-- Set timeout for windup from first phase duration
	local windupDuration = phases[1] and phases[1].Duration or 0.2
	-- We need to use ScheduleTransition for the dynamic timeout
	fsm.State = "MeleeWindup"
	fsm:ScheduleTransition(windupDuration, "MeleeStrike")
	return true
end
--[=[
	@description Handles `RequestDash` for `ActionFSM`.
	@param fsm any -- `fsm` input parameter.
	@param direction string -- `direction` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ActionFSM.RequestDash(fsm: any, direction: string)
	if fsm.State ~= "None" then
		return false
	end
	fsm.Context._dashDirection = direction
	fsm.State = "Dashing"
	return true
end
--[=[
	@description Handles `RequestFlip` for `ActionFSM`.
	@param fsm any -- `fsm` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ActionFSM.RequestFlip(fsm: any)
	if fsm.State ~= "None" then
		return false
	end
	fsm.State = "Flipping"
	return true
end
--[=[
	@description Handles `RequestHitReact` for `ActionFSM`.
	@param fsm any -- `fsm` input parameter.
	@return any -- Return value produced by the implementation, if any.
]=]

function ActionFSM.RequestHitReact(fsm: any)
	fsm.State = "HitReact"
	return true
end

return ActionFSM
