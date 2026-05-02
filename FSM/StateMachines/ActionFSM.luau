--!strict
-- @Name ActionFSM
-- @Author Copilot
-- @Description Client-side FSM managing action overlays (melee, dash, flip, hit react).
--   Writes ActionOverlay to CharacterEntity for ServiceManager observability.
--   Replaces imperative _attackBusy flag and ad-hoc cooldown logic.

local ActionFSM = {
	Name = "ActionFSM",
	className = "ActionFSM",
	validStates = { "None", "MeleeWindup", "MeleeStrike", "MeleeRecovery", "Dashing", "Flipping", "HitReact", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "None",
}

local function getCharEntity(fsm: any): any?
	local orchestrator = (shared :: any).fsm
	if not orchestrator then return nil end
	return orchestrator.GetEntity(fsm.CharacterEntityId)
end

local function writeActionOverlay(fsm: any, overlay: string)
	local charEntity = getCharEntity(fsm)
	if charEntity then
		charEntity.ActionOverlay = overlay
	end
end

function ActionFSM:RegisterStates()
	-- None: idle, waiting for action commands
	self:AddState("None", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm, "None")
			fsm.Context._currentMove = nil
			fsm.Context._movePhases = nil
			fsm.Context._phaseIndex = nil
		end,
	}, { "MeleeWindup", "Dashing", "Flipping", "HitReact" })

	-- MeleeWindup: first phase of a melee attack
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

	-- MeleeStrike: second phase (or single phase for simple attacks)
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

	-- MeleeRecovery: brief recovery before returning to None
	self:AddState("MeleeRecovery", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm, "Recovery")
		end,
		Timeout = 0.1,
		OnTimeout = "None",
	}, { "None" })

	-- Dashing: active dash with impulse
	self:AddState("Dashing", {
		OnEnter = function(_, fsm)
			local direction = fsm.Context._dashDirection or "W"
			writeActionOverlay(fsm, "Dash_" .. direction)
		end,
		Timeout = 0.25,
		OnTimeout = "None",
	}, { "None" })

	-- Flipping: double jump flip
	self:AddState("Flipping", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm, "Flipping")
		end,
		Timeout = 0.4,
		OnTimeout = "None",
	}, { "None" })

	-- HitReact: stagger from being hit
	self:AddState("HitReact", {
		OnEnter = function(_, fsm)
			writeActionOverlay(fsm, "HitReact")
		end,
		Timeout = 0.2,
		OnTimeout = "None",
	}, { "None" })
end

-- Public API: request a melee attack sequence
function ActionFSM.RequestMelee(fsm: any, phases: { { Name: string, Speed: number, Duration: number } }, onAnimate: (string, number?, number?) -> ())
	if fsm.State ~= "None" then return false end
	fsm.Context._movePhases = phases
	fsm.Context._onAnimate = onAnimate

	-- Set timeout for windup from first phase duration
	local windupDuration = phases[1] and phases[1].Duration or 0.2
	-- We need to use ScheduleTransition for the dynamic timeout
	fsm.State = "MeleeWindup"
	fsm:ScheduleTransition(windupDuration, "MeleeStrike")
	return true
end

function ActionFSM.RequestDash(fsm: any, direction: string)
	if fsm.State ~= "None" then return false end
	fsm.Context._dashDirection = direction
	fsm.State = "Dashing"
	return true
end

function ActionFSM.RequestFlip(fsm: any)
	if fsm.State ~= "None" then return false end
	fsm.State = "Flipping"
	return true
end

function ActionFSM.RequestHitReact(fsm: any)
	fsm.State = "HitReact"
	return true
end

return ActionFSM
