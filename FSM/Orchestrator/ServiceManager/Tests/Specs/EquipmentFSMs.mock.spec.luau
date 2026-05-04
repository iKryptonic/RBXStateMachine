--!strict

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local EquipJob = Helpers.getStateMachine("EquipJob")
	local UnEquipJob = Helpers.getStateMachine("UnEquipJob")
	local ToggleWeaponJob = Helpers.getStateMachine("ToggleWeaponJob")

	local function makeItemCatalog(env, names)
		local catalog = {}
		for itemId, data in pairs(names) do
			catalog[itemId] = {
				Template = data.Template or Helpers.makeItemTemplate(env, itemId, true),
				Data = data.Data or {
					GripC1 = CFrame.new(),
					Stowable = true,
				},
			}
		end
		return catalog
	end

	describe("EquipJob", function()
		it("should complete happy path", function()
			local env = Helpers.newEnvironment()
			local itemCatalog = makeItemCatalog(env, {
				Sword = { Data = { GripC1 = CFrame.new(), Stowable = true } },
			})
			Helpers.registerDefaultModules(env, { ItemCatalog = itemCatalog })

			local character = Helpers.makeCharacterRig(env, "EquipCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Inventory = { "Sword" },
				BagContents = {},
				Equipped = {},
			})

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_Happy",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Sword",
				Hand = "Right",
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(charEntity.EquippedRight).toEqual("Sword")
			expect(playerEntity.Equipped.Right).toEqual("Sword")
			expect(playerEntity.WeaponEqp).toEqual("Sword")
			expect(playerEntity.Inventory).toHaveLength(0)
			expect(charEntity.EquipLock.Right).toBeNil()

			env:Cleanup()
		end)

		it("should return the previously equipped item to inventory on swap", function()
			local env = Helpers.newEnvironment()
			local itemCatalog = makeItemCatalog(env, {
				OldSword = { Data = { GripC1 = CFrame.new(), Stowable = true } },
				NewSword = { Data = { GripC1 = CFrame.new(), Stowable = true } },
			})
			Helpers.registerDefaultModules(env, { ItemCatalog = itemCatalog })

			local character, _, _, rightHand = Helpers.makeCharacterRig(env, "SwapCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
				EquippedRight = "OldSword",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Inventory = { "NewSword" },
				Equipped = { Right = "OldSword" },
			})

			local oldClone = itemCatalog.OldSword.Template:Clone()
			oldClone.Parent = character
			local equipHelpers = env.Orchestrator.GetModule("EquipHelpers")
			equipHelpers.CreateWeld(rightHand, oldClone.Handle, CFrame.new())

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_Swap",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "NewSword",
				Hand = "Right",
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(charEntity.EquippedRight).toEqual("NewSword")
			expect(playerEntity.Inventory).toContain("OldSword")
			expect(playerEntity.Inventory).never.toContain("NewSword")

			env:Cleanup()
		end)

		it("should fail when the cloned item has no Handle part", function()
			local env = Helpers.newEnvironment()
			local emptyTemplate = env:DestroyLater(Instance.new("Model"))
			emptyTemplate.Name = "BrokenSword"
			Helpers.registerDefaultModules(env, {
				ItemCatalog = {
					BrokenSword = {
						Template = emptyTemplate,
						Data = { GripC1 = CFrame.new() },
					},
				},
			})

			local character = Helpers.makeCharacterRig(env, "BrokenCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Inventory = { "BrokenSword" },
			})

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_NoHandle",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "BrokenSword",
				Hand = "Right",
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Failed")
			expect(machine.Logs[#machine.Logs].Message).toContain("no Handle part")

			env:Cleanup()
		end)

		it("should fail inventory ownership checks when the item is missing", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env, {
				ItemCatalog = makeItemCatalog(env, {
					Sword = {},
				}),
			})

			local character = Helpers.makeCharacterRig(env, "MissingItemCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Inventory = { "OtherItem" },
			})

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_NotOwned",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Sword",
				Hand = "Right",
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("not in inventory")

			env:Cleanup()
		end)
	end)

	describe("UnEquipJob", function()
		it("should stow the item on the happy path", function()
			local env = Helpers.newEnvironment()
			local itemCatalog = makeItemCatalog(env, {
				Sword = { Data = { GripC1 = CFrame.new(), Stowable = true } },
			})
			Helpers.registerDefaultModules(env, { ItemCatalog = itemCatalog })

			local character, _, _, rightHand = Helpers.makeCharacterRig(env, "UnEquipCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
				EquippedRight = "Sword",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Equipped = { Right = "Sword" },
				Inventory = {},
			})

			local sword = itemCatalog.Sword.Template:Clone()
			sword.Parent = character
			local equipHelpers = env.Orchestrator.GetModule("EquipHelpers")
			equipHelpers.CreateWeld(rightHand, sword.Handle, CFrame.new())

			local machine = env.Mock:CreateFSM(UnEquipJob, {
				StateMachineId = "UnEquip_Happy",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				Hand = "Right",
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(charEntity.EquippedRight).toEqual("")
			expect(playerEntity.Inventory).toContain("Sword")
			expect(sword:GetAttribute("Stowed")).toBeTruthy()

			env:Cleanup()
		end)

		it("should destroy the item when ForceRemove is true", function()
			local env = Helpers.newEnvironment()
			local itemCatalog = makeItemCatalog(env, {
				Sword = { Data = { GripC1 = CFrame.new(), Stowable = true } },
			})
			Helpers.registerDefaultModules(env, {
				ItemCatalog = itemCatalog,
				DropDestroysItem = true,
			})

			local character, _, _, rightHand = Helpers.makeCharacterRig(env, "ForceRemoveCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
				EquippedRight = "Sword",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Equipped = { Right = "Sword" },
				Inventory = {},
			})

			local sword = itemCatalog.Sword.Template:Clone()
			sword.Parent = character
			local equipHelpers = env.Orchestrator.GetModule("EquipHelpers")
			equipHelpers.CreateWeld(rightHand, sword.Handle, CFrame.new())

			local machine = env.Mock:CreateFSM(UnEquipJob, {
				StateMachineId = "UnEquip_ForceRemove",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				Hand = "Right",
				ForceRemove = true,
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(sword.Parent).toBeNil()
			expect(playerEntity.Inventory).toContain("Sword")

			env:Cleanup()
		end)

		it("should fail validation for an invalid hand", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env, { ItemCatalog = makeItemCatalog(env, { Sword = {} }) })

			local character = Helpers.makeCharacterRig(env, "InvalidHandCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
			})

			local machine = env.Mock:CreateFSM(UnEquipJob, {
				StateMachineId = "UnEquip_InvalidHand",
				CharacterEntityId = charEntity.EntityId,
				Hand = "Middle",
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("Invalid hand")

			env:Cleanup()
		end)
	end)

	describe("ToggleWeaponJob", function()
		it("should run the equip branch when a weapon is selected but not equipped", function()
			local env = Helpers.newEnvironment()
			local character = Helpers.makeCharacterRig(env, "ToggleEquipCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				WeaponEqp = "Sword",
				Inventory = { "Sword" },
			})

			local created = {}
			env.Orchestrator.CreateStateMachine = function(params)
				table.insert(created, params)
				return Helpers.makeChildJob("completed")
			end

			local machine = env.Mock:CreateFSM(ToggleWeaponJob, {
				StateMachineId = "Toggle_Equip",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
			})

			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("Completed")
			expect(created[1].StateMachineClass).toEqual("EquipJob")
			expect(created[1].Context.ItemId).toEqual("Sword")

			env:Cleanup()
		end)

		it("should run the unequip branch when a weapon is already equipped", function()
			local env = Helpers.newEnvironment()
			local character = Helpers.makeCharacterRig(env, "ToggleUnEquipCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
				EquippedRight = "Sword",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				WeaponEqp = "Sword",
			})

			local created = {}
			env.Orchestrator.CreateStateMachine = function(params)
				table.insert(created, params)
				return Helpers.makeChildJob("completed")
			end

			local machine = env.Mock:CreateFSM(ToggleWeaponJob, {
				StateMachineId = "Toggle_UnEquip",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
			})

			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("Completed")
			expect(created[1].StateMachineClass).toEqual("UnEquipJob")
			expect(created[1].Context.Hand).toEqual("Right")

			env:Cleanup()
		end)

		it("should fail when no weapon is selected", function()
			local env = Helpers.newEnvironment()
			local character = Helpers.makeCharacterRig(env, "ToggleFailCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				WeaponEqp = "",
				Inventory = {},
			})

			local machine = env.Mock:CreateFSM(ToggleWeaponJob, {
				StateMachineId = "Toggle_NoSelection",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("No weapon selected")

			env:Cleanup()
		end)
	end)
end

TR.register(spec)
return spec
