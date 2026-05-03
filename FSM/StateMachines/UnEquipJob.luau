--!strict
--[=[
    @Name UnEquipJob
    @Author iKrypto
    @Description Unequips the current item from a requested hand by validating the request, serializing access with the per-hand equip lock, resolving the currently mounted asset, either dropping or stowing that asset, committing replicated entity and inventory state, emitting the unequip intent, and releasing the lock. Failures route through `Rollback`, which currently performs no physical restoration beyond ensuring the lock is released before the terminal `Failed` state. Historical integrations must target `Completed`; the deprecated `Complete` spelling is intentionally not used.

    State flow diagram:
    ValidateRequest → AcquireEquipLock → ResolveExistingItem → DoUnEquip → CommitState → EmitIntent → ReleaseEquipLock → Completed
                    ↘ Rollback → ReleaseEquipLock → Failed

    Context fields:
    - Hand: string -- normalized hand name (`Right` or `Left`).
    - _equipLockRetryCount: number -- retry counter while waiting for the per-hand equip lock.
    - _equipLockHeld: boolean -- whether this job currently owns the per-hand equip lock.
    - _resolvedHandPart: BasePart? -- hand part resolved from the live character.
    - _resolvedWeld: WeldConstraint? -- weld binding the currently mounted item to the hand.
    - _resolvedItem: Instance? -- currently mounted item model, if one exists.
    - _resolvedItemData: any? -- resolved metadata for the mounted item.
    - _resolvedItemId: string -- best-effort item id inferred from entity state or the mounted model name.
    - _wasStowed: boolean -- set only when `DoUnEquip` stows a stowable item instead of dropping it. `CommitState` uses this flag to keep equipped fields and `WeaponEqp` intact so the item remains logically equipped while visually moved to a stowed position.
    - _failureReason: string? -- reason recorded by rollback helpers and logged during lock release.

    Required params:
    - CharacterEntityId: string -- character entity whose hand will be processed.
    - PlayerEntityId: string? -- optional player entity id; falls back to the character link when omitted.
    - Hand: string? -- optional hand override; defaults to `Right`.
    - ForceRemove: boolean? -- when true, always drops/destroys the physical item instead of stowing it.

    Notes:
    - Unlike `EquipJob`, this FSM does not use tracked clone bookkeeping; it works against the already-mounted item resolved from the live character.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Helpers = ReplicatedStorage:FindFirstChild("Helpers") or script.Parent.Parent:FindFirstChild("Helpers")
assert(Helpers, "Helpers folder not found")
local ModuleLoader = require(Helpers:WaitForChild("ModuleLoader"))
local StateTransitionHelpers = require(Helpers:WaitForChild("StateTransitionHelpers"))

local UnEquipJob = {
	Name = "UnEquipJob",
	className = "UnEquipJob",
	validStates = {
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
    @description Lazily resolves and caches the shared `IntentSchema` module used to append unequip intents.
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
    @param fsm any -- Active unequip FSM instance.
    @return any? -- Current character entity.
    @return any? -- Current player entity.
    @return any? -- Live character model.
]=]
local function ensureEntitiesAlive(fsm): (any?, any?, any?)
	local orchestrator = fsm:GetOrchestrator()
	local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
	if not charEntity then
		return nil, nil, nil
	end

	local playerEntityId = fsm.PlayerEntityId
	if type(playerEntityId) ~= "string" or playerEntityId == "" then
		playerEntityId = charEntity.PlayerEntityId
	end
	local playerEntity = if type(playerEntityId) == "string" and playerEntityId ~= ""
		then orchestrator.GetEntity(playerEntityId)
		else nil
	if not playerEntity then
		return nil, nil, nil
	end

	local character = charEntity.Instance
	if not character or not character.Parent then
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
    @description Registers every UnEquipJob state, rollback edge, and terminal no-op with the FSM base class.
    @return nil -- Mutates the module definition by adding states.
]=]
function UnEquipJob:RegisterStates()
	--[=[
    @state ValidateRequest
    @description Validates the character entity, normalizes the requested hand, and seeds request context for the rest of the unequip pipeline.
    @transitions Transitions to `AcquireEquipLock` when the request is well-formed; otherwise transitions to `Failed`.
    @failure Fails immediately when the character entity cannot be found or the requested hand is neither `Right` nor `Left`.
    @reads `fsm.CharacterEntityId`, `fsm.Hand`.
    @writes `fsm.Context.Hand`.
]=]
self:AddState("ValidateRequest", {
		OnEnter = function(_, fsm)
			local orchestrator = fsm:GetOrchestrator()
			local charEntity = orchestrator.GetEntity(fsm.CharacterEntityId)
			if not charEntity then
				fsm:Fail("CharacterEntity not found")
				return
			end

			local hand = fsm.Hand or "Right"
			if hand ~= "Right" and hand ~= "Left" then
				fsm:Fail("Invalid hand: " .. tostring(hand))
				return
			end

			fsm.Context.Hand = hand
			fsm.State = "AcquireEquipLock"
		end,
	}, { "AcquireEquipLock", "Failed" })

	--[=[
    @state AcquireEquipLock
    @description Serializes unequips per hand by cloning the character `EquipLock` table and retrying for a short period while another job owns the requested hand.
    @transitions Transitions to `ResolveExistingItem` after this job marks the hand as locked; may self-transition back to `AcquireEquipLock` while waiting; transitions to `Failed` if the character disappears or the retry budget is exhausted.
    @failure Fails when the character no longer exists or when the lock remains occupied after five retries.
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
				if retryCount < 5 then
					fsm.Context._equipLockRetryCount = retryCount + 1
					fsm.WaitSpan = 0.3
					fsm.State = "AcquireEquipLock"
				else
					fsm:Fail("Timed out waiting for EquipLock for hand: " .. hand)
				end
				return
			end

			fsm.Context._equipLockRetryCount = 0
			fsm.Context._equipLockHeld = true
			equipLock[hand] = true
			charEntity.EquipLock = equipLock
			charEntity:UpdateEntity()
			fsm.State = "ResolveExistingItem"
		end,
	}, { "ResolveExistingItem", "Rollback", "Failed" })

	--[=[
    @state ResolveExistingItem
    @description Resolves the live hand part, current handle weld, mounted item model, optional item metadata, and best-effort item id so later states can decide whether to stow, drop, or just clean up entity state.
    @transitions Transitions to `DoUnEquip` when live entities and the hand part are available; otherwise queues `Rollback`.
    @failure Queues rollback if the entities disappear or the hand part cannot be resolved from the live character.
    @reads `fsm.Hand`, live entities from `ensureEntitiesAlive(...)`, current equipped property, hand weld and mounted model.
    @writes `fsm.Context._resolvedHandPart`, `_resolvedWeld`, `_resolvedItem`, `_resolvedItemData`, `_resolvedItemId`.
]=]
self:AddState("ResolveExistingItem", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during ResolveExistingItem")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local hand = fsm.Hand :: string
			local handPart = equipHelpers.GetHandPart(character, hand)
			if not handPart then
				StateTransitionHelpers.queueRollback(fsm, "Hand part not found for hand: " .. hand)
				return
			end

			local weld = equipHelpers.FindHandleWeld(handPart)
			local item = if weld and weld.Part1 then weld.Part1.Parent else nil
			local itemData = if item then equipHelpers.GetItemData(item) else nil
			local currentItemId = charEntity[getHandProperty(hand)]
			if (type(currentItemId) ~= "string" or currentItemId == "") and item then
				currentItemId = item.Name
			end

			fsm.Context._resolvedHandPart = handPart
			fsm.Context._resolvedWeld = weld
			fsm.Context._resolvedItem = item
			fsm.Context._resolvedItemData = itemData
			fsm.Context._resolvedItemId = currentItemId or ""
			fsm.State = "DoUnEquip"
		end,
	}, { "DoUnEquip", "Rollback", "Failed" })

	--[=[
    @state DoUnEquip
    @description Performs the physical unequip action by either dropping the mounted item when forced or non-stowable, or stowing it onto the character and marking `_wasStowed` so logical equipped state can remain intact.
    @transitions Transitions to `CommitState` after the physical action or warning path runs; otherwise queues `Rollback` when live entities vanish first.
    @failure Queues rollback if live entities disappear before the physical action. Missing weld or item does not fail; the state logs a warning and still advances so logical state can be cleaned up.
    @reads `fsm.Context._resolvedWeld`, `_resolvedItem`, `_resolvedItemData`, `fsm.Context.ForceRemove`, live entities from `ensureEntitiesAlive(...)`.
    @writes Physical item placement through `DropItem(...)` or `StowItem(...)`; `fsm.Context._wasStowed` when a stow operation succeeds.
]=]
self:AddState("DoUnEquip", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during DoUnEquip")
				return
			end

			local orchestrator = fsm:GetOrchestrator()
			local equipHelpers = getEquipHelpers(orchestrator)
			local weld = fsm.Context._resolvedWeld
			local item = fsm.Context._resolvedItem
			local itemData = fsm.Context._resolvedItemData
			if not weld or not item then
				local message = string.format(
					"UnEquipJob proceeding without physical item for hand %s (weld=%s, item=%s)",
					tostring(fsm.Hand),
					tostring(weld ~= nil),
					tostring(item ~= nil)
				)
				if type(fsm.Log) == "function" then
					fsm:Log({ Level = "WARN", Message = message })
				else
					warn(message)
				end
			else
				-- ForceRemove: always destroy (e.g. explicit unequip from inventory)
				-- Otherwise: stow if possible, else drop
				if fsm.Context.ForceRemove or not (itemData and itemData.Stowable) then
					equipHelpers.DropItem(item, weld)
				else
					equipHelpers.StowItem(item, character, weld, itemData)
					fsm.Context._wasStowed = true
				end
			end

			fsm.State = "CommitState"
		end,
	}, { "CommitState", "Rollback", "Failed" })

	--[=[
    @state CommitState
    @description Commits replicated character and player state based on whether the physical item was stowed. Stowed items remain logically equipped, while dropped items clear equipped fields and are returned to inventory when an item id is known.
    @transitions Transitions to `EmitIntent` after entity updates are pushed; otherwise queues `Rollback`.
    @failure Queues rollback if the character, player, or live model disappears before state commit. There is no restoration inside rollback, so previously written physical changes remain if failure occurs after `DoUnEquip`.
    @reads `fsm.Hand`, `fsm.Context._wasStowed`, `_resolvedItemId`, live entities from `ensureEntitiesAlive(...)`, playerEntity.`Equipped`, `Inventory`, `WeaponEqp`.
    @writes When `_wasStowed` is true, only replication updates are pushed. Otherwise character equipped property, playerEntity.`Equipped`, possible inventory insertion, and player entity replication are updated.
]=]
self:AddState("CommitState", {
		OnEnter = function(_, fsm)
			local charEntity, playerEntity, character = ensureEntitiesAlive(fsm)
			if not charEntity or not playerEntity or not character then
				StateTransitionHelpers.queueRollback(fsm, "Entities no longer alive during CommitState")
				return
			end

			local hand = fsm.Hand :: string

			-- When stowed, the weapon is still equipped (just on the character's back).
			-- Only clear equipped state and return to inventory for non-stow unequips.
			if fsm.Context._wasStowed then
				-- Keep EquippedRight/Left, Equipped table, and WeaponEqp intact.
				-- The item stays "equipped" but visually stowed.
				charEntity:UpdateEntity()
				playerEntity:UpdateEntity()
			else
				charEntity[getHandProperty(hand)] = ""
				charEntity:UpdateEntity()

				local equipped = if typeof(playerEntity.Equipped) == "table"
					then table.clone(playerEntity.Equipped)
					else {}
				equipped[hand] = nil
				playerEntity.Equipped = equipped
				if hand == "Right" and not fsm.Context._resolvedItemId then
					playerEntity.WeaponEqp = ""
				end
				-- Return item to inventory
				local inventory = playerEntity.Inventory
				if typeof(inventory) == "table" and fsm.Context._resolvedItemId and fsm.Context._resolvedItemId ~= "" then
					if not table.find(inventory, fsm.Context._resolvedItemId) then
						inventory = table.clone(inventory)
						table.insert(inventory, fsm.Context._resolvedItemId)
						playerEntity.Inventory = inventory
					end
				end
				playerEntity:UpdateEntity()
			end

			fsm.State = "EmitIntent"
		end,
	}, { "EmitIntent", "Rollback", "Failed" })

	--[=[
    @state EmitIntent
    @description Appends the `UnEquip` intent so clients can mirror the authoritative unequip action after entity state has been committed.
    @transitions Transitions to `ReleaseEquipLock` when the intent is appended; otherwise queues `Rollback`.
    @failure Queues rollback if the character, player, or live model disappears before intent emission.
    @reads `fsm.Hand`, `fsm.Context._resolvedItemId`, live entities from `ensureEntitiesAlive(...)`.
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
				Kind = "UnEquip",
				Payload = {
					Hand = fsm.Hand,
					ItemId = fsm.Context._resolvedItemId,
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
    @description Minimal rollback state that currently performs no physical restoration and simply advances to lock release.
    @transitions Always transitions to `ReleaseEquipLock`.
    @failure Cleanup is limited to lock release; any prior drop or stow action is not undone here.
    @reads Stored `_failureReason` and lock-ownership context from earlier states.
    @writes No additional fields are written beyond the subsequent state transition.
]=]
self:AddState("Rollback", {
		OnEnter = function(_, fsm)
			fsm.State = "ReleaseEquipLock"
		end,
	}, { "ReleaseEquipLock" })

	--[=[
    @state Completed
    @description Terminal success state for the unequip pipeline. No additional work runs here.
    @transitions No outbound transitions; the job stops here.
    @failure All required entity updates, optional stow handling, and lock release have already completed successfully.
    @reads No additional fields are read.
    @writes No additional fields are written.
]=]
self:AddState("Completed", function(_fsm) end, {})
	--[=[
    @state Failed
    @description Terminal failure state reached after rollback and lock release finish.
    @transitions No outbound transitions; the job stops here.
    @failure The rollback path only guarantees lock release, so physical stow/drop effects from earlier states may already be visible when the job fails.
    @reads Previously stored `fsm.Context._failureReason` and related rollback context.
    @writes No additional fields are written by the state itself.
]=]
self:AddState("Failed", function(_fsm) end, {})
end

return UnEquipJob
