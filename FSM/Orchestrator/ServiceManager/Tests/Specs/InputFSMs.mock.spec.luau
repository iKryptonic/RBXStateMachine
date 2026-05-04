--!strict

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local InputFSM = require(Helpers.getStateMachine("InputFSM"))
	local InputModeFSM = require(Helpers.getStateMachine("InputModeFSM"))

	describe("InputFSM", function()
		it("should transition Normal to ComboMode and back on timeout", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("InputFSM"), {
				StateMachineId = "Input_Combo",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(InputFSM.EnterComboMode(machine)).toBeTruthy()
			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("ComboMode")
			expect(charEntity.ActionOverlay).toEqual("ComboMode")
			expect(machine.Context._comboPointer).toEqual(1)
			expect(Helpers.stepUntil(env, machine, "Normal", 140)).toBeTruthy()

			env:Cleanup()
		end)

		it("should transition Normal to HeldAttack and back on release", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("InputFSM"), {
				StateMachineId = "Input_Held",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(InputFSM.EnterHeldAttack(machine)).toBeTruthy()
			env.Mock:StepFrames(1)
			expect(machine.State).toEqual("HeldAttack")
			expect(charEntity.ActionOverlay).toEqual("HeldAttack")
			InputFSM.ReleaseHeldAttack(machine)
			env.Mock:StepFrames(1)
			expect(machine.State).toEqual("Normal")
			expect(charEntity.ActionOverlay).toEqual("None")

			env:Cleanup()
		end)

		it("should toggle combo mode off when EnterComboMode is called twice", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("InputFSM"), {
				StateMachineId = "Input_ToggleCombo",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(InputFSM.EnterComboMode(machine)).toBeTruthy()
			env.Mock:StepFrames(1)
			expect(InputFSM.EnterComboMode(machine)).toBeFalsy()
			env.Mock:StepFrames(1)
			expect(machine.State).toEqual("Normal")

			env:Cleanup()
		end)
	end)

	describe("InputModeFSM", function()
		it("should initialize in CombatInput", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("InputModeFSM"), {
				StateMachineId = "InputMode_Init",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(machine.State).toEqual("CombatInput")
			expect(charEntity.MouseLocked).toBeTruthy()
			expect(charEntity.InputMode).toEqual("Combat")

			env:Cleanup()
		end)

		it("should toggle between CombatInput and UIInput", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("InputModeFSM"), {
				StateMachineId = "InputMode_Toggle",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(InputModeFSM.Toggle(machine)).toEqual("UIInput")
			env.Mock:StepFrames(1)
			expect(charEntity.MouseLocked).toBeFalsy()
			expect(charEntity.InputMode).toEqual("UI")
			expect(InputModeFSM.Toggle(machine)).toEqual("CombatInput")
			env.Mock:StepFrames(1)
			expect(charEntity.MouseLocked).toBeTruthy()
			expect(charEntity.InputMode).toEqual("Combat")

			env:Cleanup()
		end)

		it("should allow explicit CombatInput and UIInput setters", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("InputModeFSM"), {
				StateMachineId = "InputMode_Setters",
				CharacterEntityId = charEntity.EntityId,
			})

			InputModeFSM.SetUIInput(machine)
			env.Mock:StepFrames(1)
			expect(machine.State).toEqual("UIInput")
			InputModeFSM.SetCombatInput(machine)
			env.Mock:StepFrames(1)
			expect(machine.State).toEqual("CombatInput")

			env:Cleanup()
		end)
	end)
end

TR.register(spec)
return spec
