--!strict


--[=[
	@Name InputFSM
	@Author iKrypto
	@Description Client-side input state machine. Tracks whether the player is in Normal
	input mode, Combo mode (C key for spell combos), or HeldAttack mode (holding Q for
	repeated attacks). Manages the combo key buffer and pointer for spell keystroke
	sequences.

	State flow:
	Normal ↔ ComboMode (C key toggle)
	Normal → HeldAttack (Q hold) → Normal (Q release)

	Context fields:
	- _comboBuffer: string — accumulated keystroke sequence for spell combos
	- _comboPointer: number — current position in the combo buffer

	Required params:
	- CharacterEntityId: string — character entity ID
]=]

local InputFSM = {
	Name = "InputFSM",
	className = "InputFSM",
	validStates = {"Normal","ComboMode","HeldAttack","Completed","Failed" },
	terminalStates = {"Completed","Failed" },
	initialState = "Normal",
}

local KEYSTROKE_TIMEOUT = 1.75

--[=[
	@description Writes the derived input mode data back onto the active entity or FSM context.
	@param fsm any -- Input consumed by `writeInputMode`.
	@param mode any -- Input consumed by `writeInputMode`.
	@return any -- Helper result used by the surrounding FSM flow, when applicable.
]=]

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


--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `InputFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function InputFSM:RegisterStates()


	--[=[
		@state Normal
		@description Runs the `normal` stage of `InputFSM`.
			Transitions:
			- External transitions allow: `ComboMode`, `HeldAttack`.
			Writes: none.
	]=]

	self:AddState("Normal", {
		OnEnter = function(_, _fsm)
			-- Normal input mode — all bindings active
		end,
	}, {"ComboMode","HeldAttack" })


	--[=[
		@state ComboMode
		@description On enter, stores `Context._comboBuffer`, stores `Context._comboPointer`, sets `_comboBuffer`.
			Transitions:
			- `Normal` when the KEYSTROKE_TIMEOUT-second timeout expires.
			Writes: stores `Context._comboBuffer`, stores `Context._comboPointer`, sets `_comboBuffer`, sets `_comboPointer`.
	]=]

	self:AddState("ComboMode", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm,"ComboMode")
			fsm.Context._comboBuffer = {}
			fsm.Context._comboPointer = 1
		end,
		OnLeave = function(_, fsm)
			fsm.Context._comboBuffer = {}
			fsm.Context._comboPointer = 0
		end,
		Timeout = KEYSTROKE_TIMEOUT,
		OnTimeout = "Normal",
	}, {"Normal" })


	--[=[
		@state HeldAttack
		@description Runs the `held attack` stage of `InputFSM`.
			Transitions:
			- External transitions allow: `Normal`.
			Writes: none.
	]=]

	self:AddState("HeldAttack", {
		OnEnter = function(_, fsm)
			writeInputMode(fsm,"HeldAttack")
		end,
		OnLeave = function(_, fsm)
			writeInputMode(fsm,"None")
		end,
	}, {"Normal" })
	--[=[
	@state Completed
	@description Terminal success sink reserved for explicit shutdown of the input-mode FSM. Runtime behavior normally stays inside `Normal`, `ComboMode`, and `HeldAttack`, so `OnEnter` is a no-op.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Completed", function() end, {})
	--[=[
	@state Failed
	@description Terminal failure sink reserved for future input-processing errors. The current implementation does not route here, and `OnEnter` performs no writes.
		Transitions: none.
		Writes: none.
	]=]

	self:AddState("Failed", function() end, {})
end


--[=[
	@description Switches the FSM into `ComboMode` when its current state allows the change.
	@param fsm any -- Value consumed by `EnterComboMode`.
	@return boolean -- True when the requested transition or action was accepted.
]=]

function InputFSM.EnterComboMode(fsm: any): boolean
	if fsm.State == "ComboMode" then
		fsm.State = "Normal"
		return false
	end
	fsm.State = "ComboMode"
	return true
end


--[=[
	@description Switches the FSM into `HeldAttack` when its current state allows the change.
	@param fsm any -- Value consumed by `EnterHeldAttack`.
	@return boolean -- True when the requested transition or action was accepted.
]=]

function InputFSM.EnterHeldAttack(fsm: any): boolean
	if fsm.State ~= "Normal" then
		return false
	end
	fsm.State = "HeldAttack"
	return true
end


--[=[
	@description Releases the active `held attack` mode and returns control to the default path when applicable.
	@param fsm any -- Value consumed by `ReleaseHeldAttack`.
	@return nil -- Performs state changes or cleanup as side effects.
]=]

function InputFSM.ReleaseHeldAttack(fsm: any)
	if fsm.State == "HeldAttack" then
		fsm.State = "Normal"
	end
end


--[=[
	@description Returns whether the FSM is currently in the `ComboMode` branch.
	@param fsm any -- Value consumed by `IsComboMode`.
	@return boolean -- True when the requested transition or action was accepted.
]=]

function InputFSM.IsComboMode(fsm: any): boolean
	return fsm.State == "ComboMode"
end


--[=[
	@description Returns whether the FSM is currently in the `HeldAttack` branch.
	@param fsm any -- Value consumed by `IsHeldAttack`.
	@return boolean -- True when the requested transition or action was accepted.
]=]

function InputFSM.IsHeldAttack(fsm: any): boolean
	return fsm.State == "HeldAttack"
end

return InputFSM
