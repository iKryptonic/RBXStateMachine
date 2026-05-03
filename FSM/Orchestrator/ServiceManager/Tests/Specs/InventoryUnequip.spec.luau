--!strict
-- @Name ServiceManager/Tests/Specs/InventoryUnequip.spec.luau
-- @Author iKrypto
-- @Description Contract tests for UnEquipJob inventory restoration and stow/drop branching.

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.Parent.Mocks.StateMachineSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local equipHelpers: any = {
		stowCalls = 0,
		dropCalls = 0,
	}
	function equipHelpers:reset()
		self.stowCalls = 0
		self.dropCalls = 0
		self.lastStow = nil
		self.lastDrop = nil
	end
	function equipHelpers.StowItem(item: any, character: any, weld: any, itemData: any)
		equipHelpers.stowCalls += 1
		equipHelpers.lastStow = {
			Item = item,
			Character = character,
			Weld = weld,
			ItemData = itemData,
		}
	end
	function equipHelpers.DropItem(item: any, weld: any)
		equipHelpers.dropCalls += 1
		equipHelpers.lastDrop = {
			Item = item,
			Weld = weld,
		}
	end

	local function loadUnEquipJob()
		local job = Helpers.requireStateMachine("UnEquipJob")
		return job, Helpers.captureStates(job)
	end

	describe("UnEquipJob definition", function()
		it("loads with expected metadata and API", function()
			local job, states = loadUnEquipJob()
			expect(job.Name).toEqual("UnEquipJob")
			expect(job.className).toEqual("UnEquipJob")
			expect(job.validStates).toEqual({
				"ValidateRequest",
				"AcquireEquipLock",
				"ResolveExistingItem",
				"DoUnEquip",
				"CommitState",
				"EmitIntent",
				"ReleaseEquipLock",
				"Rollback",
				"Completed",
				"Failed",
			})
			expect(job.terminalStates).toEqual({ "Completed", "Failed" })
			expect(type(job.RegisterStates)).toEqual("function")
			expect(states.DoUnEquip).never.toBeNil()
			expect(states.CommitState).never.toBeNil()
		end)

		it("restores the unequipped item back into player inventory", function()
			local _, states = loadUnEquipJob()
			local character, cleanupCharacter = Helpers.makeCharacterModel("UnEquipCommitCharacter")
			local charEntity = Helpers.makeCharacterEntity({
				EntityId = "Char_UnEquip",
				PlayerEntityId = "Player_UnEquip",
				Instance = character,
				EquippedRight = "2",
			})
			local playerEntity = Helpers.makePlayerEntity({
				EntityId = "Player_UnEquip",
				Inventory = { "1", "3" },
				Equipped = { Right = "2" },
				WeaponEqp = "2",
			})
			local orchestrator = Helpers.makeOrchestrator({
				entities = {
					Char_UnEquip = charEntity,
					Player_UnEquip = playerEntity,
				},
			})
			local fsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_UnEquip",
				PlayerEntityId = "Player_UnEquip",
				Hand = "Right",
				Context = { _resolvedItemId = "2" },
			})

			states.CommitState.Definition.OnEnter(nil, fsm)

			expect(playerEntity.Inventory).toEqual({ "1", "3", "2" })
			expect(charEntity.EquippedRight).toEqual("")
			expect(playerEntity.Equipped.Right).toBeNil()
			expect(playerEntity.WeaponEqp).toEqual("")
			expect(fsm.State).toEqual("EmitIntent")
			cleanupCharacter()
		end)

		it("stows stowable items and drops non-stowable items", function()
			local _, states = loadUnEquipJob()
			equipHelpers:reset()
			local character, cleanupCharacter = Helpers.makeCharacterModel("UnEquipDoUnEquipCharacter")
			local charEntity = Helpers.makeCharacterEntity({
				EntityId = "Char_Branch",
				PlayerEntityId = "Player_Branch",
				Instance = character,
			})
			local playerEntity = Helpers.makePlayerEntity({ EntityId = "Player_Branch" })
			local orchestrator = Helpers.makeOrchestrator({
				entities = {
					Char_Branch = charEntity,
					Player_Branch = playerEntity,
				},
				modules = { EquipHelpers = equipHelpers },
			})
			local item = Instance.new("Folder")
			item.Name = "Sword01"
			item.Parent = character
			local weld = { Part1 = true }

			local stowFsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_Branch",
				PlayerEntityId = "Player_Branch",
				Hand = "Right",
				Context = {
					_resolvedWeld = weld,
					_resolvedItem = item,
					_resolvedItemData = { Stowable = true },
				},
			})
			states.DoUnEquip.Definition.OnEnter(nil, stowFsm)
			expect(equipHelpers.stowCalls).toEqual(1)
			expect(equipHelpers.dropCalls).toEqual(0)
			expect(stowFsm.State).toEqual("CommitState")

			equipHelpers:reset()
			local dropFsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_Branch",
				PlayerEntityId = "Player_Branch",
				Hand = "Right",
				Context = {
					_resolvedWeld = weld,
					_resolvedItem = item,
					_resolvedItemData = { Stowable = false },
				},
			})
			states.DoUnEquip.Definition.OnEnter(nil, dropFsm)
			expect(equipHelpers.stowCalls).toEqual(0)
			expect(equipHelpers.dropCalls).toEqual(1)
			expect(dropFsm.State).toEqual("CommitState")

			item:Destroy()
			cleanupCharacter()
		end)

		it("handles an empty hand without failing", function()
			local _, states = loadUnEquipJob()
			equipHelpers:reset()
			local character, cleanupCharacter = Helpers.makeCharacterModel("UnEquipEmptyHandCharacter")
			local charEntity = Helpers.makeCharacterEntity({
				EntityId = "Char_Empty",
				PlayerEntityId = "Player_Empty",
				Instance = character,
			})
			local playerEntity = Helpers.makePlayerEntity({ EntityId = "Player_Empty" })
			local orchestrator = Helpers.makeOrchestrator({
				entities = {
					Char_Empty = charEntity,
					Player_Empty = playerEntity,
				},
				modules = { EquipHelpers = equipHelpers },
			})
			local fsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_Empty",
				PlayerEntityId = "Player_Empty",
				Hand = "Left",
				Context = {
					_resolvedWeld = nil,
					_resolvedItem = nil,
					_resolvedItemData = nil,
				},
			})

			states.DoUnEquip.Definition.OnEnter(nil, fsm)

			expect(fsm.Failure).toBeNil()
			expect(fsm.State).toEqual("CommitState")
			expect(#fsm.Logs).toBeGreaterThan(0)
			expect(fsm.Logs[1].Level).toEqual("WARN")
			cleanupCharacter()
		end)
	end)
end

TR.register(spec)
return spec
