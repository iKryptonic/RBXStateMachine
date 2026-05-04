--!strict

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local LoadPlayerJob = Helpers.getStateMachine("LoadPlayerJob")
	local PlayerTeardownFSM = Helpers.getStateMachine("PlayerTeardownFSM")
	local SpawnCharacterJob = Helpers.getStateMachine("SpawnCharacterJob")
	local InventoryItemFSM = Helpers.getStateMachine("InventoryItemFSM")

	describe("LoadPlayerJob", function()
		it("should create player and character entities and register commands", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env, { IsAbilityUnlocked = true })

			local character = Helpers.makeCharacterRig(env, "PlayerLoadCharacter")
			local player = Helpers.makeFakePlayer(321, character)
			local registered = {}
			env.Orchestrator.RegisterEntityCommandCallback = function(entityId, command, handler)
				registered[command] = { EntityId = entityId, Handler = handler }
			end

			local machine = env.Mock:CreateFSM(LoadPlayerJob, {
				StateMachineId = "LoadPlayer_Happy",
				Player = player,
				UserId = 321,
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			expect(env.Orchestrator.GetEntity("Player_321")).never.toBeNil()
			expect(env.Orchestrator.GetEntity("Char_321")).never.toBeNil()
			expect(registered.RequestMeleeAttack.EntityId).toEqual("Char_321")
			expect(registered.ToggleWeapon.EntityId).toEqual("Char_321")
			expect(registered.RequestAbility.EntityId).toEqual("Char_321")

			env:Cleanup()
		end)

		it("should fail validation for an invalid player reference", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local invalidPlayer = {
				UserId = 0,
				IsA = function()
					return false
				end,
			}
			local machine = env.Mock:CreateFSM(LoadPlayerJob, {
				StateMachineId = "LoadPlayer_Invalid",
				Player = invalidPlayer,
				UserId = 0,
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("Invalid player reference")

			env:Cleanup()
		end)

		it("should wait for the character to appear before creating the character entity", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local player = Helpers.makeFakePlayer(654, nil)
			env.Orchestrator.RegisterEntityCommandCallback = function() end
			local machine = env.Mock:CreateFSM(LoadPlayerJob, {
				StateMachineId = "LoadPlayer_Await",
				Player = player,
				UserId = 654,
			})

			expect(Helpers.stepUntil(env, machine, "AwaitCharacter", 10)).toBeTruthy()
			player.Character = Helpers.makeCharacterRig(env, "AwaitedCharacter")
			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			expect(env.Orchestrator.GetEntity("Char_654")).never.toBeNil()

			env:Cleanup()
		end)
	end)

	describe("PlayerTeardownFSM", function()
		it("should cancel active state machines flush persistence and delete entities", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {})
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})
			playerEntity._privateProperties = { Context = { _IsPersistent = true } }
			charEntity._privateProperties = { Context = { _IsPersistent = true } }

			local cancelled = {}
			env.Mock.stateMachines.ActiveCast = {
				Context = { CharacterEntityId = "Char_1", PlayerEntityId = "Player_1" },
				Cancel = function()
					table.insert(cancelled, "ActiveCast")
				end,
			}
			env.Mock.stateMachines.ActiveStatus = {
				Context = { UserId = 55 },
				Cancel = function()
					table.insert(cancelled, "ActiveStatus")
				end,
			}

			local saved = {}
			env.Orchestrator.Factory = {
				PersistenceManager = {
					SaveState = function(entity)
						table.insert(saved, entity.EntityId)
					end,
				},
			}
			local deleted = {}
			env.Orchestrator.DeleteEntity = function(entityId)
				table.insert(deleted, entityId)
				env.Mock.entities[entityId] = nil
			end

			local machine = env.Mock:CreateFSM(PlayerTeardownFSM, {
				StateMachineId = "Teardown_Player",
				UserId = 55,
				PlayerEntityId = playerEntity.EntityId,
				CharacterEntityId = charEntity.EntityId,
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(cancelled).toContain("ActiveCast")
			expect(cancelled).toContain("ActiveStatus")
			expect(saved).toContain("Player_1")
			expect(saved).toContain("Char_1")
			expect(deleted).toContain("Player_1")
			expect(deleted).toContain("Char_1")

			env:Cleanup()
		end)

		it("should ignore unrelated state machines during cancellation", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local cancelled = false
			env.Mock.stateMachines.Unrelated = {
				Context = { CharacterEntityId = "OtherChar" },
				Cancel = function()
					cancelled = true
				end,
			}
			env.Orchestrator.DeleteEntity = function() end

			local machine = env.Mock:CreateFSM(PlayerTeardownFSM, {
				StateMachineId = "Teardown_Unrelated",
				UserId = 99,
				PlayerEntityId = "Player_1",
				CharacterEntityId = "Char_1",
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(cancelled).toBeFalsy()

			env:Cleanup()
		end)

		it("should log completion after deleting entities", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			env.Orchestrator.DeleteEntity = function() end

			local machine = env.Mock:CreateFSM(PlayerTeardownFSM, {
				StateMachineId = "Teardown_Log",
				UserId = 1,
				PlayerEntityId = "Player_1",
				CharacterEntityId = "Char_1",
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(machine.Logs[#machine.Logs].Message).toContain("completed")

			env:Cleanup()
		end)
	end)

	describe("SpawnCharacterJob", function()
		it("should validate bind the entity and apply loadout", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character = Helpers.makeCharacterRig(env, "SpawnCharacter")
			local player = Helpers.makeFakePlayer(999, character)
			local charEntity = Helpers.createCharacterEntity(env, "Char_999", {
				IsBlocking = true,
				CanMove = false,
				MoveSpeedCap = 0,
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_999", {
				Equipped = { Right = "Sword", Left = "Shield" },
			})

			local created = {}
			env.Orchestrator.CreateStateMachine = function(params)
				table.insert(created, params)
				return { Start = function(_, args) params._startedWith = args end }
			end

			local machine = env.Mock:CreateFSM(SpawnCharacterJob, {
				StateMachineId = "SpawnCharacter_Happy",
				Player = player,
				Character = character,
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(charEntity.Instance).toBe(character)
			expect(charEntity.IsBlocking).toBeFalsy()
			expect(charEntity.CanMove).toBeTruthy()
			expect(charEntity.MoveSpeedCap).toEqual(16)
			expect(#created).toEqual(2)
			expect(created[1].StateMachineClass).toEqual("EquipJob")

			env:Cleanup()
		end)

		it("should fail validation when player or character is missing", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local invalidPlayer = {
				IsA = function()
					return false
				end,
			}
			local machine = env.Mock:CreateFSM(SpawnCharacterJob, {
				StateMachineId = "SpawnCharacter_Invalid",
				Player = invalidPlayer,
				Character = nil,
				CharacterEntityId = "Char_1",
				PlayerEntityId = "Player_1",
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("Missing Player or Character")

			env:Cleanup()
		end)

		it("should complete even when there is no saved loadout", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character = Helpers.makeCharacterRig(env, "SpawnNoLoadout")
			local player = Helpers.makeFakePlayer(1000, character)
			local charEntity = Helpers.createCharacterEntity(env, "Char_1000", {})
			Helpers.createPlayerEntity(env, "Player_1000", { Equipped = {} })

			local machine = env.Mock:CreateFSM(SpawnCharacterJob, {
				StateMachineId = "SpawnCharacter_NoLoadout",
				Player = player,
				Character = character,
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = "Player_1000",
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")

			env:Cleanup()
		end)
	end)

	describe("InventoryItemFSM", function()
		it("should add items through RouteBranch", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", { Inventory = {} })

			local machine = env.Mock:CreateFSM(InventoryItemFSM, {
				StateMachineId = "Inventory_Add",
				Operation = "Add",
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Potion",
			})

			env.Mock:StepFrames(3)
			expect(machine.State).toEqual("Completed")
			expect(playerEntity.Inventory).toContain("Potion")

			env:Cleanup()
		end)

		it("should remove items through RouteBranch", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", { Inventory = { "Potion", "Sword" } })

			local machine = env.Mock:CreateFSM(InventoryItemFSM, {
				StateMachineId = "Inventory_Remove",
				Operation = "Remove",
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Potion",
			})

			env.Mock:StepFrames(3)
			expect(machine.State).toEqual("Completed")
			expect(playerEntity.Inventory).never.toContain("Potion")

			env:Cleanup()
		end)

		it("should drop equipped items through RouteBranch", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			Helpers.ensureAsset(env, "Sword")

			local character = Helpers.makeCharacterRig(env, "InventoryDropCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				EquippedRight = "Sword",
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Inventory = {},
			})

			env.Orchestrator.CreateStateMachine = function(_params)
				return Helpers.makeChildJob("completed", function()
					charEntity.EquippedRight = ""
					playerEntity.Inventory = { "Sword" }
				end)
			end

			local machine = env.Mock:CreateFSM(InventoryItemFSM, {
				StateMachineId = "Inventory_Drop",
				Operation = "Drop",
				PlayerEntityId = playerEntity.EntityId,
				CharacterEntityId = charEntity.EntityId,
				ItemId = "Sword",
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 20)).toBeTruthy()
			expect(machine.Context._worldItem).never.toBeNil()
			expect(playerEntity.Inventory).never.toContain("Sword")

			env:Cleanup()
		end)

		it("should move items between inventory containers through RouteBranch", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Inventory = { "Sword" },
				BagContents = {},
			})

			local machine = env.Mock:CreateFSM(InventoryItemFSM, {
				StateMachineId = "Inventory_Move",
				Operation = "Move",
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Sword",
				Direction = "ToBag",
			})

			env.Mock:StepFrames(5)
			expect(machine.State).toEqual("Completed")
			expect(playerEntity.Inventory).never.toContain("Sword")
			expect(playerEntity.BagContents).toContain("Sword")

			env:Cleanup()
		end)
	end)
end

TR.register(spec)
return spec
