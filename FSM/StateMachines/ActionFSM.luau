--!strict


--[=[
	@module ActionFSM
	@description Tracks transient action overlays for a character, including melee phases, dashes, flips, and hit reactions.
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
	terminalStates = {"Completed","Failed" },
	initialState = "None",
}

--[=[
	@description Returns the char entity used by this state machine when it can be resolved.
	@param fsm any -- Input consumed by `getCharEntity`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function getCharEntity(fsm: any): any?
	local orchestrator = (shared :: any).fsm
	if not orchestrator then
		return nil
	end
	return orchestrator.GetEntity(fsm.CharacterEntityId)
end

--[=[
	@description Writes the derived action overlay data back onto the active entity or FSM context.
	@param fsm any -- Input consumed by `writeActionOverlay`.
	@param overlay any -- Input consumed by `writeActionOverlay`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

local function writeActionOverlay(fsm: any, overlay: string)
	local charEntity = getCharEntity(fsm)
	if charEntity then
		charEntity.ActionOverlay = overlay
	end
end


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `ActionFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function ActionFSM:RegisterStates()


	--[=[
		@state None
		@description Writes `ActionOverlay` as `None`.
			Transitions:
			- External transitions allow: `MeleeWindup`, `Dashing`, `Flipping`, `HitReact`.
			Writes: clears `Context._currentMove`, clears `Context._movePhases`, clears `Context._phaseIndex`, stores `Context._currentMove`, stores `Context._movePhases`.
	]=]

	self:AddState("None", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm,"None")
			fsm.Context._currentMove = nil
			fsm.Context._movePhases = nil
			fsm.Context._phaseIndex = nil
		end,
	}, {"MeleeWindup","Dashing","Flipping","HitReact" })


	--[=[
		@state MeleeWindup
		@description Updates the action overlay.
			Transitions:
			- `MeleeStrike` when the nil-second timeout expires.
			- `None` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._phaseIndex`, sets `_phaseIndex`.
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
	}, {"MeleeStrike","None" })


	--[=[
		@state MeleeStrike
		@description Updates the action overlay.
			Transitions:
			- `MeleeRecovery` when this stage finishes its immediate work or falls through its guard checks.
			Writes: stores `Context._phaseIndex`, sets `_phaseIndex`.
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
	}, {"MeleeRecovery","None" })


	--[=[
		@state MeleeRecovery
		@description Writes `ActionOverlay` as `Recovery`.
			Transitions:
			- `None` when the 0.1-second timeout expires.
			Writes: none.
	]=]

	self:AddState("MeleeRecovery", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm,"Recovery")
		end,
		Timeout = 0.1,
		OnTimeout = "None",
	}, {"None" })


	--[=[
		@state Dashing
		@description Writes `ActionOverlay` as `Dash_`.
			Transitions:
			- `None` when the 0.25-second timeout expires.
			Writes: none.
	]=]

	self:AddState("Dashing", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection or "W"
			writeActionOverlay(fsm,"Dash_" .. direction)
		end,
		Timeout = 0.25,
		OnTimeout = "None",
	}, {"None" })


	--[=[
		@state Flipping
		@description Writes `ActionOverlay` as `Flipping`.
			Transitions:
			- `None` when the 0.4-second timeout expires.
			Writes: none.
	]=]

	self:AddState("Flipping", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm,"Flipping")
		end,
		Timeout = 0.4,
		OnTimeout = "None",
	}, {"None" })


	--[=[
		@state HitReact
		@description Writes `ActionOverlay` as `HitReact`.
			Transitions:
			- `None` when the 0.2-second timeout expires.
			Writes: none.
	]=]

	self:AddState("HitReact", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm,"HitReact")

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
	}, {"None" })
	--[=[
	@state Completed
	@description Terminal success sink reserved for explicit shutdown of the action overlay FSM. Normal melee, dash, flip, and hit-react flows return to `None` instead, so `OnEnter` is a no-op.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink reserved for future hard action errors. Current action requests fall back to `None` rather than routing here, so `OnEnter` is a no-op.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Failed", function() end, {})
end


--[=[
	@description Attempts to start the `Melee` path when the FSM is in a compatible state.
	@return nil -- Performs state changes or cleanup as side effects.
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
	fsm:ScheduleTransition(windupDuration,"MeleeStrike")
	return true
end


--[=[
	@description Attempts to start the `Dash` path when the FSM is in a compatible state.
	@param fsm any -- Value consumed by `RequestDash`.
	@param direction any -- Value consumed by `RequestDash`.
	@return nil -- Performs state changes or cleanup as side effects.
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
	@description Attempts to start the `Flip` path when the FSM is in a compatible state.
	@param fsm any -- Value consumed by `RequestFlip`.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

function ActionFSM.RequestFlip(fsm: any)
	if fsm.State ~= "None" then
		return false
	end
	fsm.State = "Flipping"
	return true
end


--[=[
	@description Attempts to start the `HitReact` path when the FSM is in a compatible state.
	@param fsm any -- Value consumed by `RequestHitReact`.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

function ActionFSM.RequestHitReact(fsm: any)
	fsm.State = "HitReact"
	return true
end

return ActionFSM
