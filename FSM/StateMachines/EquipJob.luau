--!strict
--[=[
    @Name EquipJob
    @Author iKrypto
    @Description Equips an inventory item into a requested hand by validating ownership, serializing access with the per-hand equip lock, cloning and mounting the asset, committing replicated character and player state, emitting the equip intent, and finally releasing the lock. If any stage calls `queueRollback`, the flow destroys the new clone, attempts to restore any captured previous item snapshot, releases the lock, and ends in `Failed`. Historical integrations must target `Completed`; the deprecated `Complete` spelling is intentionally not used.

    State flow diagram:
    ValidateRequest → AcquireEquipLock → ResolveItemMeta → PreUnEquip → CloneAsset → CreateWeld → MountItem → CommitState → EmitIntent → ReleaseEquipLock → Completed
                    ↘ Rollback → ReleaseEquipLock → Failed

    Context fields:
    - Hand: string -- normalized hand name (`Right` or `Left`).
    - ItemId: string -- normalized item id being equipped.
    - _equipLockRetryCount: number -- retry counter while waiting for a stale per-hand equip lock.
    - _equipLockHeld: boolean -- whether this job currently owns the per-hand equip lock.
    - _clonedItem: Instance -- cloned weapon model tracked for rollback.
    - _itemData: any -- required item data module contents.
    - _handle: BasePart -- resolved handle or fallback base part used for welding.
    - _weld: WeldConstraint? -- weld created between the hand part and handle.
    - _handPart: BasePart? -- resolved hand part receiving the mounted item.
    - _previousItemId: string? -- previously equipped item id returned to inventory on successful swap.
    - _previousItem: Instance? -- optional previous item snapshot used only when rollback restoration data was captured externally.
    - _previousItemData: any? -- optional metadata used when rollback attempts to remount the previous item.
    - _previousItemAction: string? -- optional label describing the step that triggered rollback during previous-item restoration.
    - _failureReason: string? -- reason recorded by rollback helpers and logged during lock release.

    Required params:
    - CharacterEntityId: string -- character entity that will hold the equipped item.
    - PlayerEntityId: string -- player entity whose inventory/equipped state is updated.
    - ItemId: string -- asset and inventory id to equip.
    - Hand: string? -- optional hand override; defaults to `Right`.

    Notes:
    - `fsm:TrackInstance(item, ..., true)` uses the `trackOnly` form so the cloned asset is registered for cleanup bookkeeping without changing the explicit rollback ownership model. `Rollback` still destroys `_clonedItem` itself.
    - This job does not set `_wasStowed`; when swapping items it destroys old hand-held or stowed duplicates instead of preserving a visual stow state.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

local EquipJob = {
	Name = "EquipJob",
	className = "EquipJob",
	validStates = {
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
	},
	terminalStates = { "Completed", "Failed" },
	initialState = "ValidateRequest",
}

local cachedEquipHelpers = nil :: any
local cachedIntentSchema = nil :: any

--[=[
    @description Lazily resolves and caches the shared `EquipHelpers` module for repeated use across states.
    @param orchestrator any -- Orchestrator passed into `ModuleLoader.requireSharedModule`.
    @return any -- Cached `EquipHelpers` module table.
]=]
local function getEquipHelpers(orchestrator: any)
	if not cachedEquipHelpers then
		cachedEquipHelpers = ModuleLoader.requireSharedModule(orchestrator, "EquipHelpers")
	end
	return cachedEquipHelpers
end

--[=[
    @description Lazily resolves and caches the shared `IntentSchema` module used to append equip intents.
    @param orchestrator any -- Orchestrator passed into `ModuleLoader.requireSharedModule`.
    @return any -- Cached `IntentSchema` module table.
]=]
local function getIntentSchema(orchestrator: any)
	if not cachedIntentSchema then
		cachedIntentSchema = ModuleLoader.requireSharedModule(orchestrator, "IntentSchema")
	end
	return cachedIntentSchema
end

--[=[
    @description Maps a hand name to the matching character entity equipped-property field.
    @param hand string -- `Right` or `Left`.
    @return string -- `EquippedRight` for the right hand, otherwise `EquippedLeft`.
]=]
local function getHandProperty(hand: string): string
	return if hand == "Right" then "EquippedRight" else "EquippedLeft"
end

--[=[
    @description Re-resolves the character entity, player entity, and live character model, falling back to the Roblox `Players` service if the cached character instance was replaced server-side.
    @param fsm any -- Active equip FSM instance.
    @return any? -- Current character entity.
    @return any? -- Current player entity.
    @return any? -- Live character model.
]=]
local function ensureEntitiesAlive(fsm): (any?, any?, any?)
	local orchestrator = fsm:GetOrchestrator()
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	local playerEntity = orchestrator.GetEntity(fsm.PlayerEntityId)
	if not charEntity or not playerEntity then
		return nil, nil, nil
	end
	local character = charEntity.Instance
	if not character or not character.Parent then
		-- Server-side fallback: find player's character directly
		local Players = game:GetService("Players")
		local userId = charEntity.UserId or charEntity:GetContext("UserId")
		if userId then
			for _, player in Players:GetPlayers() do
				if player.UserId == userId and player.Character and player.Character.Parent then
					character = player.Character
					break
				end
			end
		end
	end
	if not character or not character.Parent then
		return nil, nil, nil
	end
	return charEntity, playerEntity, character
end

--[=[
    @description Registers every EquipJob state, rollback edge, and terminal no-op with the FSM base class.
    @return nil -- Mutates the module definition by adding states.
]=]
function EquipJob:RegisterStates()
	--[=[
    @state ValidateRequest
    @description Validates the character and player entities, confirms the requested item id exists under assets and is present in bag or inventory when those collections are populated, normalizes the hand, and stores normalized request context.
    @transitions Transitions to `AcquireEquipLock` when the request is well-formed; otherwise transitions to `Failed`.
    @failure Fails immediately when required entities, item id, asset data, inventory ownership, or hand validity checks fail.
    @reads `fsm.CharacterEntityId`, `fsm.PlayerEntityId`, `fsm.ItemId`, `fsm.Hand`, playerEntity.`BagContents`, `Inventory`, `ReplicatedStorage.Assets`.
    @writes `fsm.Context.Hand`, `fsm.Context.ItemId`.
]=]
self:AddState("ValidateRequest", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			local playerEntity = orchestrator.GetEntity(fsm.PlayerEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end
			if not playerEntity then
				fsm:Fail("PlayerEntity not found")
				return
			end

			local itemId = tostring(fsm.ItemId or "")
			if itemId == "" then
				fsm:Fail("No ItemId provided")
				return
			end

			local assets = ReplicatedStorage:FindFirstChild("Assets")
			if not assets or not assets:FindFirstChild(itemId, true) then
				fsm:Fail("Asset not found for item: " .. itemId)
				return
			end

			local hand = fsm.Hand or "Right"
			if hand ~= "Right" and hand ~= "Left" then
				fsm:Fail("Invalid hand: " .. tostring(hand))
				return
			end

			-- Inventory ownership check
			local bag = playerEntity.BagContents
			local inventory = playerEntity.Inventory
			local hasBag = typeof(bag) == "table" and #bag > 0
			local hasInventory = typeof(inventory) == "table" and #inventory > 0
			if hasBag or hasInventory then
				local found = false
				if hasBag and table.find(bag, itemId) then found = true end
				if not found and hasInventory and table.find(inventory, itemId) then found = true end
				if not found then
					fsm:Fail("Item " .. itemId .. " not in inventory")
					return
				end
			end

			fsm.Context.Hand = hand
			fsm.Context.ItemId = itemId
			fsm.State = "AcquireEquipLock"
		end,
	}, { "AcquireEquipLock", "Failed" })

	--[=[
    @state AcquireEquipLock
    @description Serializes equips per hand by cloning the character `EquipLock` table, retrying briefly if another job already owns the hand, and force-clearing a stale lock after the retry budget is exhausted.
    @transitions Transitions to `ResolveItemMeta` after this job marks the requested hand as locked; may self-transition back to `AcquireEquipLock` while waiting; transitions to `Failed` if the character disappears.
    @failure If the character no longer exists the job fails immediately. Stale-lock recovery does not fail; it force-clears the lock and continues.
    @reads `fsm.CharacterEntityId`, `fsm.Hand`, `fsm.Context._equipLockRetryCount`, characterEntity.`EquipLock`.
    @writes `fsm.Context._equipLockRetryCount`, `_equipLockHeld`, `fsm.WaitSpan`, characterEntity.`EquipLock`.
]=]
self:AddState("AcquireEquipLock", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity no longer exists")
				return
			end

			local hand = fsm.Hand :: string
			local equipLock = if typeof(charEntity.EquipLock) == "table" then table.clone(charEntity.EquipLock) else {}
			if equipLock[hand] then
				local retryCount = tonumber(fsm.Context._equipLockRetryCount) or 0
				if retryCount < 3 then
					fsm.Context._equipLockRetryCount = retryCount + 1
					fsm.WaitSpan = 0.2
					fsm.State = "AcquireEquipLock"
				else
					-- Force-clear stale lock after retries
					equipLock[hand] = nil
					charEntity.EquipLock = equipLock
					pcall(function() charEntity:UpdateEntity() end)
				end
				if equipLock[hand] then return end
			end

			fsm.Context._equipLockRetryCount = 0
			fsm.Context._equipLockHeld = true
			equipLock[hand] = true
			charEntity.EquipLock = equipLock
			pcall(function() charEntity:UpdateEntity() end)
			fsm.State = "ResolveItemMeta"
		end,
	}, { "ResolveItemMeta", "Rollback", "Failed" })

	--[=[
    @state ResolveItemMeta
    @description Clones the requested asset, tracks that clone for cleanup bookkeeping, requires item metadata, resolves a usable handle part, and caches all data needed for mount-time work.
    @transitions Transitions to `PreUnEquip` when the clone, data module, and handle are valid; otherwise queues `Rollback`.
    @failure `queueRollback(...)` records the failure reason when the item cannot be cloned, lacks a data module, or has no usable handle. The partially cloned item is explicitly destroyed before rollback when necessary.
    @reads `fsm.ItemId`, shared `EquipHelpers.CloneItem`, cloned item children and `PrimaryPart`.
    @writes `fsm.Context._clonedItem`, `_itemData`, `_handle`, and tracked instance bookkeeping via `fsm:TrackInstance(..., true)`.
]=]
self:AddState("ResolveItemMeta", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local item, itemData = equipHelpers.CloneItem(fsm.ItemId)
			if not item then
				StateTransitionHelpers.queueRollback(fsm, "Item not found in assets: " .. tostring(fsm.ItemId))
				return
			end
			fsm:TrackInstance(item, "WeaponClone:" .. tostring(fsm.ItemId), true)
			if not itemData then
				item:Destroy()
				StateTransitionHelpers.queueRollback(fsm, "Item has no Data module: " .. tostring(fsm.ItemId))
				return
			end

			local handle = item:FindFirstChild("Handle")
			if not handle or not handle:IsA("BasePart") then
				-- Fallback: use PrimaryPart or first BasePart child
				handle = item.PrimaryPart
				if not handle then
					for _, child in item:GetChildren() do
						if child:IsA("BasePart") then
							handle = child
							break
						end
					end
				end
			end
			if not handle or not handle:IsA("BasePart") then
				item:Destroy()
				StateTransitionHelpers.queueRollback(fsm, "Item has no Handle part: " .. tostring(fsm.ItemId))
				return
			end

			fsm.Context._clonedItem = item
			fsm.Context._itemData = itemData
			fsm.Context._handle = handle
			fsm.State = "PreUnEquip"
		end,
	}, { "PreUnEquip", "Rollback", "Failed" })

	--[=[
    @state PreUnEquip
    @description Resolves the current character model, destroys any existing hand-held clone on the target hand, records the previous item id for inventory restoration, and clears any lingering stowed duplicate of that previous item before the new asset is mounted.
    @transitions Transitions to `CloneAsset` when the target hand has been prepared; otherwise queues `Rollback`.
    @failure Queues rollback if the character entity disappears or the live character model is unavailable before the swap can proceed.
    @reads `fsm.CharacterEntityId`, `fsm.Hand`, current equipped property, existing hand welds, existing item parent model.
    @writes `fsm.Context._previousItemId`; destroys old welds, old mounted clones, and stowed duplicates through `EquipHelpers`.
]=]
self:AddState("PreUnEquip", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				StateTransitionHelpers.queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				StateTransitionHelpers.queueRollback(fsm, "Character model is unavailable")
				return
			end

			local hand = fsm.Hand :: string
			local currentProperty = getHandProperty(hand)
			local currentEquipped = charEntity[currentProperty]
			if type(currentEquipped) == "string" and currentEquipped ~= "" then
				local handPart = equipHelpers.GetHandPart(character, hand)
				if handPart then
					local weld = equipHelpers.FindHandleWeld(handPart)
					if weld and weld.Part1 then
						local existingItem = weld.Part1.Parent
						if existingItem then
							fsm.Context._previousItemId = currentEquipped
							-- Always destroy the old clone when swapping via inventory
							weld:Destroy()
							existingItem:Destroy()
						end
					end
				end
				-- Clear stowed duplicate if any
				equipHelpers.ClearStowedDuplicate(character, currentEquipped)
			end

			fsm.State = "CloneAsset"
		end,
	}, { "CloneAsset", "Rollback", "Failed" })

	--[=[
    @state CloneAsset
    @description Clears any stowed duplicate of the item being newly equipped so only one visual instance remains before the fresh clone is welded in-hand.
    @transitions Transitions to `CreateWeld` on success; otherwise queues `Rollback`.
    @failure Queues rollback if the character entity or live character model disappears before duplicate cleanup runs.
    @reads `fsm.CharacterEntityId`, `fsm.ItemId`, live character model.
    @writes Character descendants by removing stowed duplicates of the new item through `EquipHelpers.ClearStowedDuplicate(...)`.
]=]
self:AddState("CloneAsset", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				StateTransitionHelpers.queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				StateTransitionHelpers.queueRollback(fsm, "Character model is unavailable")
				return
			end

			equipHelpers.ClearStowedDuplicate(character, fsm.ItemId)
			fsm.State = "CreateWeld"
		end,
	}, { "CreateWeld", "Rollback", "Failed" })

	--[=[
    @state CreateWeld
    @description Finds the target hand part on the live character and creates the weld that binds the cloned item handle to that hand using the configured grip offset.
    @transitions Transitions to `MountItem` when the hand part and weld are created; otherwise queues `Rollback`.
    @failure Queues rollback if the character model disappears or the requested hand part cannot be found.
    @reads `fsm.CharacterEntityId`, `fsm.Hand`, `fsm.Context._handle`, `fsm.Context._itemData.GripC1`.
    @writes `fsm.Context._weld`, `fsm.Context._handPart`.
]=]
self:AddState("CreateWeld", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				StateTransitionHelpers.queueRollback(fsm, "CharacterEntity no longer exists")
				return
			end

			local character = charEntity.Instance
			if not character or not character:IsA("Model") then
				StateTransitionHelpers.queueRollback(fsm, "Character model is unavailable")
				return
			end

			local handPart = equipHelpers.GetHandPart(character, fsm.Hand)
			if not handPart then
				StateTransitionHelpers.queueRollback(fsm, "Hand part not found for hand: " .. tostring(fsm.Hand))
				return
			end

			local weld =
				equipHelpers.CreateWeld(handPart, fsm.Context._handle, fsm.Context._itemData.GripC1 or CFrame.new())
			fsm.Context._weld = weld
			fsm.Context._handPart = handPart
			fsm.State = "MountItem"
		end,
	}, { "MountItem", "Rollback", "Failed" })

	--[=[
    @state MountItem
    @description Parents the cloned item into the live character rig using the previously resolved hand part and weld context.
    @transitions Transitions to `CommitState` when mount succeeds; otherwise queues `Rollback`.
    @failure Queues rollback if any entity became unavailable or if `EquipHelpers.MountItem(...)` errors during parenting.
    @reads `fsm.Context._clonedItem`, `fsm.Context._handPart`, current live entities from `ensureEntitiesAlive(...)`.
    @writes Character model hierarchy by mounting the cloned item.
]=]
self:AddState("MountItem", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during MountItem")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local ok, err = pcall(function()
				equipHelpers.MountItem(fsm.Context._clonedItem, fsm.Context._handPart)
			end)
			if not ok then
				StateTransitionHelpers.queueRollback(fsm, "MountItem failed: " .. tostring(err))
				return
			end
			fsm.State = "CommitState"
		end,
	}, { "CommitState", "Rollback", "Failed" })

	--[=[
    @state CommitState
    @description Commits the equipped item id onto the character entity and player entity, updates right-hand `WeaponEqp` when applicable, returns any swapped-out item id to inventory, and removes the newly equipped item from inventory.
    @transitions Transitions to `EmitIntent` after state is committed; otherwise queues `Rollback`.
    @failure Queues rollback if the character, player, or live model disappears before replicated entity fields can be updated.
    @reads `fsm.Hand`, `fsm.ItemId`, `fsm.Context._previousItemId`, playerEntity.`Equipped`, `Inventory`, character equipped property.
    @writes Character equipped property (`EquippedRight` or `EquippedLeft`), playerEntity.`Equipped`, `WeaponEqp`, `Inventory`, and replicated entity updates.
]=]
self:AddState("CommitState", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during CommitState")
				return
			end

			local hand = fsm.Hand :: string
			local propertyName = getHandProperty(hand)
			charEntity[propertyName] = fsm.ItemId
			pcall(function() charEntity:UpdateEntity() end)

			local equipped = if typeof(playerEntity.Equipped) == "table" then table.clone(playerEntity.Equipped) else {}
			equipped[hand] = fsm.ItemId
			playerEntity.Equipped = equipped
			if hand == "Right" then
				playerEntity.WeaponEqp = fsm.ItemId
			end

			local inventory = if typeof(playerEntity.Inventory) == "table"
				then table.clone(playerEntity.Inventory)
				else {}

			-- Return previously equipped item to inventory
			local prevItemId = fsm.Context._previousItemId
			if typeof(prevItemId) == "string" and prevItemId ~= "" then
				if not table.find(inventory, prevItemId) then
					table.insert(inventory, prevItemId)
				end
			end

			-- Remove newly equipped item from inventory
			local newIdx = table.find(inventory, fsm.ItemId)
			if newIdx then
				table.remove(inventory, newIdx)
			end

			playerEntity.Inventory = inventory
			pcall(function() playerEntity:UpdateEntity() end)

			fsm.State = "EmitIntent"
		end,
	}, { "EmitIntent", "Rollback", "Failed" })

	--[=[
    @state EmitIntent
    @description Appends the `Equip` intent so clients can mirror the successful equip action after the authoritative entity state has been committed.
    @transitions Transitions to `ReleaseEquipLock` when the intent is appended; otherwise queues `Rollback`.
    @failure Queues rollback if the character, player, or live model disappears before intent emission.
    @reads `fsm.Hand`, `fsm.ItemId`, live entities from `ensureEntitiesAlive(...)`.
    @writes Character entity intent queue through `IntentSchema.AppendIntent(...)`.
]=]
self:AddState("EmitIntent", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during EmitIntent")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local intentSchema = getIntentSchema(orchestrator)
			intentSchema.AppendIntent(charEntity, {
				Kind = "Equip",
				Payload = {
					Hand = fsm.Hand,
					ItemId = fsm.ItemId,
				},
			})

			fsm.State = "ReleaseEquipLock"
		end,
	}, { "ReleaseEquipLock", "Rollback", "Failed" })

	--[=[
    @state ReleaseEquipLock
    @description Clears the per-hand equip lock if this job still owns it, then chooses `Completed` or `Failed` based on whether rollback stored `_failureReason`.
    @transitions Transitions to `Completed` when no failure reason exists, otherwise transitions to `Failed`.
    @failure Even after rollback, this state still releases the lock and logs `_failureReason` before entering `Failed`.
    @reads `fsm.CharacterEntityId`, `fsm.Hand`, `fsm.Context._equipLockHeld`, `fsm.Context._failureReason`, characterEntity.`EquipLock`.
    @writes Character entity.`EquipLock`, `fsm.Context._equipLockHeld`; emits an error log when `_failureReason` is present.
]=]
self:AddState("ReleaseEquipLock", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if charEntity and fsm.Context._equipLockHeld then
				local equipLock = if typeof(charEntity.EquipLock) == "table"
					then table.clone(charEntity.EquipLock)
					else {}
				equipLock[fsm.Hand] = nil
				charEntity.EquipLock = equipLock
				charEntity:UpdateEntity()
				fsm.Context._equipLockHeld = false
			end

			if fsm.Context._failureReason then
				fsm:Log({ Level = "ERROR", Message = tostring(fsm.Context._failureReason) })
				fsm.State = "Failed"
			else
				fsm.State = "Completed"
			end
		end,
	}, { "Completed", "Failed" })

	--[=[
    @state Rollback
    @description Destroys the newly cloned item if it still exists and, when a previous item snapshot was captured, attempts to recreate its weld and remount it before handing control to lock release.
    @transitions Always transitions to `ReleaseEquipLock`.
    @failure Rollback is best-effort. If no `_previousItem` snapshot exists, cleanup only destroys the new clone. If remounting the previous item fails, the job logs a warning but still proceeds to lock release and then `Failed`.
    @reads `fsm.Context._clonedItem`, `_previousItem`, `_previousItemData`, `_previousItemAction`, `_previousItemId`, `fsm.Hand`, live entities from `ensureEntitiesAlive(...)`.
    @writes Destroys `_clonedItem`; may recreate a weld and remount `_previousItem`; leaves `_failureReason` intact for `ReleaseEquipLock`.
]=]
self:AddState("Rollback", {
		OnEnter = function(_, fsm)
			local clonedItem = fsm.Context._clonedItem
			if clonedItem and clonedItem.Parent then
				clonedItem:Destroy()
			end

			local previousItem = fsm.Context._previousItem
			if previousItem then
				local action = tostring(fsm.Context._previousItemAction or "unknown action")
				--[=[
				    @description Emits a rollback warning through the FSM logger when available, otherwise falls back to `warn`.
				    @param message string -- Warning message describing the rollback restoration issue.
				    @return nil -- Produces a logging side effect only.
				]=]
				local function logRollbackWarning(message: string)
					if type(fsm.Log) == "function" then
						fsm:Log({ Level = "WARN", Message = message })
					else
						warn(message)
					end
				end

				local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
				if charEntity and playerEntity and character and previousItem.Parent then
					local orchestrator = fsm:GetOrchestrator()
					local equipHelpers = getEquipHelpers(orchestrator)
					local handPart = equipHelpers.GetHandPart(character, fsm.Hand)
					local previousData = fsm.Context._previousItemData or equipHelpers.GetItemData(previousItem)
					local handle = previousItem:FindFirstChild("Handle")
					if not handle or not handle:IsA("BasePart") then
						handle = previousItem.PrimaryPart
						if not handle then
							for _, child in previousItem:GetChildren() do
								if child:IsA("BasePart") then
									handle = child
									break
								end
							end
						end
					end

					if handPart and handle and handle:IsA("BasePart") then
						local ok, err = pcall(function()
							equipHelpers.CreateWeld(handPart, handle, if previousData then previousData.GripC1 or CFrame.new() else CFrame.new())
							equipHelpers.MountItem(previousItem, handPart)
						end)
						if not ok then
							logRollbackWarning(
								string.format(
									"Equip rollback could not restore previous item '%s' after %s: %s",
									tostring(fsm.Context._previousItemId or previousItem.Name),
									action,
									tostring(err)
								)
							)
						end
					else
						logRollbackWarning(
							string.format(
								"Equip rollback could not restore previous item '%s' after %s: missing hand part or handle",
								tostring(fsm.Context._previousItemId or previousItem.Name),
								action
							)
						)
					end
				else
					logRollbackWarning(
						string.format(
							"Equip rollback may have lost previous item '%s' after %s",
							tostring(fsm.Context._previousItemId or previousItem.Name),
							action
						)
					)
				end
			end

			fsm.State = "ReleaseEquipLock"
		end,
	}, { "ReleaseEquipLock" })

	--[=[
    @state Completed
    @description Terminal success state for the equip pipeline. No additional work runs here.
    @transitions No outbound transitions; the job stops here.
    @failure No rollback remains because the clone, entity state, and lock release have already completed successfully.
    @reads No additional fields are read.
    @writes No additional fields are written.
]=]
self:AddState("Completed", function(_fsm) end, {})
	--[=[
    @state Failed
    @description Terminal failure state reached after rollback and lock release finish.
    @transitions No outbound transitions; the job stops here.
    @failure Any cleanup that could be performed has already happened in `Rollback` and `ReleaseEquipLock`; remaining issues are surfaced through the stored `_failureReason` log.
    @reads Previously stored `fsm.Context._failureReason` and related rollback context.
    @writes No additional fields are written by the state itself.
]=]
self:AddState("Failed", function(_fsm) end, {})
end

return EquipJob
