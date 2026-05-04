--!strict
-- @Name ServiceManager/Tests/Specs/InventoryEquip.spec.luau
-- @Author iKrypto
-- @Description Contract tests for EquipJob inventory flow and lock handling.

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.Parent.Mocks.StateMachineSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function loadEquipJob()
		local job = Helpers.requireStateMachine("EquipJob")
		return job, Helpers.captureStates(job)
	end

	describe("EquipJob definition", function()
		it("loads with expected metadata and API", function()
			local job, states = loadEquipJob()
			expect(job.Name).toEqual("EquipJob")
			expect(job.className).toEqual("EquipJob")
			expect(job.validStates).toEqual({
				"ValidateRequest",
				"AcquireEquipLock",
				"ResolveItemMeta",
				"PreUnEquip",
				"CloneAsset",
				"CreateWeld",
				"MountItem",
				"CommitState",
				"EmitIntent",
				"ReleaseEquipLock",
				"Rollback",
				"Completed",
				"Failed",
			})
			expect(job.terminalStates).toEqual({ "Completed", "Failed" })
			expect(type(job.RegisterStates)).toEqual("function")
			expect(states.ValidateRequest).never.toBeNil()
			expect(states.AcquireEquipLock).never.toBeNil()
			expect(states.Rollback).never.toBeNil()
		end)

		it("removes the equipped item from player inventory on commit", function()
			local _, states = loadEquipJob()
			local character, cleanupCharacter = Helpers.makeCharacterModel("EquipJobCommitCharacter")
			local charEntity = Helpers.makeCharacterEntity({
				EntityId = "Char_Equip",
				PlayerEntityId = "Player_Equip",
				Instance = character,
			})
			local playerEntity = Helpers.makePlayerEntity({
				EntityId = "Player_Equip",
				Inventory = { "1", "2", "3" },
				Equipped = {},
				WeaponEqp = "",
			})
			local orchestrator = Helpers.makeOrchestrator({
				entities = {
					Char_Equip = charEntity,
					Player_Equip = playerEntity,
				},
			})
			local fsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_Equip",
				PlayerEntityId = "Player_Equip",
				Hand = "Right",
				ItemId = "2",
			})

			states.CommitState.Definition.OnEnter(nil, fsm)

			expect(playerEntity.Inventory).toEqual({ "1", "3" })
			expect(playerEntity.Equipped.Right).toEqual("2")
			expect(playerEntity.WeaponEqp).toEqual("2")
			expect(charEntity.EquippedRight).toEqual("2")
			expect(fsm.State).toEqual("EmitIntent")
			cleanupCharacter()
		end)

		it("retries AcquireEquipLock with WaitSpan when the hand is locked", function()
			local _, states = loadEquipJob()
			local character, cleanupCharacter = Helpers.makeCharacterModel("EquipJobLockCharacter")
			local charEntity = Helpers.makeCharacterEntity({
				EntityId = "Char_Lock",
				Instance = character,
				EquipLock = { Right = true },
			})
			local orchestrator = Helpers.makeOrchestrator({
				entities = { Char_Lock = charEntity },
			})
			local fsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_Lock",
				Hand = "Right",
				Context = {},
			})

			states.AcquireEquipLock.Definition.OnEnter(nil, fsm)

			expect(fsm.State).toEqual("AcquireEquipLock")
			expect(fsm.WaitSpan).toEqual(0.3)
			expect(fsm.Context._equipLockRetryCount).toEqual(1)
			cleanupCharacter()
		end)

		it("fails validation when the requested item is not in inventory", function()
			local job, states = loadEquipJob()
			local cleanupAssets = Helpers.ensureAssets({ "9" })
			local character, cleanupCharacter = Helpers.makeCharacterModel("EquipJobValidateCharacter")
			local charEntity = Helpers.makeCharacterEntity({
				EntityId = "Char_Validate",
				PlayerEntityId = "Player_Validate",
				Instance = character,
			})
			local playerEntity = Helpers.makePlayerEntity({
				EntityId = "Player_Validate",
				Inventory = { "1", "2", "3" },
			})
			local orchestrator = Helpers.makeOrchestrator({
				entities = {
					Char_Validate = charEntity,
					Player_Validate = playerEntity,
				},
			})
			local fsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_Validate",
				PlayerEntityId = "Player_Validate",
				ItemId = "9",
				Context = {},
			})

			states.ValidateRequest.Definition.OnEnter(nil, fsm)

			expect(fsm.Failure).toEqual("Item 9 not in inventory")
			expect(states.ValidateRequest.Transitions).toContain("Failed")
			expect(job.validStates).toContain("AcquireEquipLock")
			expect(job.validStates).toContain("Rollback")
			cleanupCharacter()
			cleanupAssets()
		end)
	end)
end

TR.register(spec)
return spec
