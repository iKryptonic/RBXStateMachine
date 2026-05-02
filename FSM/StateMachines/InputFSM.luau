--!strict
-- @Name InputFSM
-- @Author iKrypto
-- @Description Client-side FSM managing input mode state.
--   States: Normal → ComboMode → Normal (timeout)
--           Normal → HeldAttack → Normal (key release)
--   Replaces imperative _keystrokeMode/_heldAttackKey with observable states.

local InputFSM = {
	Name = "InputFSM",
	className = "InputFSM",
	validStates = { "Normal", "ComboMode", "HeldAttack", "Completed", "Failed" },
	terminalStates = { "Completed", "Failed" },
	initialState = "Normal",
}

local KEYSTROKE_TIMEOUT = 1.75

local function writeInputMode(fsm: any, mode: string)
	local orchestrator = (shared :: any).fsm
	if not orchestrator then
		return
	end
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if charEntity then
		charEntity.ActionOverlay = if mode == "Normal" then (charEntity.ActionOverlay or "None") else mode
	end
end

function InputFSM:RegisterStates()
	self:AddState("Normal", {
		OnEnter = function(_, _fsm)
			-- Normal input mode — all bindings active
		end,
	}, { "ComboMode", "HeldAttack" })

	self:AddState("ComboMode", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, "ComboMode")
			fsm.Context._comboBuffer = {}
			fsm.Context._comboPointer = 1
		end,
		OnLeave = function(_, fsm)
			fsm.Context._comboBuffer = {}
			fsm.Context._comboPointer = 0
		end,
		Timeout = KEYSTROKE_TIMEOUT,
		OnTimeout = "Normal",
	}, { "Normal" })

	self:AddState("HeldAttack", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm, "HeldAttack")
		end,
		OnLeave = function(_, fsm)
			writeInputMode(fsm, "None")
		end,
	}, { "Normal" })

	self:AddState("Completed", function() end, {})
	self:AddState("Failed", function() end, {})
end

-- Public API
function InputFSM.EnterComboMode(fsm: any): boolean
	if fsm.State == "ComboMode" then
		fsm.State = "Normal"
		return false
	end
	fsm.State = "ComboMode"
	return true
end

function InputFSM.EnterHeldAttack(fsm: any): boolean
	if fsm.State ~= "Normal" then
		return false
	end
	fsm.State = "HeldAttack"
	return true
end

function InputFSM.ReleaseHeldAttack(fsm: any)
	if fsm.State == "HeldAttack" then
		fsm.State = "Normal"
	end
end

function InputFSM.IsComboMode(fsm: any): boolean
	return fsm.State == "ComboMode"
end

function InputFSM.IsHeldAttack(fsm: any): boolean
	return fsm.State == "HeldAttack"
end

return InputFSM
