--!strict
-- @Name ServiceManager/Tests/Specs/FSMJobs.spec.luau
-- @Author iKrypto
-- @Description Behavior specs for FSM job state transitions, rollback paths, and edge cases.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

local sharedFolder = ReplicatedStorage:WaitForChild("shared")
local SharedEquipHelpers = require(sharedFolder:WaitForChild("EquipHelpers"))

local IntentRecords = {}
local AppliedEffects = {}
local SpecItemCatalog: { [string]: { Template: Model, Data: any } } = {}
local handWelds: { [Instance]: any } = {}

local SharedIntentSchema = {
	AppendIntent = function(charEntity: any, intent: any)
		local intents = if type(charEntity.GetContext) == "function" then charEntity:GetContext("_RecordedIntents") else nil
		if typeof(intents) ~= "table" then
			intents = {}
		end
		table.insert(intents, intent)
		if type(charEntity.SetContext) == "function" then
			charEntity:SetContext("_RecordedIntents", intents)
		else
			charEntity._RecordedIntents = intents
		end
		table.insert(IntentRecords, { EntityId = charEntity.EntityId, Intent = intent })
	end,
}

local SharedDamageCalculator = {
	Compute = function(baseDamage: number, isBlocking: boolean)
		return if isBlocking then baseDamage * 0.5 else baseDamage
	end,
	GetWeaponBaseDamage = function(itemData: any)
		return tonumber(itemData and itemData.WeaponStats and itemData.WeaponStats.Attack) or 10
	end,
}

local SharedStatusEffectDefs = {
	Get = function(_effectId: string)
		return nil
	end,
}

local SharedTalentTreeDefs = {
	GetMergedPassiveEffects = function(_playerEntity: any)
		return {}
	end,
}

local SharedStatusEffectHelper = {
	Apply = function(_orchestrator: any, targetEntityId: string, effectId: string)
		table.insert(AppliedEffects, { TargetEntityId = targetEntityId, EffectId = effectId })
	end,
}

local SharedAbilityDefs = {
	GetAbility = function(_abilityId: string)
		return nil
	end,
	GetConsumable = function(_itemId: string)
		return nil
	end,
}

local SharedAllowLists = {
	AllowAllAnimations = true,
	ValidAnimationNames = {
		Blocking = true,
		Slash = true,
		HitReact = true,
	},
	ValidEffectNames = {
		BlockSpark = true,
	},
	ValidSoundIds = {
		["1248511833"] = true,
	},
	IsValidClientIntent = function(kind: string)
		return kind == "Animation" or kind == "Effect" or kind == "Sound"
	end,
	IsServerOnlyIntent = function(_kind: string)
		return false
	end,
}

local SpecEquipHelpers = {
	CloneItem = function(itemId: string)
		local entry = SpecItemCatalog[itemId]
		if not entry then
			return nil, nil
		end
		return entry.Template:Clone(), table.clone(entry.Data)
	end,
	GetItemData = function(item: Instance)
		local entry = SpecItemCatalog[item.Name]
		return if entry then table.clone(entry.Data) else nil
	end,
	GetHandPart = function(character: Model, hand: string)
		return character:FindFirstChild(hand .. "Hand") or character:FindFirstChild("HumanoidRootPart")
	end,
	FindHandleWeld = function(handPart: Instance)
		return handWelds[handPart]
	end,
	CreateWeld = function(handPart: Instance, handle: BasePart, grip: CFrame)
		local weld = {
			Part0 = handPart,
			Part1 = handle,
			C1 = grip,
			Destroyed = false,
		}
		function weld:Destroy()
			self.Destroyed = true
			handWelds[handPart] = nil
		end
		handWelds[handPart] = weld
		return weld
	end,
	MountItem = function(item: Instance, handPart: Instance)
		item.Parent = handPart.Parent
	end,
	ClearStowedDuplicate = function(character: Model, itemId: string)
		for _, child in ipairs(character:GetChildren()) do
			if child.Name == itemId and child:GetAttribute("Stowed") == true then
				child:Destroy()
			end
		end
	end,
	DropItem = function(item: Instance, weld: any)
		if weld and weld.Destroy then
			weld:Destroy()
		end
		item:Destroy()
	end,
	StowItem = function(item: Instance, character: Model, weld: any)
		if weld and weld.Destroy then
			weld:Destroy()
		end
		item.Parent = character
		item:SetAttribute("Stowed", true)
	end,
	ResolveDataModule = function(_item: Instance)
		return nil
	end,
	Reset = function()
		table.clear(handWelds)
	end,
}

local function resetSharedState()
	table.clear(IntentRecords)
	table.clear(AppliedEffects)
	SpecEquipHelpers.Reset()
end

local function ensureSpecItem(itemId: string, data: any?)
	local entry = SpecItemCatalog[itemId]
	if not entry then
		local model = Instance.new("Model")
		model.Name = itemId

		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 1, 3)
		handle.Parent = model
		model.PrimaryPart = handle

		entry = {
			Template = model,
			Data = {
				GripC1 = CFrame.new(),
				Stowable = true,
			},
		}
		SpecItemCatalog[itemId] = entry
	end
	if typeof(data) == "table" then
		entry.Data = table.clone(data)
	end
	return entry
end

local function registerSpecModules(env: any)
	env:RegisterModule("IntentSchema", SharedIntentSchema)
	env:RegisterModule("DamageCalculator", SharedDamageCalculator)
	env:RegisterModule("StatusEffectDefs", SharedStatusEffectDefs)
	env:RegisterModule("TalentTreeDefs", SharedTalentTreeDefs)
	env:RegisterModule("StatusEffectHelper", SharedStatusEffectHelper)
	env:RegisterModule("AbilityDefs", SharedAbilityDefs)
	env:RegisterModule("EquipHelpers", SpecEquipHelpers)
	env:RegisterModule("AllowLists", SharedAllowLists)
end

local function captureStates(machineDef: any): { [string]: any }
	local captured = {}
	local proxy: any = setmetatable({}, {
		__index = machineDef,
	})

	function proxy:AddState(name: string, definition: any, transitions: { string }?)
		captured[name] = {
			Definition = if type(definition) == "function" then { OnEnter = definition } else definition,
			Transitions = transitions or {},
		}
	end

	(machineDef.RegisterStates :: any)(proxy)
	return captured
end

local function expectSequenceContainsInOrder(expectFn: any, sequence: { string }, expected: { string })
	local cursor = 1
	for _, value in ipairs(sequence) do
		if value == expected[cursor] then
			cursor += 1
			if cursor > #expected then
				break
			end
		end
	end
	expectFn(cursor).toBe(#expected + 1)
end

local function createEquipActors(env: any, options: any?)
	options = options or {}
	local character, _, _, rightHand, leftHand = Helpers.makeCharacterRig(env, options.CharacterName or "FSMJobsCharacter")
	local charEntity = Helpers.createCharacterEntity(env, options.CharacterEntityId or "Char_1", {
		Instance = character,
		PlayerEntityId = options.PlayerEntityId or "Player_1",
		EquippedRight = options.EquippedRight or "",
		EquippedLeft = options.EquippedLeft or "",
		UserId = options.UserId or 101,
	})
	local playerEntity = Helpers.createPlayerEntity(env, options.PlayerEntityId or "Player_1", {
		Inventory = options.Inventory or {},
		BagContents = options.BagContents or {},
		Equipped = options.Equipped or {},
		WeaponEqp = options.WeaponEqp or "",
	})
	return character, charEntity, playerEntity, rightHand, leftHand
end

local function mountEquippedItem(env: any, character: Model, handPart: BasePart, itemId: string)
	local template = ensureSpecItem(itemId).Template
	local clone = template:Clone()
	env:DestroyLater(clone)
	clone.Parent = character
	SpecEquipHelpers.CreateWeld(handPart, clone:FindFirstChild("Handle") :: BasePart, CFrame.new())
	return clone
end

local function makeStateFsm(env: any, overrides: any?): any
	overrides = overrides or {}
	local fsm: any = {
		Id = overrides.Id or "FSMJobs_State",
		State = overrides.State,
		Hand = overrides.Hand,
		CharacterEntityId = overrides.CharacterEntityId,
		PlayerEntityId = overrides.PlayerEntityId,
		ItemId = overrides.ItemId,
		Context = if typeof(overrides.Context) == "table" then overrides.Context else {},
		Logs = {},
	}
	for key, value in pairs(overrides) do
		if key ~= "Context" then
			fsm[key] = value
		end
	end
	function fsm:GetOrchestrator()
		return env.Orchestrator
	end
	function fsm:GetEntity(entityId: string)
		return env.Orchestrator.GetEntity(entityId)
	end
	function fsm:Fail(reason: string)
		self.Failure = reason
		self.State = "Failed"
	end
	function fsm:Log(entry: any)
		table.insert(self.Logs, entry)
	end
	return fsm
end

local function clearDamageAnchors()
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name == "DamageTextAnchor" then
			child:Destroy()
		end
	end
end

local comboWeaponId: string? = nil
local function findComboWeaponId(): string
	if comboWeaponId then
		return comboWeaponId
	end
	local assets = ReplicatedStorage:WaitForChild("Assets")
	for _, child in ipairs(assets:GetChildren()) do
		local dataModule = SharedEquipHelpers.ResolveDataModule(child)
		if dataModule then
			local ok, data = pcall(require, dataModule)
			if ok and typeof(data) == "table" and typeof(data.Animations) == "table" then
				local combos = data.Animations.Combos
				if typeof(combos) == "table" and next(combos) ~= nil then
					comboWeaponId = child.Name
					return child.Name
				end
			end
		end
	end
	error("No combo-capable weapon asset found under ReplicatedStorage.Assets")
end

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local EquipJob = Helpers.getStateMachine("EquipJob")
	local UnEquipJob = Helpers.getStateMachine("UnEquipJob")
	local AttackJob = Helpers.getStateMachine("AttackJob")
	local DamageJob = Helpers.getStateMachine("DamageJob")
	local BlockJob = Helpers.getStateMachine("BlockJob")
	local ReplicateIntentJob = Helpers.getStateMachine("ReplicateIntentJob")

	describe("EquipJob", function()
		it("completes the full happy path through every equip state", function()
			resetSharedState()
			ensureSpecItem("Sword")
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character, charEntity, playerEntity = createEquipActors(env, {
				Inventory = { "Sword" },
			})

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_HappyPath",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Sword",
				Hand = "Right",
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			expect(charEntity.EquippedRight).toEqual("Sword")
			expect(playerEntity.Equipped.Right).toEqual("Sword")
			expect(playerEntity.WeaponEqp).toEqual("Sword")
			expect(playerEntity.Inventory).toHaveLength(0)
			expect(charEntity.EquipLock.Right).toBeNil()
			expect(IntentRecords).toHaveLength(1)
			expect(IntentRecords[1].Intent.Kind).toEqual("Equip")
			expect(IntentRecords[1].Intent.Payload.ItemId).toEqual("Sword")

			local equippedClone = character:FindFirstChild("Sword")
			expect(equippedClone).never.toBeNil()

			local sequence = Helpers.getTransitionSequence(env, machine)
			expectSequenceContainsInOrder(expect, sequence, {
				"AcquireEquipLock",
				"ResolveItemMeta",
				"PreUnEquip",
				"CloneAsset",
				"CreateWeld",
				"MountItem",
				"CommitState",
				"EmitIntent",
				"ReleaseEquipLock",
				"Completed",
			})

			env:Cleanup()
		end)

		it("fails validation when the item is not in inventory", function()
			resetSharedState()
			ensureSpecItem("Sword")
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local _, charEntity, playerEntity = createEquipActors(env, {
				Inventory = { "Shield" },
			})

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_MissingInventory",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Sword",
				Hand = "Right",
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("not in inventory")
			expect(IntentRecords).toHaveLength(0)

			env:Cleanup()
		end)

		it("retries a held equip lock three times before force-clearing it", function()
			resetSharedState()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local states = captureStates(EquipJob)
			local _, charEntity = createEquipActors(env, {
				Inventory = { "Sword" },
			})
			charEntity.EquipLock = { Right = true }
			charEntity:UpdateEntity()

			local fsm = makeStateFsm(env, {
				CharacterEntityId = charEntity.EntityId,
				Hand = "Right",
				Context = {},
			})

			for retry = 1, 3 do
				states.AcquireEquipLock.Definition.OnEnter(nil, fsm)
				expect(fsm.State).toEqual("AcquireEquipLock")
				expect(fsm.WaitSpan).toEqual(0.2)
				expect(fsm.Context._equipLockRetryCount).toEqual(retry)
			end

			states.AcquireEquipLock.Definition.OnEnter(nil, fsm)
			expect(fsm.State).toEqual("ResolveItemMeta")
			expect(fsm.Context._equipLockHeld).toBeTruthy()
			expect(charEntity.EquipLock.Right).toBeTruthy()

			env:Cleanup()
		end)

		it("swaps an equipped weapon by destroying the old clone and returning it to inventory", function()
			resetSharedState()
			ensureSpecItem("OldSword")
			ensureSpecItem("NewSword")
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character, charEntity, playerEntity, rightHand = createEquipActors(env, {
				Inventory = { "NewSword" },
				EquippedRight = "OldSword",
				Equipped = { Right = "OldSword" },
				WeaponEqp = "OldSword",
			})
			local oldClone = mountEquippedItem(env, character, rightHand, "OldSword")

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_Swap",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "NewSword",
				Hand = "Right",
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			expect(oldClone.Parent).toBeNil()
			expect(playerEntity.Inventory).toContain("OldSword")
			expect(playerEntity.Inventory).never.toContain("NewSword")
			expect(charEntity.EquippedRight).toEqual("NewSword")

			env:Cleanup()
		end)

		it("fails gracefully and rolls back when the character instance is missing", function()
			resetSharedState()
			ensureSpecItem("Sword")
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local _, charEntity, playerEntity = createEquipActors(env, {
				Inventory = { "Sword" },
			})
			charEntity.Instance = nil
			charEntity:UpdateEntity()

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_NoCharacter",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Sword",
				Hand = "Right",
			})

			expect(Helpers.stepUntil(env, machine, "Failed", 30)).toBeTruthy()
			expect(machine.Context._failureReason).toContain("Character model is unavailable")
			expect(charEntity.EquipLock.Right).toBeNil()

			local sequence = Helpers.getTransitionSequence(env, machine)
			expectSequenceContainsInOrder(expect, sequence, {
				"AcquireEquipLock",
				"ResolveItemMeta",
				"PreUnEquip",
				"Rollback",
				"ReleaseEquipLock",
				"Failed",
			})

			env:Cleanup()
		end)

		it("uses TrackInstance in track-only mode so the equipped clone survives FSM teardown", function()
			resetSharedState()
			ensureSpecItem("Sword")
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character, charEntity, playerEntity = createEquipActors(env, {
				Inventory = { "Sword" },
			})

			local machine = env.Mock:CreateFSM(EquipJob, {
				StateMachineId = "Equip_TrackOnly",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ItemId = "Sword",
				Hand = "Right",
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			local equippedClone = character:FindFirstChild("Sword")
			expect(equippedClone).never.toBeNil()

			machine:Destroy()
			expect(equippedClone.Parent).toBe(character)

			env:Cleanup()
		end)
	end)

	describe("UnEquipJob", function()
		it("force-removes an equipped item, destroys the instance, and returns it to inventory", function()
			resetSharedState()
			ensureSpecItem("Sword")
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character, charEntity, playerEntity, rightHand = createEquipActors(env, {
				EquippedRight = "Sword",
				Equipped = { Right = "Sword" },
				WeaponEqp = "Sword",
			})
			local sword = mountEquippedItem(env, character, rightHand, "Sword")

			local machine = env.Mock:CreateFSM(UnEquipJob, {
				StateMachineId = "UnEquip_ForceRemove",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				Hand = "Right",
				ForceRemove = true,
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			expect(sword.Parent).toBeNil()
			expect(playerEntity.Inventory).toContain("Sword")
			expect(charEntity.EquippedRight).toEqual("")

			env:Cleanup()
		end)

		it("stows the item for a toggle-style unequip and keeps it logically equipped", function()
			resetSharedState()
			ensureSpecItem("Sword", {
				GripC1 = CFrame.new(),
				Stowable = true,
			})
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character, charEntity, playerEntity, rightHand = createEquipActors(env, {
				EquippedRight = "Sword",
				Equipped = { Right = "Sword" },
				WeaponEqp = "Sword",
			})
			local sword = mountEquippedItem(env, character, rightHand, "Sword")

			local machine = env.Mock:CreateFSM(UnEquipJob, {
				StateMachineId = "UnEquip_Stow",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				Hand = "Right",
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			expect(sword:GetAttribute("Stowed")).toBeTruthy()
			expect(charEntity.EquippedRight).toEqual("Sword")
			expect(playerEntity.Equipped.Right).toEqual("Sword")
			expect(playerEntity.WeaponEqp).toEqual("Sword")
			expect(playerEntity.Inventory).never.toContain("Sword")

			env:Cleanup()
		end)

		it("honors the _wasStowed flag by skipping inventory return during commit", function()
			resetSharedState()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local states = captureStates(UnEquipJob)
			local _, charEntity, playerEntity = createEquipActors(env, {
				EquippedRight = "Sword",
				Equipped = { Right = "Sword" },
				WeaponEqp = "Sword",
			})

			local fsm = makeStateFsm(env, {
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				Hand = "Right",
				Context = {
					_wasStowed = true,
					_resolvedItemId = "Sword",
				},
			})

			states.CommitState.Definition.OnEnter(nil, fsm)
			expect(playerEntity.Inventory).never.toContain("Sword")
			expect(charEntity.EquippedRight).toEqual("Sword")
			expect(playerEntity.Equipped.Right).toEqual("Sword")
			expect(playerEntity.WeaponEqp).toEqual("Sword")
			expect(fsm.State).toEqual("EmitIntent")

			env:Cleanup()
		end)

		it("handles an empty hand gracefully when no weapon is equipped", function()
			resetSharedState()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local _, charEntity, playerEntity = createEquipActors(env)

			local machine = env.Mock:CreateFSM(UnEquipJob, {
				StateMachineId = "UnEquip_Empty",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				Hand = "Right",
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			expect(machine.State).toEqual("Completed")
			expect(#machine.Logs).toBeGreaterThan(0)
			expect(machine.Logs[1].Level).toEqual("WARN")

			env:Cleanup()
		end)
	end)

	describe("AttackJob", function()
		it("fails through rollback when the combat lock is already held", function()
			resetSharedState()
			local weaponId = findComboWeaponId()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local _, charEntity, playerEntity = createEquipActors(env, {
				EquippedRight = weaponId,
				WeaponEqp = weaponId,
			})
			charEntity:SetLockBehavior(false)

			local machine = env.Mock:CreateFSM(AttackJob, {
				StateMachineId = "Attack_Locked",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ComboSlot = 1,
			})

			expect(Helpers.stepUntil(env, machine, "Failed", 30)).toBeTruthy()
			expect(machine.Context._failureReason).toContain("already performing another combat action")
			expect(charEntity.CombatLock).toBeFalsy()

			local sequence = Helpers.getTransitionSequence(env, machine)
			expectSequenceContainsInOrder(expect, sequence, {
				"AcquireCombatLock",
				"RollbackConstraints",
				"ReleaseCombatLock",
				"Failed",
			})

			env:Cleanup()
		end)

		it("completes a valid attack through the expected state sequence", function()
			resetSharedState()
			local weaponId = findComboWeaponId()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local _, charEntity, playerEntity = createEquipActors(env, {
				EquippedRight = weaponId,
				WeaponEqp = weaponId,
			})

			local machine = env.Mock:CreateFSM(AttackJob, {
				StateMachineId = "Attack_Happy",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				ComboSlot = 1,
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 240)).toBeTruthy()
			expect(machine.State).toEqual("Completed")
			expect(charEntity.CombatLock).toBeFalsy()
			expect(charEntity.CanMove).toBeTruthy()
			expect(charEntity.MoveSpeedCap).toEqual(16)

			local sequence = Helpers.getTransitionSequence(env, machine)
			expectSequenceContainsInOrder(expect, sequence, {
				"AcquireCombatLock",
				"ResolveAttackDef",
				"ApplyMovementConstraints",
				"EmitWindupIntent",
				"PlayTimeline",
				"EmitRecoveryIntent",
				"RollbackConstraints",
				"ReleaseCombatLock",
				"Completed",
			})

			env:Cleanup()
		end)
	end)

	describe("DamageJob", function()
		it("applies damage, emits hit feedback, and creates floating damage text", function()
			resetSharedState()
			clearDamageAnchors()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local attacker = Helpers.makeCharacterRig(env, "DamageAttacker")
			local victimCharacter, victimHumanoid = Helpers.makeCharacterRig(env, "DamageVictim")
			local attackerEntity = Helpers.createCharacterEntity(env, "Char_Attacker", {
				Instance = attacker,
				PlayerEntityId = "Player_Attacker",
				UserId = 111,
			})
			Helpers.createPlayerEntity(env, "Player_Attacker", {})
			local victimEntity = Helpers.createCharacterEntity(env, "Char_Victim", {
				Instance = victimCharacter,
				UserId = 222,
			})

			local machine = env.Mock:CreateFSM(DamageJob, {
				StateMachineId = "Damage_Happy",
				AttackerCharEntityId = attackerEntity.EntityId,
				VictimUserId = 222,
				AttackName = "TestStrike",
				BaseDamage = 20,
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 30)).toBeTruthy()
			expect(victimHumanoid.Health).toEqual(80)
			expect(victimEntity.Health).toEqual(80)
			expect(IntentRecords).toHaveLength(1)
			expect(IntentRecords[1].Intent.Kind).toEqual("HitReact")
			expect(env.Mock.events).toHaveLength(1)
			expect(env.Mock.events[1].Event).toEqual("Damage/Applied")
			expect(workspace:FindFirstChild("DamageTextAnchor")).never.toBeNil()

			clearDamageAnchors()
			env:Cleanup()
		end)

		it("fails cleanly when the target is already dead", function()
			resetSharedState()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local attacker = Helpers.makeCharacterRig(env, "DeadTargetAttacker")
			local victimCharacter, victimHumanoid = Helpers.makeCharacterRig(env, "DeadTargetVictim")
			victimHumanoid.Health = 0
			local attackerEntity = Helpers.createCharacterEntity(env, "Char_Attacker", {
				Instance = attacker,
				UserId = 111,
			})
			Helpers.createCharacterEntity(env, "Char_Victim", {
				Instance = victimCharacter,
				UserId = 222,
			})

			local machine = env.Mock:CreateFSM(DamageJob, {
				StateMachineId = "Damage_DeadTarget",
				AttackerCharEntityId = attackerEntity.EntityId,
				VictimUserId = 222,
				BaseDamage = 20,
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("dead")
			expect(IntentRecords).toHaveLength(0)

			env:Cleanup()
		end)
	end)

	describe("BlockJob", function()
		it("enters the blocking state when blocking starts", function()
			resetSharedState()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character = Helpers.makeCharacterRig(env, "BlockStartCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_Block", {
				Instance = character,
			})

			local machine = env.Mock:CreateFSM(BlockJob, {
				StateMachineId = "Block_Start",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(Helpers.stepUntil(env, machine, "WaitForRelease", 20)).toBeTruthy()
			expect(charEntity.IsBlocking).toBeTruthy()
			expect(charEntity.MoveSpeedCap).toEqual(0)
			expect(IntentRecords).toHaveLength(1)
			expect(IntentRecords[1].Intent.Payload.Name).toEqual("Blocking")

			env:Cleanup()
		end)

		it("restores movement and exits blocking when blocking ends", function()
			resetSharedState()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character = Helpers.makeCharacterRig(env, "BlockEndCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_Block", {
				Instance = character,
			})

			local machine = env.Mock:CreateFSM(BlockJob, {
				StateMachineId = "Block_End",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(Helpers.stepUntil(env, machine, "WaitForRelease", 20)).toBeTruthy()
			charEntity.IsBlocking = false
			expect(Helpers.stepUntil(env, machine, "Completed", 20)).toBeTruthy()
			expect(charEntity.IsBlocking).toBeFalsy()
			expect(charEntity.MoveSpeedCap).toEqual(16)

			env:Cleanup()
		end)
	end)

	describe("ReplicateIntentJob", function()
		it("normalizes and replicates a valid intent to the character entity", function()
			resetSharedState()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character = Helpers.makeCharacterRig(env, "IntentCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_Intent", {
				Instance = character,
			})

			local machine = env.Mock:CreateFSM(ReplicateIntentJob, {
				StateMachineId = "Intent_Happy",
				CharacterEntityId = charEntity.EntityId,
				Kind = "Animation",
				Payload = {
					AnimationName = "Blocking",
					Speed = 1.5,
				},
			})

			expect(machine.State).toEqual("Completed")
			expect(IntentRecords).toHaveLength(1)
			expect(IntentRecords[1].Intent.Kind).toEqual("Animation")
			expect(IntentRecords[1].Intent.Payload.Name).toEqual("Blocking")
			expect(IntentRecords[1].Intent.Payload.Speed).toEqual(1.5)
			expect(IntentRecords[1].Intent.SourceCharId).toEqual(charEntity.EntityId)
		end)

		it("rejects an empty payload without mutating the entity", function()
			resetSharedState()
			local env = Helpers.newEnvironment()
			registerSpecModules(env)
			local character = Helpers.makeCharacterRig(env, "IntentEmptyCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_Intent", {
				Instance = character,
			})

			local machine = env.Mock:CreateFSM(ReplicateIntentJob, {
				StateMachineId = "Intent_Empty",
				CharacterEntityId = charEntity.EntityId,
				Kind = "Animation",
				Payload = {},
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("allowlist-blocked animation")
			expect(IntentRecords).toHaveLength(0)

			env:Cleanup()
		end)
	end)
end

TR.register(spec)
return spec
