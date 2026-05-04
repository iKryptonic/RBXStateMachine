--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

local sharedFolder = ReplicatedStorage:WaitForChild("shared")
local AbilityCombosDefs = require(sharedFolder:WaitForChild("AbilityCombosDefs"))
local TalentPassiveDefs = require(sharedFolder:WaitForChild("TalentPassiveDefs"))

local function expectSequenceContainsInOrder(expectFn, sequence, expected)
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

local function countOccurrences(sequence, needle)
	local count = 0
	for _, value in ipairs(sequence) do
		if value == needle then
			count += 1
		end
	end
	return count
end

local function registerAbilityModules(env)
	Helpers.registerDefaultModules(env)
	env:RegisterModule("AbilityCombosDefs", AbilityCombosDefs)
end

local function ensureWeaponAsset(env, itemId)
	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
	if not assetsFolder then
		assetsFolder = env:DestroyLater(Instance.new("Folder"))
		assetsFolder.Name = "Assets"
		assetsFolder.Parent = ReplicatedStorage
	end

	local existing = assetsFolder:FindFirstChild(itemId)
	if existing then
		return existing
	end

	local mainModule = ServerScriptService:FindFirstChild("MainModule")
	assert(mainModule, "ServerScriptService.MainModule is required for weapon asset tests")
	local content = mainModule:FindFirstChild("Content")
	assert(content, "ServerScriptService.MainModule.Content is required for weapon asset tests")
	local assetData = content:FindFirstChild("AssetData")
	assert(assetData, "ServerScriptService.MainModule.Content.AssetData is required for weapon asset tests")
	local source = assetData:FindFirstChild(itemId)
	assert(source, string.format("AssetData.%s is required for weapon asset tests", itemId))

	local clone = env:DestroyLater(source:Clone())
	clone.Name = itemId
	clone.Parent = assetsFolder
	return clone
end

local function createAbilityEntities(env, options)
	options = options or {}
	local character = Helpers.makeCharacterRig(env, options.CharacterName or "AbilityCharacter")
	local charEntity = Helpers.createCharacterEntity(env, options.CharacterEntityId or "Char_1", {
		Instance = character,
		PlayerEntityId = options.PlayerEntityId or "Player_1",
		EquippedRight = options.EquippedRight or "",
		AbilityCooldowns = options.CharacterCooldowns or {},
		Mana = options.CharacterMana,
	})
	local playerEntity = Helpers.createPlayerEntity(env, options.PlayerEntityId or "Player_1", {
		Mana = if options.PlayerMana ~= nil then options.PlayerMana else 100,
		EquippedAbilities = options.EquippedAbilities or {},
		UnlockedAbilities = options.UnlockedAbilities or {},
		AbilityCooldowns = options.PlayerCooldowns or {},
		TalentSelections = options.TalentSelections or {},
		Inventory = options.Inventory or {},
	})
	return charEntity, playerEntity
end

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local AbilityComboFSM = Helpers.getStateMachine("AbilityComboFSM")

	describe("AbilityComboFSM", function()
		it("should complete a valid ability combo and record cooldowns", function()
			local env = Helpers.newEnvironment()
			registerAbilityModules(env)
			local charEntity, playerEntity = createAbilityEntities(env, {
				PlayerMana = 100,
				UnlockedAbilities = { ThunderStrike = true },
			})

			local machine = env.Mock:CreateFSM(AbilityComboFSM, {
				StateMachineId = "AbilityCombo_Happy",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				AbilityId = "ThunderStrike",
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 60)).toBeTruthy()
			expect(machine.State).toEqual("Completed")
			expect(playerEntity.Mana).toEqual(70)
			expect((charEntity.AbilityCooldowns :: any).ThunderStrike).toBeGreaterThan(os.clock())
			expect((playerEntity.AbilityCooldowns :: any).ThunderStrike).toBeGreaterThan(os.clock())

			local sequence = Helpers.getTransitionSequence(env, machine)
			expectSequenceContainsInOrder(expect, sequence, {
				"ValidateAbility",
				"CheckMana",
				"DeductMana",
				"PlayComboStep",
				"ProcessComboEvents",
				"AdvanceStep",
				"PlayComboStep",
				"ProcessComboEvents",
				"AdvanceStep",
				"PlayComboStep",
				"ProcessComboEvents",
				"AdvanceStep",
				"Cooldown",
				"Completed",
			})

			env:Cleanup()
		end)

		it("should fail mana validation when the player has less than the required 25 mana", function()
			local env = Helpers.newEnvironment()
			registerAbilityModules(env)
			local charEntity, playerEntity = createAbilityEntities(env, {
				PlayerMana = 10,
				UnlockedAbilities = { WarCry = true },
			})

			local machine = env.Mock:CreateFSM(AbilityComboFSM, {
				StateMachineId = "AbilityCombo_LowMana",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				AbilityId = "WarCry",
			})

			expect(Helpers.stepUntil(env, machine, "Failed", 10)).toBeTruthy()
			expect(machine.Failure).toContain("Not enough mana")
			expect(playerEntity.Mana).toEqual(10)
			expect(Helpers.getTransitionSequence(env, machine)).never.toContain("DeductMana")

			env:Cleanup()
		end)

		it("should reject ability use while cooldown is active", function()
			local env = Helpers.newEnvironment()
			registerAbilityModules(env)
			local charEntity, playerEntity = createAbilityEntities(env, {
				PlayerMana = 100,
				UnlockedAbilities = { WarCry = true },
				CharacterCooldowns = { WarCry = os.clock() + 30 },
			})

			local machine = env.Mock:CreateFSM(AbilityComboFSM, {
				StateMachineId = "AbilityCombo_Cooldown",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				AbilityId = "WarCry",
			})

			expect(Helpers.stepUntil(env, machine, "Failed", 10)).toBeTruthy()
			expect(machine.Failure).toContain("cooldown")
			expect(playerEntity.Mana).toEqual(100)

			env:Cleanup()
		end)

		it("should fail validation for unknown abilities", function()
			local env = Helpers.newEnvironment()
			registerAbilityModules(env)
			local charEntity, playerEntity = createAbilityEntities(env, {
				PlayerMana = 100,
				UnlockedAbilities = {},
			})

			local machine = env.Mock:CreateFSM(AbilityComboFSM, {
				StateMachineId = "AbilityCombo_Unknown",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				AbilityId = "MissingAbility",
			})

			expect(Helpers.stepUntil(env, machine, "Failed", 10)).toBeTruthy()
			expect(machine.Failure).toContain("definition not found")

			env:Cleanup()
		end)

		it("should fail validation when the equipped weapon type does not match the ability", function()
			local env = Helpers.newEnvironment()
			registerAbilityModules(env)
			ensureWeaponAsset(env, "Kama")
			local charEntity, playerEntity = createAbilityEntities(env, {
				PlayerMana = 100,
				UnlockedAbilities = { PowerStrike = true },
				EquippedRight = "Kama",
			})

			local machine = env.Mock:CreateFSM(AbilityComboFSM, {
				StateMachineId = "AbilityCombo_WeaponMismatch",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				AbilityId = "PowerStrike",
			})

			expect(Helpers.stepUntil(env, machine, "Failed", 10)).toBeTruthy()
			expect(machine.Failure).toContain("Incorrect weapon type")

			env:Cleanup()
		end)

		it("should loop through every combo step for a 3-step ability", function()
			local env = Helpers.newEnvironment()
			registerAbilityModules(env)
			local charEntity, playerEntity = createAbilityEntities(env, {
				PlayerMana = 100,
				UnlockedAbilities = { ThunderStrike = true },
			})

			local machine = env.Mock:CreateFSM(AbilityComboFSM, {
				StateMachineId = "AbilityCombo_MultiStep",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				AbilityId = "ThunderStrike",
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 60)).toBeTruthy()
			local sequence = Helpers.getTransitionSequence(env, machine)
			expect(countOccurrences(sequence, "PlayComboStep")).toEqual(3)
			expect(countOccurrences(sequence, "ProcessComboEvents")).toEqual(3)
			expect(countOccurrences(sequence, "AdvanceStep")).toEqual(3)

			env:Cleanup()
		end)

		it("should fail gracefully when the character entity cannot be resolved", function()
			local env = Helpers.newEnvironment()
			registerAbilityModules(env)
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				Mana = 100,
				UnlockedAbilities = { ThunderStrike = true },
			})

			local machine = env.Mock:CreateFSM(AbilityComboFSM, {
				StateMachineId = "AbilityCombo_NoCharacter",
				CharacterEntityId = "Missing_Char",
				PlayerEntityId = playerEntity.EntityId,
				AbilityId = "ThunderStrike",
			})

			expect(Helpers.stepUntil(env, machine, "Failed", 10)).toBeTruthy()
			expect(machine.Failure).toContain("CharacterEntity not found")

			env:Cleanup()
		end)
	end)

	describe("TalentPassiveDefs", function()
		it("should find a known talent and its tier", function()
			local talent, tier = TalentPassiveDefs.FindTalent("SwordMastery")
			expect(talent).never.toBeNil()
			expect((talent :: any).Name).toEqual("Sword Mastery")
			expect(tier).toEqual(1)
		end)

		it("should return nil when a talent id is unknown", function()
			local talent, tier = TalentPassiveDefs.FindTalent("MissingTalent")
			expect(talent).toBeNil()
			expect(tier).toBeNil()
		end)

		it("should merge aura effects from multiple selected talents", function()
			local effects = TalentPassiveDefs.ComputeAuraEffects({
				[1] = "SwordMastery",
				[2] = "ManaWell",
			})
			expect(effects.SwordDamageMultiplier).toEqual(0.15)
			expect(effects.MaxManaMultiplier).toEqual(0.25)
		end)

		it("should return an empty effects table for empty selections", function()
			local effects = TalentPassiveDefs.ComputeAuraEffects({})
			expect(next(effects)).toBeNil()
		end)

		it("should return unlocked ability ids for unlock talents", function()
			local abilities = TalentPassiveDefs.GetUnlockedAbilities({
				[2] = "UnlockWhirlwind",
			})
			expect(abilities).toEqual({ "WhirlwindSlash" })
		end)

		it("should return no unlocked abilities for aura-only selections", function()
			local abilities = TalentPassiveDefs.GetUnlockedAbilities({
				[1] = "SwordMastery",
				[2] = "ManaWell",
			})
			expect(abilities).toEqual({})
		end)

		it("should replace the previous choice when selecting a new talent in the same tier", function()
			local selections = { [1] = "SwordMastery" }
			selections[1] = "QuickFeet"

			local effects = TalentPassiveDefs.ComputeAuraEffects(selections)
			expect(TalentPassiveDefs.SELECTIONS_PER_TIER).toEqual(1)
			expect(effects.SwordDamageMultiplier).toBeNil()
			expect(effects.MoveSpeedMultiplier).toEqual(0.15)
		end)
	end)

	describe("AbilityCombosDefs", function()
		it("should return authored data for a known ability", function()
			local ability = AbilityCombosDefs.GetAbility("PowerStrike")
			expect(ability).never.toBeNil()
			expect((ability :: any).Name).toEqual("Power Strike")
			expect((ability :: any).ManaCost).toEqual(10)
			expect((ability :: any).Cooldown).toEqual(5)
			expect((ability :: any).ComboSequence).toHaveLength(3)
		end)

		it("should return nil for unknown ability ids", function()
			expect(AbilityCombosDefs.GetAbility("MissingAbility")).toBeNil()
		end)

		it("should return a sorted list of all ability ids", function()
			local ids = AbilityCombosDefs.GetAllAbilityIds()
			local sorted = table.clone(ids)
			table.sort(sorted)
			expect(ids).toEqual(sorted)
			expect(ids).toContain("PowerStrike")
			expect(ids).toContain("ThunderStrike")
		end)

		it("should validate the authored schema for every ability", function()
			for abilityId, ability in pairs(AbilityCombosDefs.Abilities) do
				expect(type(ability.Name)).toEqual("string")
				expect(ability.Name).never.toEqual("")
				expect(type(ability.ManaCost)).toEqual("number")
				expect(type(ability.Cooldown)).toEqual("number")
				expect(type(ability.ComboSequence)).toEqual("table")
				expect(#ability.ComboSequence).toBeGreaterThan(0)

				for index, step in ipairs(ability.ComboSequence) do
					expect(type(step.Animation)).toEqual("string")
					expect(step.Animation).never.toEqual("")
					expect(type(step.Duration)).toEqual("number")
					expect(type(step.Speed)).toEqual("number")
					expect(index).toBeGreaterThan(0)
				end
			end
		end)
	end)
end

TR.register(spec)
return spec
