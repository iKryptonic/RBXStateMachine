--!strict
-- @Name ServiceManager/Tests/Specs/InventoryConsistency.spec.luau
-- @Author iKrypto
-- @Description Contract tests for the player/character inventory data model.

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.Parent.Mocks.StateMachineSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function loadInventoryContracts()
		local playerEntity = Helpers.requireEntity("PlayerEntity")
		local characterEntity = Helpers.requireEntity("CharacterEntity")
		local equipJob = Helpers.requireStateMachine("EquipJob")
		local unEquipJob = Helpers.requireStateMachine("UnEquipJob")
		return playerEntity, characterEntity, Helpers.captureStates(equipJob), Helpers.captureStates(unEquipJob)
	end

	describe("inventory schema consistency", function()
		it("keeps EquipSlots removed from PlayerEntity schema", function()
			local playerEntity, characterEntity = loadInventoryContracts()
			expect(playerEntity.Schema.EquipSlots).toBeNil()
			expect(playerEntity.Schema.Inventory).never.toBeNil()
			expect(playerEntity.Schema.Equipped).never.toBeNil()
			expect(playerEntity.Schema.WeaponEqp).never.toBeNil()
			expect(characterEntity.Schema.EquippedRight).never.toBeNil()
			expect(characterEntity.Schema.EquippedLeft).never.toBeNil()
			expect(characterEntity.Schema.EquipLock).never.toBeNil()
		end)

		it("equip commit moves the item from Inventory into Equipped.Right", function()
			local _, _, equipStates = loadInventoryContracts()
			local character, cleanupCharacter = Helpers.makeCharacterModel("InventoryConsistencyEquipCharacter")
			local charEntity = Helpers.makeCharacterEntity({
				EntityId = "Char_Consistency",
				PlayerEntityId = "Player_Consistency",
				Instance = character,
			})
			local playerEntity = Helpers.makePlayerEntity({
				EntityId = "Player_Consistency",
				Inventory = { "1", "2", "3" },
				Equipped = {},
				WeaponEqp = "",
			})
			local orchestrator = Helpers.makeOrchestrator({
				entities = {
					Char_Consistency = charEntity,
					Player_Consistency = playerEntity,
				},
			})
			local fsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_Consistency",
				PlayerEntityId = "Player_Consistency",
				Hand = "Right",
				ItemId = "1",
			})

			equipStates.CommitState.Definition.OnEnter(nil, fsm)

			expect(playerEntity.Inventory).toEqual({ "2", "3" })
			expect(playerEntity.Equipped.Right).toEqual("1")
			expect(playerEntity.WeaponEqp).toEqual("1")
			expect(charEntity.EquippedRight).toEqual("1")
			cleanupCharacter()
		end)

		it("unequip commit restores inventory and clears duplicate tracking", function()
			local _, _, _, unEquipStates = loadInventoryContracts()
			local character, cleanupCharacter = Helpers.makeCharacterModel("InventoryConsistencyUnEquipCharacter")
			local charEntity = Helpers.makeCharacterEntity({
				EntityId = "Char_Consistency2",
				PlayerEntityId = "Player_Consistency2",
				Instance = character,
				EquippedRight = "1",
			})
			local playerEntity = Helpers.makePlayerEntity({
				EntityId = "Player_Consistency2",
				Inventory = { "2", "3" },
				Equipped = { Right = "1" },
				WeaponEqp = "1",
			})
			local orchestrator = Helpers.makeOrchestrator({
				entities = {
					Char_Consistency2 = charEntity,
					Player_Consistency2 = playerEntity,
				},
			})
			local fsm = Helpers.makeFSM(orchestrator, {
				CharacterEntityId = "Char_Consistency2",
				PlayerEntityId = "Player_Consistency2",
				Hand = "Right",
				Context = { _resolvedItemId = "1" },
			})

			unEquipStates.CommitState.Definition.OnEnter(nil, fsm)

			expect(playerEntity.Inventory).toEqual({ "2", "3", "1" })
			expect(charEntity.EquippedRight).toEqual("")
			expect(playerEntity.Equipped.Right).toBeNil()
			expect(playerEntity.WeaponEqp).toEqual("")
			cleanupCharacter()
		end)
	end)
end

TR.register(spec)
return spec
