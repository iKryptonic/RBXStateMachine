--!strict
-- @Name ServiceManager/Tests/Specs/InventoryManagement.spec.luau
-- @Author iKrypto
-- @Description Contract tests for the consolidated inventory item FSM.

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.Parent.Mocks.StateMachineSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function loadJob()
		local job = Helpers.requireStateMachine("InventoryItemFSM")
		return job, Helpers.captureStates(job)
	end

	describe("InventoryItemFSM", function()
		it("loads with the merged state graph", function()
			local job = loadJob()
			expect(job.Name).toEqual("InventoryItemFSM")
			expect(job.className).toEqual("InventoryItemFSM")
			expect(job.validStates).toEqual({
				"Validate", "RouteBranch",
				"CheckCapacity", "AddToInventory",
				"FindItem", "RemoveFromInventory",
				"CheckIfEquipped", "UnequipIfNeeded", "SpawnWorldItem",
				"ResolveSource", "MoveItem",
				"Commit", "Completed", "Failed",
			})
			expect(job.terminalStates).toEqual({ "Completed", "Failed" })
		end)

		it("routes each operation to the correct branch entry state", function()
			local _, states = loadJob()

			local addFsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				Context = { Operation = "Add" },
			})
			states.RouteBranch.Definition.OnEnter(nil, addFsm)
			expect(addFsm.State).toEqual("CheckCapacity")

			local removeFsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				Context = { Operation = "Remove" },
			})
			states.RouteBranch.Definition.OnEnter(nil, removeFsm)
			expect(removeFsm.State).toEqual("FindItem")

			local dropFsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				Context = { Operation = "Drop" },
			})
			states.RouteBranch.Definition.OnEnter(nil, dropFsm)
			expect(dropFsm.State).toEqual("CheckIfEquipped")

			local moveFsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				Context = { Operation = "Move" },
			})
			states.RouteBranch.Definition.OnEnter(nil, moveFsm)
			expect(moveFsm.State).toEqual("ResolveSource")

			local invalidFsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				Context = { Operation = "Craft" },
			})
			states.RouteBranch.Definition.OnEnter(nil, invalidFsm)
			expect(invalidFsm.Failure).toEqual("Unknown operation: Craft")
		end)

		it("fails capacity checks at MAX_INVENTORY_SIZE", function()
			local _, states = loadJob()
			local fullInventory = {}
			for index = 1, 100 do
				table.insert(fullInventory, tostring(index))
			end
			local playerEntity = Helpers.makePlayerEntity({
				EntityId = "Player_Add",
				Inventory = fullInventory,
			})
			local fsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				Context = { _playerEntity = playerEntity },
			})

			states.CheckCapacity.Definition.OnEnter(nil, fsm)

			expect(fsm.Failure).toEqual("Inventory is full")
		end)

		it("handles item-not-found in inventory and bag", function()
			local _, states = loadJob()
			local playerEntity = Helpers.makePlayerEntity({
				EntityId = "Player_Remove",
				Inventory = { "1", "2" },
				BagContents = { "3" },
			})
			local fsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				Context = {
					Operation = "Remove",
					_playerEntity = playerEntity,
					ItemId = "9",
				},
			})

			states.FindItem.Definition.OnEnter(nil, fsm)

			expect(fsm.Failure).toEqual("Item not found in Inventory or BagContents")
		end)

		it("accepts move directions and resolves source containers", function()
			local _, states = loadJob()
			local playerEntity = Helpers.makePlayerEntity({
				EntityId = "Player_Move",
				Inventory = { "1" },
				BagContents = { "2" },
			})
			local orchestrator = Helpers.makeOrchestrator({
				entities = { Player_Move = playerEntity },
			})

			local toBagFsm = Helpers.makeFSM(orchestrator, {
				Context = {
					Operation = "Move",
					PlayerEntityId = "Player_Move",
					ItemId = "1",
					Direction = "ToBag",
				},
			})
			states.Validate.Definition.OnEnter(nil, toBagFsm)
			expect(toBagFsm.State).toEqual("RouteBranch")
			states.ResolveSource.Definition.OnEnter(nil, toBagFsm)
			expect(toBagFsm.Context._sourceField).toEqual("Inventory")
			expect(toBagFsm.Context._destinationField).toEqual("BagContents")
			expect(toBagFsm.State).toEqual("MoveItem")

			local toInventoryFsm = Helpers.makeFSM(orchestrator, {
				Context = {
					Operation = "Move",
					PlayerEntityId = "Player_Move",
					ItemId = "2",
					Direction = "ToInventory",
				},
			})
			states.Validate.Definition.OnEnter(nil, toInventoryFsm)
			expect(toInventoryFsm.State).toEqual("RouteBranch")
			states.ResolveSource.Definition.OnEnter(nil, toInventoryFsm)
			expect(toInventoryFsm.Context._sourceField).toEqual("BagContents")
			expect(toInventoryFsm.Context._destinationField).toEqual("Inventory")
			expect(toInventoryFsm.State).toEqual("MoveItem")

			local invalidFsm = Helpers.makeFSM(orchestrator, {
				Context = {
					Operation = "Move",
					PlayerEntityId = "Player_Move",
					ItemId = "1",
					Direction = "Sideways",
				},
			})
			states.Validate.Definition.OnEnter(nil, invalidFsm)
			expect(invalidFsm.Failure).toEqual("Invalid Direction")
		end)
	end)
end

TR.register(spec)
return spec
