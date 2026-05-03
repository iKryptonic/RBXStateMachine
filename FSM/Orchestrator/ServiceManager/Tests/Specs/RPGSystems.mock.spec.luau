--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

local function getRuntimeStatusEffectDefs(): any
	local sharedFolder = ReplicatedStorage:FindFirstChild("shared")
	assert(sharedFolder, "ReplicatedStorage.shared is required for StatusEffectFSM tests")
	local moduleScript = sharedFolder:FindFirstChild("StatusEffectDefs")
	assert(moduleScript and moduleScript:IsA("ModuleScript"), "shared.StatusEffectDefs is required for StatusEffectFSM tests")
	return require(moduleScript)
end

local function findEffect(defs: any, predicate: (any) -> boolean): any?
	local effects = defs.Effects or {}
	for _, def in pairs(effects) do
		if typeof(def) == "table" and predicate(def) then
			return def
		end
	end
	return nil
end

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local CastFSMModule = Helpers.getStateMachine("CastFSM")
	local CastFSM = require(CastFSMModule)
	local StatusEffectFSM = Helpers.getStateMachine("StatusEffectFSM")
	local CrowdControlFSM = Helpers.getStateMachine("CrowdControlFSM")

	describe("CastFSM", function()
		it("should validate ability requests and reject missing definitions", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env, {
				AbilityDefs = {
					GetAbility = function()
						return nil
					end,
					GetConsumable = function()
						return nil
					end,
				},
			})

			local character = Helpers.makeCharacterRig(env, "CasterValidation")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
			})
			Helpers.createPlayerEntity(env, "Player_1", {})

			local machine = env.Mock:CreateFSM(CastFSMModule, {
				StateMachineId = "Cast_Invalid",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = "Player_1",
				AbilityId = "MissingAbility",
			})
			machine.State = "ValidateAbility"
			env.Mock:StepFrames(1)

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("Cast definition not found")

			env:Cleanup()
		end)

		it("should deduct resources and set cooldown on a successful cast", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env, {
				IsAbilityUnlocked = true,
			})

			local character, _, root = Helpers.makeCharacterRig(env, "CasterResources")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				PlayerEntityId = "Player_1",
				Stamina = 80,
				Mana = 40,
				Health = 60,
			})
			local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
				LearnedAbilities = { HealPulse = true },
			})

			local machine = env.Mock:CreateFSM(CastFSMModule, {
				StateMachineId = "Cast_Resources",
				CharacterEntityId = charEntity.EntityId,
				PlayerEntityId = playerEntity.EntityId,
				AutoStart = true,
			})

			local castDef = {
				Id = "HealPulse",
				SourceType = "Ability",
				EffectType = "SelfHeal",
				StaminaCost = 15,
				ManaCost = 10,
				Cooldown = 2,
				CastTime = 0.1,
				HealAmount = 20,
				Animation = "CastSpell",
				FinishAnimation = "CastDone",
			}

			CastFSM.RequestCast(machine, castDef, charEntity.EntityId)
			expect(Helpers.stepUntil(env, machine, "Completed", 60)).toBeTruthy()
			expect(charEntity.Stamina).toEqual(65)
			expect(charEntity.Mana).toEqual(30)
			expect(charEntity.Health).toEqual(80)
			expect(charEntity.ActiveCastId).toEqual("")
			expect((charEntity.AbilityCooldowns or {}).HealPulse).toBeGreaterThan(os.clock())
			expect(root.Parent).toBe(character)

			env:Cleanup()
		end)

		it("should dispatch every ExecuteX branch", function()
			local branchCases = {
				{
					Name = "MeleeSingle",
					Def = { Id = "Strike", SourceType = "Ability", EffectType = "MeleeSingle", Damage = 12, CastTime = 0, Cooldown = 1 },
					Assert = function(_env, _charEntity, _playerEntity, createdDamageJobs, _root)
						expect(#createdDamageJobs).toEqual(1)
					end,
				},
				{
					Name = "MeleeAoE",
					Def = { Id = "Whirl", SourceType = "Ability", EffectType = "MeleeAoE", Damage = 8, CastTime = 0, Cooldown = 1 },
					VictimCount = 2,
					Assert = function(_env, _charEntity, _playerEntity, createdDamageJobs, _root)
						expect(#createdDamageJobs).toEqual(2)
					end,
				},
				{
					Name = "Projectile",
					Def = { Id = "Fireball", SourceType = "Ability", EffectType = "Projectile", Damage = 14, CastTime = 0, Cooldown = 1 },
					Assert = function(_env, _charEntity, _playerEntity, _createdDamageJobs, _root)
						local projectile = nil
						for _, child in ipairs(workspace:GetChildren()) do
							if child.Name:find("^CastProjectile_Fireball") then
								projectile = child
								break
							end
						end
						expect(projectile).never.toBeNil()
					end,
				},
				{
					Name = "SelfHeal",
					Def = { Id = "Renew", SourceType = "Ability", EffectType = "SelfHeal", HealAmount = 15, CastTime = 0, Cooldown = 1 },
					Assert = function(_env, charEntity)
						expect(charEntity.Health).toEqual(75)
					end,
				},
				{
					Name = "InstantHeal",
					Def = { Id = "PotionHeal", SourceType = "Ability", EffectType = "InstantHeal", HealAmount = 25, CastTime = 0, Cooldown = 1 },
					Assert = function(_env, charEntity)
						expect(charEntity.Health).toEqual(85)
					end,
				},
				{
					Name = "InstantStamina",
					Def = { Id = "PotionStamina", SourceType = "Ability", EffectType = "InstantStamina", RestoreAmount = 20, CastTime = 0, Cooldown = 1 },
					Assert = function(_env, charEntity)
						expect(charEntity.Stamina).toEqual(70)
					end,
				},
				{
					Name = "InstantMana",
					Def = { Id = "PotionMana", SourceType = "Ability", EffectType = "InstantMana", RestoreAmount = 15, CastTime = 0, Cooldown = 1 },
					Assert = function(_env, charEntity)
						expect(charEntity.Mana).toEqual(45)
					end,
				},
				{
					Name = "Dash",
					Def = { Id = "BlinkStrike", SourceType = "Ability", EffectType = "Dash", DashDistance = 12, Damage = 10, CastTime = 0, Cooldown = 1 },
					Assert = function(_env, _charEntity, _playerEntity, createdDamageJobs, root)
						expect(#createdDamageJobs).toEqual(1)
						expect(root:FindFirstChildOfClass("BodyVelocity")).never.toBeNil()
					end,
				},
				{
					Name = "TargetedAoE",
					Def = { Id = "Meteor", SourceType = "Ability", EffectType = "TargetedAoE", Damage = 11, AoERadius = 8, CastTime = 0, Cooldown = 1 },
					VictimCount = 2,
					UseTargetEntity = true,
					Assert = function(_env, _charEntity, _playerEntity, createdDamageJobs, _root)
						expect(#createdDamageJobs).toEqual(2)
					end,
				},
			}

			for _, case in ipairs(branchCases) do
				local env = Helpers.newEnvironment()
				Helpers.registerDefaultModules(env, { IsAbilityUnlocked = true })

				local character, _, root = Helpers.makeCharacterRig(env, "Caster_" .. case.Name)
				local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
					Instance = character,
					PlayerEntityId = "Player_1",
					Health = 60,
					Stamina = 50,
					Mana = 30,
				})
				local playerEntity = Helpers.createPlayerEntity(env, "Player_1", {
					LearnedAbilities = { [case.Def.Id] = true },
				})

				local createdDamageJobs = {}
				env.Orchestrator.CreateStateMachine = function(params)
					table.insert(createdDamageJobs, params)
					return { Start = function() end }
				end

				local victimCount = case.VictimCount or 1
				for index = 1, victimCount do
					local victimModel, _, victimRoot = Helpers.makeCharacterRig(env, case.Name .. "Victim" .. tostring(index))
					victimRoot.CFrame = CFrame.new(index * 2, 5, -4)
					Helpers.createCharacterEntity(env, "Victim_" .. tostring(index), {
						Instance = victimModel,
						UserId = 200 + index,
					})
				end

				if case.UseTargetEntity then
					charEntity.TargetEntityId = "Victim_1"
				end

				local machine = env.Mock:CreateFSM(CastFSMModule, {
					StateMachineId = "Cast_" .. case.Name,
					CharacterEntityId = charEntity.EntityId,
					PlayerEntityId = playerEntity.EntityId,
				})
				CastFSM.RequestCast(machine, case.Def, charEntity.EntityId)
				env.Mock:StepFrames(10)

				expect(machine.State).toEqual("Completed")
				case.Assert(env, charEntity, playerEntity, createdDamageJobs, root)
				env:Cleanup()
			end
		end)
	end)

	describe("StatusEffectFSM", function()
		it("should apply tick effects and clean up on expiry", function()
			local defs = getRuntimeStatusEffectDefs()
			local tickEffect = findEffect(defs, function(def)
				return (tonumber(def.TickDamage) or 0) > 0 or (tonumber(def.TickHeal) or 0) > 0
			end)
			assert(tickEffect, "No runtime status effect with tick behavior is available")

			local env = Helpers.newEnvironment()
			local character, humanoid = Helpers.makeCharacterRig(env, "StatusTickCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				Health = 80,
				MaxHealth = 100,
			})

			local machine = env.Mock:CreateFSM(StatusEffectFSM, {
				StateMachineId = "Status_Tick",
				CharacterEntityId = charEntity.EntityId,
				EffectId = tickEffect.Id,
			})

			expect(Helpers.stepUntil(env, machine, "Ticking", 10)).toBeTruthy()
			local before = charEntity.Health
			env.Mock:StepFrames(math.max(2, math.ceil((tonumber(tickEffect.TickInterval) or 0.1) * 60) + 2))
			expect(charEntity.Health).never.toEqual(before)
			expect(#(charEntity.ActiveStatusEffects or {})).toBeGreaterThan(0)
			expect(Helpers.stepUntil(env, machine, "Expired", math.max(60, math.ceil((tonumber(tickEffect.Duration) or 1) * 60) + 30))).toBeTruthy()
			expect(#(charEntity.ActiveStatusEffects or {})).toEqual(0)
			expect(humanoid.Health).toEqual(charEntity.Health)

			env:Cleanup()
		end)

		it("should apply and later remove stat modifiers and flags", function()
			local defs = getRuntimeStatusEffectDefs()
			local modifierEffect = findEffect(defs, function(def)
				return (typeof(def.StatModifiers) == "table" and next(def.StatModifiers) ~= nil)
					or (typeof(def.ApplyFlags) == "table" and next(def.ApplyFlags) ~= nil)
			end)
			assert(modifierEffect, "No runtime status effect with modifiers is available")

			local env = Helpers.newEnvironment()
			local character = Helpers.makeCharacterRig(env, "StatusModifierCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				MoveSpeedCap = 16,
				Strength = 10,
				CanMove = true,
			})

			local originalStrength = charEntity.Strength
			local originalMove = charEntity.MoveSpeedCap
			local originalCanMove = charEntity.CanMove

			local machine = env.Mock:CreateFSM(StatusEffectFSM, {
				StateMachineId = "Status_Modifier",
				CharacterEntityId = charEntity.EntityId,
				EffectId = modifierEffect.Id,
			})

			expect(Helpers.stepUntil(env, machine, "Ticking", 10)).toBeTruthy()
			if typeof(modifierEffect.StatModifiers) == "table" and modifierEffect.StatModifiers.Strength ~= nil then
				expect(charEntity.Strength).never.toEqual(originalStrength)
			end
			if typeof(modifierEffect.ApplyFlags) == "table" and modifierEffect.ApplyFlags.CanMove ~= nil then
				expect(charEntity.CanMove).toEqual(modifierEffect.ApplyFlags.CanMove)
			end
			if typeof(modifierEffect.ApplyFlags) == "table" and modifierEffect.ApplyFlags.MoveSpeedCap ~= nil then
				expect(charEntity.MoveSpeedCap).toEqual(modifierEffect.ApplyFlags.MoveSpeedCap)
			end

			expect(Helpers.stepUntil(env, machine, "Expired", math.max(60, math.ceil((tonumber(modifierEffect.Duration) or 1) * 60) + 30))).toBeTruthy()
			expect(charEntity.Strength).toEqual(originalStrength)
			expect(charEntity.MoveSpeedCap).toEqual(originalMove)
			expect(charEntity.CanMove).toEqual(originalCanMove)

			env:Cleanup()
		end)

		it("should fail validation when the character entity is missing", function()
			local env = Helpers.newEnvironment()
			local machine = env.Mock:CreateFSM(StatusEffectFSM, {
				StateMachineId = "Status_Invalid",
				CharacterEntityId = "Missing_Char",
				EffectId = "Anything",
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("CharacterEntity not found")

			env:Cleanup()
		end)
	end)

	describe("CrowdControlFSM", function()
		it("should apply and clear stun flags", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			local character = Helpers.makeCharacterRig(env, "StunCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				CanMove = true,
				MoveSpeedCap = 16,
			})

			local machine = env.Mock:CreateFSM(CrowdControlFSM, {
				StateMachineId = "CC_Stun",
				CharacterEntityId = charEntity.EntityId,
				Operation = "Stun",
				Duration = 0.1,
			})

			expect(Helpers.stepUntil(env, machine, "WaitDuration", 10)).toBeTruthy()
			expect(charEntity.IsStunned).toBeTruthy()
			expect(charEntity.CanMove).toBeFalsy()
			expect(charEntity.MoveSpeedCap).toEqual(0)
			expect(Helpers.stepUntil(env, machine, "Completed", 20)).toBeTruthy()
			expect(charEntity.IsStunned).toBeFalsy()
			expect(charEntity.CanMove).toBeTruthy()
			expect(charEntity.CCLock).toBeFalsy()

			env:Cleanup()
		end)

		it("should apply and clear knockdown flags", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			local character = Helpers.makeCharacterRig(env, "KnockCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
			})

			local machine = env.Mock:CreateFSM(CrowdControlFSM, {
				StateMachineId = "CC_Knock",
				CharacterEntityId = charEntity.EntityId,
				Operation = "Knockdown",
				Duration = 0.1,
			})

			expect(Helpers.stepUntil(env, machine, "WaitDuration", 10)).toBeTruthy()
			expect(charEntity.IsKnocked).toBeTruthy()
			expect(Helpers.stepUntil(env, machine, "Completed", 20)).toBeTruthy()
			expect(charEntity.IsKnocked).toBeFalsy()
			expect(charEntity.MoveSpeedCap).toEqual(16)

			env:Cleanup()
		end)

		it("should fail for unsupported crowd control operations", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			local character = Helpers.makeCharacterRig(env, "BadCCCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { Instance = character })

			local machine = env.Mock:CreateFSM(CrowdControlFSM, {
				StateMachineId = "CC_Invalid",
				CharacterEntityId = charEntity.EntityId,
				Operation = "Freeze",
				Duration = 0.1,
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("Unsupported crowd control operation")

			env:Cleanup()
		end)
	end)
end

TR.register(spec)
return spec
