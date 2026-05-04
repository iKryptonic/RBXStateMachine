--!strict

local Debris = game:GetService("Debris")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MAX_INVENTORY_SIZE = 100

--[=[
	@module InventoryItemFSM
	@description Adds, removes, moves, or drops inventory items, including optional unequip work before a drop and world-item spawning for dropped assets.
]=]

local InventoryItemFSM = {
	Name = "InventoryItemFSM",
	className = "InventoryItemFSM",
	validStates = {
		"Validate","RouteBranch",
		"CheckCapacity","AddToInventory",
		"FindItem","RemoveFromInventory",
		"CheckIfEquipped","UnequipIfNeeded","SpawnWorldItem",
		"ResolveSource","MoveItem",
		"Commit","Completed","Failed",
	},
	terminalStates = {"Completed","Failed" },
	initialState = "Validate",
}

-- @param container any
-- @return { any }
-- @reads container
-- @writes none
-- Returns a cloned inventory-like container when possible.
--[=[
	@description Clones the container.
	@param container any  -- Container table to inspect or mutate.
	@return any -- Result returned by `cloneContainer`, mirrored through this wrapper.
]=]

local function cloneContainer(container: any): { any }
	if typeof(container) == "table" then
		return table.clone(container)
	end
	return {}
end

-- @param container any
-- @param itemId string
-- @return number?
-- @reads container
-- @writes none
-- Resolves an item id from primitive or table-backed inventory entries.
--[=[
	@description Finds the item index for the current request.
	@param container any  -- Container table to inspect or mutate.
	@param itemId any  -- Item identifier for the request.
	@return number -- Numeric value derived for downstream logic.
]=]

local function findItemIndex(container: any, itemId: string): number?
	if typeof(container) ~= "table" then
		return nil
	end

	for index, value in ipairs(container) do
		if value == itemId then
			return index
		end
		if typeof(value) == "table" then
			local resolvedId = value.ItemId or value.Id or value.itemId or value.id
			if typeof(resolvedId) == "string" and resolvedId == itemId then
				return index
			end
		end
	end

	return nil
end

-- @param character Model
-- @return BasePart?
-- @reads character.PrimaryPart, character descendants
-- @writes none
-- Returns the best available root part for item drop positioning.
--[=[
	@description Returns the root part for this FSM, or `nil` when it cannot be found.
	@param character any  -- Character model associated with the request.
	@return any -- Resolved root part, or `nil` when unavailable.
]=]

local function getRootPart(character: Model): BasePart?
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return character.PrimaryPart or character:FindFirstChildWhichIsA("BasePart", true)
end

-- @param character Model
-- @return CFrame?
-- @reads character root part transform
-- @writes none
-- Computes a forward-biased drop position in front of the character.
--[=[
	@description Returns the drop cframe for this FSM, or `nil` when it cannot be found.
	@param character any  -- Character model associated with the request.
	@return any -- Resolved drop c frame, or `nil` when unavailable.
]=]

local function getDropCFrame(character: Model): CFrame?
	local rootPart = getRootPart(character)
	if not rootPart then
		return nil
	end

	local forward = rootPart.CFrame.LookVector
	local horizontal = Vector3.new(forward.X, 0, forward.Z)
	if horizontal.Magnitude <= 0.01 then
		horizontal = Vector3.new(0, 0, -1)
	else
		horizontal = horizontal.Unit
	end

	local position = rootPart.Position + horizontal * 3 + Vector3.new(0, 1.5, 0)
	return CFrame.new(position, position + horizontal)
end

-- @param instance Instance
-- @reads instance descendants
-- @writes BasePart.CanCollide
-- Enables collisions on dropped world items.
--[=[
	@description Enables collision.
	@param instance any  -- Dropped item instance whose collidable parts should be enabled.
	@return nil -- Performs this helper's work in place.
]=]

local function enableCollision(instance: Instance)
	if instance:IsA("BasePart") then
		instance.CanCollide = true
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = true
		end
	end
end

-- @param item Instance
-- @param targetCFrame CFrame
-- @return boolean
-- @reads item hierarchy
-- @writes item transform
-- Positions a cloned dropped item using the first viable transform target.
--[=[
	@description Positions dropped item.
	@param item any  -- Cloned dropped item that should be positioned in the world.
	@param targetCFrame any  -- World transform to apply to the dropped item.
	@return boolean -- Whether the helper completed successfully.
]=]

local function positionDroppedItem(item: Instance, targetCFrame: CFrame): boolean
	if item:IsA("Model") then
		item:PivotTo(targetCFrame)
		return true
	end

	if item:IsA("BasePart") then
		item.CFrame = targetCFrame
		return true
	end

	local basePart = item:FindFirstChildWhichIsA("BasePart", true)
	if basePart then
		basePart.CFrame = targetCFrame
		return true
	end

	return false
end

-- @param fsm any
-- @param hand string
-- @reads fsm.Context, orchestrator state machine factory
-- @writes fsm.Context._activeUnEquipJob, fsm managed cleanup
-- Spawns and manages the drop-flow UnEquipJob child FSM.
--[=[
	@description Starts unequip job.
	@param fsm any  -- InventoryItemFSM instance carrying the current inventory operation and staged containers.
	@param hand any  -- Hand being read or updated.
	@return nil -- Performs this helper's work in place.
]=]

local function beginUnequipJob(fsm: any, hand: string)
	local orchestrator = fsm:GetOrchestrator()
	local childJob = orchestrator.CreateStateMachine({
		StateMachineClass = "UnEquipJob",
		StateMachineId = string.format(
			"%s_UnEquip_%s",
			tostring(fsm.Id or "InventoryItemFSM"),
			HttpService:GenerateGUID(false)
		),
		Context = {
			CharacterEntityId = fsm.Context.CharacterEntityId,
			PlayerEntityId = fsm.Context.PlayerEntityId,
			Hand = hand,
		},
		AutoStart = false,
	})
	if not childJob then
		fsm:Fail("Failed to create UnEquipJob")
		return
	end

	fsm.Context._activeUnEquipJob = childJob
	fsm:Manage(function()
		if childJob.IsActive then
			childJob:Cancel()
		end
	end)
	fsm:Manage(childJob.Completed:Connect(function()
		if fsm.IsActive and fsm.State == "UnequipIfNeeded" then
			fsm.State = "FindItem"
		end
	end))
	fsm:Manage(childJob.Failed:Connect(function(reason)
		if fsm.IsActive and fsm.State == "UnequipIfNeeded" then
			local suffix = if reason and tostring(reason) ~= "" then": " .. tostring(reason) else""
			fsm:Fail("UnEquipJob failed" .. suffix)
		end
	end))
	fsm:Manage(childJob.Cancelled:Connect(function()
		if fsm.IsActive and fsm.State == "UnequipIfNeeded" then
			fsm:Fail("UnEquipJob cancelled")
		end
	end))

	childJob:Start({ State = "ValidateRequest" })
end

--[=[
	@description Registers the runtime states, transitions, and terminal behavior for `InventoryItemFSM`.
	@return nil -- Populates the state graph on the FSM definition table.
]=]

function InventoryItemFSM:RegisterStates()

	--[=[
	@state Validate
	@description Normalizes operation, player/item ids, resolves the player entity, and loads extra character or direction context required for drop and move requests.
	Transitions:
	- `RouteBranch` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: none.

]=]

	self:AddState("Validate", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local context = fsm.Context
			local operation = tostring(context.Operation or fsm.Operation or "")
			local playerEntityId = tostring(context.PlayerEntityId or "")
			if playerEntityId == "" then
				fsm:Fail("Missing PlayerEntityId")
				return
			end

			local itemId = tostring(context.ItemId or "")
			if itemId == "" then
				fsm:Fail("Missing ItemId")
				return
			end

			local playerEntity = orchestrator.GetEntity(playerEntityId)
			if not playerEntity then
				fsm:Fail("PlayerEntity not found")
				return
			end

			context.Operation = operation
			context.PlayerEntityId = playerEntityId
			context.ItemId = itemId
			context._playerEntity = playerEntity

			if operation == "Drop" then
				local characterEntityId = tostring(context.CharacterEntityId or "")
				if characterEntityId == "" then
					fsm:Fail("Missing CharacterEntityId")
					return
				end

				local charEntity = orchestrator.GetEntity(characterEntityId)
				if not charEntity then
					fsm:Fail("CharacterEntity not found")
					return
				end

				context.CharacterEntityId = characterEntityId
				context._charEntity = charEntity
			elseif operation == "Move" then
				local direction = tostring(context.Direction or "")
				if direction ~= "ToBag" and direction ~= "ToInventory" then
					fsm:Fail("Invalid Direction")
					return
				end

				context.Direction = direction
			end

			fsm.State = "RouteBranch"
		end,
	}, {"RouteBranch","Failed" })

	--[=[
	@state RouteBranch
	@description Dispatches add, remove, drop, and move requests to the matching inventory flow state.
	Transitions:
	- `CheckCapacity` when OnEnter finishes or falls through its guard checks.
	- `FindItem` when OnEnter finishes or falls through its guard checks.
	- `CheckIfEquipped` when OnEnter finishes or falls through its guard checks.
	- `ResolveSource` when OnEnter finishes or falls through its guard checks.
	Writes: none.

]=]

	self:AddState("RouteBranch", {
		OnEnter = function(_, fsm)
			local op = tostring(fsm.Operation or "")
			if op == "Add" then
				fsm.State = "CheckCapacity"
			elseif op == "Remove" then
				fsm.State = "FindItem"
			elseif op == "Drop" then
				fsm.State = "CheckIfEquipped"
			elseif op == "Move" then
				fsm.State = "ResolveSource"
			else
				fsm:Fail("Unknown operation: " .. tostring(op))
			end
		end,
	}, {"CheckCapacity","FindItem","CheckIfEquipped","ResolveSource","Failed" })

	--[=[
	@state CheckCapacity
	@description Clones the current inventory and rejects add requests once the fixed inventory cap is reached.
	Transitions:
	- `AddToInventory` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: none.

]=]

	self:AddState("CheckCapacity", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local playerEntity = context._playerEntity
			if not playerEntity then
				fsm:Fail("PlayerEntity no longer exists")
				return
			end

			local inventory = cloneContainer(playerEntity.Inventory)
			if #inventory >= MAX_INVENTORY_SIZE then
				fsm:Fail("Inventory is full")
				return
			end

			context._nextInventory = inventory
			fsm.State = "AddToInventory"
		end,
	}, {"AddToInventory","Failed" })

	--[=[
	@state AddToInventory
	@description Appends the requested item id to the staged inventory clone and writes it back to the player entity before commit.
	Transitions:
	- `Commit` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: sets `Inventory`.

]=]

	self:AddState("AddToInventory", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local playerEntity = context._playerEntity
			if not playerEntity then
				fsm:Fail("PlayerEntity no longer exists")
				return
			end

			local nextInventory = cloneContainer(context._nextInventory)
			table.insert(nextInventory, context.ItemId)
			playerEntity.Inventory = nextInventory
			context._nextInventory = nextInventory
			fsm.State = "Commit"
		end,
	}, {"Commit","Failed" })

	--[=[
	@state FindItem
	@description Searches inventory first, then bag contents, caching the source container and index for removal.
	Transitions:
	- `RemoveFromInventory` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: none.

]=]

	self:AddState("FindItem", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local playerEntity = context._playerEntity
			if not playerEntity then
				fsm:Fail("PlayerEntity no longer exists")
				return
			end

			local inventoryIndex = findItemIndex(playerEntity.Inventory, context.ItemId)
			if inventoryIndex ~= nil then
				context._sourceField = "Inventory"
				context._sourceIndex = inventoryIndex
				fsm.State = "RemoveFromInventory"
				return
			end

			local bagIndex = findItemIndex(playerEntity.BagContents, context.ItemId)
			if bagIndex ~= nil then
				context._sourceField = "BagContents"
				context._sourceIndex = bagIndex
				fsm.State = "RemoveFromInventory"
				return
			end

			fsm:Fail("Item not found in Inventory or BagContents")
		end,
	}, {"RemoveFromInventory","Failed" })

	--[=[
	@state RemoveFromInventory
	@description Removes the resolved item from its source container and branches to drop spawning or commit based on the requested operation.
	Transitions:
	- `SpawnWorldItem` when OnEnter finishes or falls through its guard checks.
	- `Commit` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: none.

]=]

	self:AddState("RemoveFromInventory", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local playerEntity = context._playerEntity
			local sourceField = context._sourceField
			local sourceIndex = context._sourceIndex
			if not playerEntity then
				fsm:Fail("PlayerEntity no longer exists")
				return
			end
			if typeof(sourceField) ~= "string" or typeof(sourceIndex) ~= "number" then
				fsm:Fail("No source item resolved")
				return
			end

			local sourceContainer = cloneContainer(playerEntity[sourceField])
			if sourceIndex < 1 or sourceIndex > #sourceContainer then
				fsm:Fail("Resolved item index is out of range")
				return
			end

			table.remove(sourceContainer, sourceIndex)
			playerEntity[sourceField] = sourceContainer
			if context.Operation == "Drop" then
				context._removedField = sourceField
				fsm.State = "SpawnWorldItem"
			elseif context.Operation == "Remove" then
				fsm.State = "Commit"
			else
				fsm:Fail("RemoveFromInventory only supports Remove and Drop operations")
			end
		end,
	}, {"Commit","SpawnWorldItem","Failed" })

	--[=[
	@state CheckIfEquipped
	@description Checks whether the drop target is currently equipped in either hand and caches that hand for forced unequip.
	Transitions:
	- `UnequipIfNeeded` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: sets `EquippedRight`, sets `EquippedLeft`.

]=]

	self:AddState("CheckIfEquipped", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local charEntity = context._charEntity
			if not charEntity then
				fsm:Fail("CharacterEntity no longer exists")
				return
			end

			local itemId = context.ItemId
			local equippedHand = nil :: string?
			if charEntity.EquippedRight == itemId then
				equippedHand = "Right"
			elseif charEntity.EquippedLeft == itemId then
				equippedHand = "Left"
			end

			context._isEquipped = equippedHand ~= nil
			context._equippedHand = equippedHand
			fsm.State = "UnequipIfNeeded"
		end,
	}, {"UnequipIfNeeded","Failed" })

	--[=[
	@state UnequipIfNeeded
	@description Starts the child unequip job when the item is still equipped; otherwise it proceeds directly to item lookup.
	Transitions:
	- `FindItem` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: none.

]=]

	self:AddState("UnequipIfNeeded", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			if context._isEquipped ~= true then
				fsm.State = "FindItem"
				return
			end

			local hand = context._equippedHand
			if typeof(hand) ~= "string" or hand == "" then
				fsm:Fail("Equipped hand could not be resolved")
				return
			end

			beginUnequipJob(fsm, hand)
		end,
	}, {"FindItem","Failed" })

	--[=[
	@state SpawnWorldItem
	@description Clones the dropped item into workspace, positions it in front of the character, enables collision, and tracks it for later cleanup.
	Transitions:
	- `Commit` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: sets `Parent`.

]=]

	self:AddState("SpawnWorldItem", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local charEntity = context._charEntity
			if not charEntity then
				fsm:Fail("CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				fsm:Fail("Character model is unavailable")
				return
			end

			local assets = ReplicatedStorage:FindFirstChild("Assets")
			if not assets then
				fsm:Fail("ReplicatedStorage.Assets not found")
				return
			end

			local sourceItem = assets:FindFirstChild(context.ItemId, true)
			if not sourceItem then
				fsm:Fail("Item asset not found: " .. tostring(context.ItemId))
				return
			end

			local dropCFrame = getDropCFrame(character)
			if not dropCFrame then
				fsm:Fail("Character root part is unavailable")
				return
			end

			local worldItem = sourceItem:Clone()
			worldItem.Parent = workspace
			if not positionDroppedItem(worldItem, dropCFrame) then
				worldItem:Destroy()
				fsm:Fail("Dropped asset has no BasePart: " .. tostring(context.ItemId))
				return
			end

			enableCollision(worldItem)
			Debris:AddItem(worldItem, 30)
			context._worldItem = worldItem
			fsm.State = "Commit"
		end,
	}, {"Commit","Failed" })

	--[=[
	@state ResolveSource
	@description Picks the source and destination containers for move requests, then resolves the source index of the item to move.
	Transitions:
	- `MoveItem` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: none.

]=]

	self:AddState("ResolveSource", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local playerEntity = context._playerEntity
			local direction = context.Direction
			if not playerEntity then
				fsm:Fail("PlayerEntity no longer exists")
				return
			end

			if direction == "ToBag" then
				context._sourceField = "Inventory"
				context._destinationField = "BagContents"
			elseif direction == "ToInventory" then
				context._sourceField = "BagContents"
				context._destinationField = "Inventory"
			else
				fsm:Fail("Invalid Direction")
				return
			end

			local sourceIndex = findItemIndex(playerEntity[context._sourceField], context.ItemId)
			if sourceIndex == nil then
				fsm:Fail("Item not found in source container")
				return
			end

			context._sourceIndex = sourceIndex
			fsm.State = "MoveItem"
		end,
	}, {"MoveItem","Failed" })

	--[=[
	@state MoveItem
	@description Moves the resolved item from the source container to the destination container, enforcing inventory capacity on moves into inventory.
	Transitions:
	- `Commit` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: none.

]=]

	self:AddState("MoveItem", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local playerEntity = context._playerEntity
			local sourceField = context._sourceField
			local destinationField = context._destinationField
			local sourceIndex = context._sourceIndex
			if not playerEntity then
				fsm:Fail("PlayerEntity no longer exists")
				return
			end
			if typeof(sourceField) ~= "string" or typeof(destinationField) ~= "string" or typeof(sourceIndex) ~= "number" then
				fsm:Fail("Move context is incomplete")
				return
			end

			local sourceContainer = cloneContainer(playerEntity[sourceField])
			local destinationContainer = cloneContainer(playerEntity[destinationField])
			if sourceIndex < 1 or sourceIndex > #sourceContainer then
				fsm:Fail("Resolved item index is out of range")
				return
			end
			if destinationField == "Inventory" and #destinationContainer >= MAX_INVENTORY_SIZE then
				fsm:Fail("Inventory is full")
				return
			end

			table.remove(sourceContainer, sourceIndex)
			table.insert(destinationContainer, context.ItemId)
			playerEntity[sourceField] = sourceContainer
			playerEntity[destinationField] = destinationContainer
			fsm.State = "Commit"
		end,
	}, {"Commit","Failed" })

	--[=[
	@state Commit
	@description Replicates the player entity after the staged inventory mutation and writes an operation-specific audit log when applicable.
	Transitions:
	- `Completed` when OnEnter finishes or falls through its guard checks.
	- `Failed` when validation or downstream work reports an unrecoverable problem.
	Writes: replicates entity changes, writes to the log.

]=]

	self:AddState("Commit", {
		OnEnter = function(_, fsm)
			local context = fsm.Context
			local playerEntity = context._playerEntity
			if not playerEntity then
				fsm:Fail("PlayerEntity no longer exists")
				return
			end

			playerEntity:UpdateEntity()
			if context.Operation == "Add" then
				fsm:Log({
					Level = "INFO",
					Message = string.format("Added item %s to %s", tostring(context.ItemId), tostring(context.PlayerEntityId)),
				})
			elseif context.Operation == "Drop" then
				fsm:Log({
					Level = "INFO",
					Message = string.format("Dropped item %s from %s", tostring(context.ItemId), tostring(context.PlayerEntityId)),
				})
			end
			fsm.State = "Completed"
		end,
	}, {"Completed","Failed" })
	--[=[
	@state Completed
	@description Terminal success sink reached after the add/drop operation has updated player inventory state, replicated the entity, and written the audit log entry. `OnEnter` is a no-op.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Completed", function(_fsm) end, {})
	--[=[
	@state Failed
	@description Terminal failure sink for invalid inventory requests, missing entities, or persistence errors during add/drop handling. `OnEnter` is a no-op.
	Transitions: none.
	Writes: none.

]=]

	self:AddState("Failed", function(_fsm) end, {})
end

return InventoryItemFSM
