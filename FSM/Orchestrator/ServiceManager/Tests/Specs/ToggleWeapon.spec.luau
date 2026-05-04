--!strict
-- @Name ServiceManager/Tests/Specs/ToggleWeapon.spec.luau
-- @Author iKrypto
-- @Description Contract tests for ToggleWeaponJob branch selection and validation.

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.Parent.Mocks.StateMachineSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function loadToggleWeaponJob()
		local job = Helpers.requireStateMachine("ToggleWeaponJob")
		return job, Helpers.captureStates(job)
	end

	describe("ToggleWeaponJob", function()
		it("loads with expected definition", function()
			local job, states = loadToggleWeaponJob()
			expect(job.Name).toEqual("ToggleWeaponJob")
			expect(job.className).toEqual("ToggleWeaponJob")
			expect(job.validStates).toEqual({ "Validate", "ResolveCurrentState", "ChooseBranch", "RunEquip", "RunUnEquip", "Completed", "Failed" })
			expect(job.terminalStates).toEqual({ "Completed", "Failed" })
			expect(states.ResolveCurrentState).never.toBeNil()
			expect(states.ChooseBranch).never.toBeNil()
		end)

		it("fails gracefully when WeaponEqp is empty", function()
			local job, states = loadToggleWeaponJob()
			local fsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				PlayerEntity = { WeaponEqp = "", Inventory = {} },
				CharacterEntity = { EquippedRight = "", EquippedLeft = "" },
				IsEquipped = false,
			})

			states.ChooseBranch.Definition.OnEnter(nil, fsm)

			expect(job.terminalStates).toContain("Failed")
			expect(fsm.Failure).toEqual("No weapon selected to equip")
		end)

		it("validates that the selected weapon exists in inventory", function()
			local _, states = loadToggleWeaponJob()
			local fsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				PlayerEntity = { WeaponEqp = "Sword99", Inventory = { "Sword01", "Sword02" } },
				CharacterEntity = { EquippedRight = "", EquippedLeft = "" },
				IsEquipped = false,
			})

			states.ChooseBranch.Definition.OnEnter(nil, fsm)

			expect(fsm.Failure).toEqual("Weapon Sword99 not in inventory")
		end)

		it("checks both hands when resolving equipped state", function()
			local _, states = loadToggleWeaponJob()

			local rightFsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				PlayerEntity = { WeaponEqp = "Sword01" },
				CharacterEntity = { EquippedRight = "Sword01", EquippedLeft = "" },
			})
			states.ResolveCurrentState.Definition.OnEnter(nil, rightFsm)
			expect(rightFsm.Hand).toEqual("Right")
			expect(rightFsm.EquippedItemId).toEqual("Sword01")
			expect(rightFsm.IsEquipped).toBeTruthy()

			local leftFsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				PlayerEntity = { WeaponEqp = "Sword02" },
				CharacterEntity = { EquippedRight = "", EquippedLeft = "Sword02" },
			})
			states.ResolveCurrentState.Definition.OnEnter(nil, leftFsm)
			expect(leftFsm.Hand).toEqual("Left")
			expect(leftFsm.EquippedItemId).toEqual("Sword02")
			expect(leftFsm.IsEquipped).toBeTruthy()
		end)
	end)
end

TR.register(spec)
return spec
