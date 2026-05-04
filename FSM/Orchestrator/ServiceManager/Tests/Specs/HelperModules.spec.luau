--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

local function requireHelper(name: string)
	local moduleScript = ReplicatedStorage:FindFirstChild(name, true)
	assert(moduleScript and moduleScript:IsA("ModuleScript"), string.format("Helper module %s not found", name))
	return require(moduleScript)
end

local CombatHelpers = requireHelper("CombatHelpers")
local CrowdControlHelpers = requireHelper("CrowdControlHelpers")
local EntityHelpers = requireHelper("EntityHelpers")
local IntentHelpers = requireHelper("IntentHelpers")
local ModuleLoader = requireHelper("ModuleLoader")
local ResourceHelpers = requireHelper("ResourceHelpers")
local StateTransitionHelpers = requireHelper("StateTransitionHelpers")

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function makeRigEntity(env: any, entityId: string, rigName: string, position: Vector3, data: any?)
		local character, humanoid, root = Helpers.makeCharacterRig(env, rigName)
		root.CFrame = CFrame.new(position)
		local entityData = table.clone(data or {})
		entityData.Instance = character
		local entity = Helpers.createCharacterEntity(env, entityId, entityData)
		return entity, character, humanoid, root
	end

	describe("CombatHelpers", function()
		it("returns an empty list when the orchestrator has no entities", function()
			local victims = CombatHelpers.scanVictims({}, "Source", Vector3.new(), 12)
			expect(victims).toHaveLength(0)
		end)

		it("finds only living victims in range and sorts them by distance", function()
			local env = Helpers.newEnvironment()
			makeRigEntity(env, "Source", "SourceRig", Vector3.new(0, 0, 0))
			makeRigEntity(env, "Near", "NearRig", Vector3.new(3, 0, 0))
			makeRigEntity(env, "Far", "FarRig", Vector3.new(6, 0, 0))
			local _, _, deadHumanoid = makeRigEntity(env, "Dead", "DeadRig", Vector3.new(2, 0, 0))
			deadHumanoid.Health = 0
			makeRigEntity(env, "Out", "OutRig", Vector3.new(20, 0, 0))

			local victims = CombatHelpers.scanVictims(env.Orchestrator, "Source", Vector3.new(0, 0, 0), 10)
			expect(victims).toHaveLength(2)
			expect(victims[1].EntityId).toEqual("Near")
			expect(victims[2].EntityId).toEqual("Far")
			expect(victims[1].Distance).toBeLessThan(victims[2].Distance)

			env:Cleanup()
		end)

		it("returns only forward victims for frontal scans", function()
			local env = Helpers.newEnvironment()
			local _, _, _, attackerRoot = makeRigEntity(env, "Source", "AttackerRig", Vector3.new(0, 0, 0))
			attackerRoot.CFrame = CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(0, 0, -10))
			makeRigEntity(env, "Front", "FrontRig", Vector3.new(0, 0, -5))
			makeRigEntity(env, "Behind", "BehindRig", Vector3.new(0, 0, 5))
			makeRigEntity(env, "Overlap", "OverlapRig", Vector3.new(0, 0, 0))

			local victims = CombatHelpers.scanForwardVictims(env.Orchestrator, "Source", attackerRoot, 10)
			expect(victims).toHaveLength(1)
			expect(victims[1].EntityId).toEqual("Front")

			env:Cleanup()
		end)

		it("creates and starts a damage job when the victim resolves to a user id", function()
			local createdParams = nil
			local startArgs = nil
			local machine = { Start = function(_self, args)
				startArgs = args
			end }
			local orchestrator = {
				CreateStateMachine = function(params)
					createdParams = params
					return machine
				end,
			}

			local result = CombatHelpers.createDamageJob(
				orchestrator,
				"Attacker_1",
				{ UserId = 77, EntityId = "Victim_77" },
				"Slash",
				25,
				"nonce-1"
			)

			expect(result).toBe(machine)
			expect(createdParams.StateMachineClass).toEqual("DamageJob")
			expect(createdParams.StateMachineId).toContain("Damage_Attacker_1_77_nonce-1")
			expect(createdParams.Context.AttackerEntityId).toEqual("Attacker_1")
			expect(createdParams.Context.VictimUserId).toEqual(77)
			expect(createdParams.Context.VictimEntityId).toEqual("Victim_77")
			expect(createdParams.Context.BaseDamage).toEqual(25)
			expect(startArgs.State).toEqual("Validate")
		end)

		it("returns nil and skips creation when the victim is invalid", function()
			local wasCalled = false
			local orchestrator = {
				CreateStateMachine = function()
					wasCalled = true
				end,
			}

			local result = CombatHelpers.createDamageJob(orchestrator, "Attacker_1", { UserId = "bad" }, "Slash", 10)
			expect(result).toBeNil()
			expect(wasCalled).toBeFalsy()
		end)
	end)

	describe("EntityHelpers", function()
		it("returns nil humanoid and root for a nil subject", function()
			local humanoid, root = EntityHelpers.getHumanoidAndRoot(nil)
			expect(humanoid).toBeNil()
			expect(root).toBeNil()
		end)

		it("finds the humanoid and humanoid root part for a model", function()
			local env = Helpers.newEnvironment()
			local character, humanoid, root = Helpers.makeCharacterRig(env, "EntityHelperRig")

			local resolvedHumanoid, resolvedRoot = EntityHelpers.getHumanoidAndRoot(character)
			expect(resolvedHumanoid).toBe(humanoid)
			expect(resolvedRoot).toBe(root)

			env:Cleanup()
		end)

		it("resolves character parts through the entity Instance field", function()
			local env = Helpers.newEnvironment()
			local entity, character, humanoid, root = makeRigEntity(env, "Char_1", "CharacterPartsRig", Vector3.new(0, 0, 0))

			local resolvedCharacter, resolvedHumanoid, resolvedRoot = EntityHelpers.getCharacterParts(entity)
			expect(resolvedCharacter).toBe(character)
			expect(resolvedHumanoid).toBe(humanoid)
			expect(resolvedRoot).toBe(root)

			env:Cleanup()
		end)

		it("reports a dead character as unable to act", function()
			local env = Helpers.newEnvironment()
			local entity, _, humanoid = makeRigEntity(env, "Char_1", "DeadCharacterRig", Vector3.new(0, 0, 0))
			humanoid.Health = 0

			local ok, reason = EntityHelpers.validateCharacterAlive(entity)
			expect(ok).toBeFalsy()
			expect(reason).toEqual("Character cannot act")

			env:Cleanup()
		end)

		it("reports crowd control flags when stunned or knocked", function()
			expect(EntityHelpers.isCrowdControlled({ IsStunned = true })).toBeTruthy()
			expect(EntityHelpers.isCrowdControlled({ IsKnocked = true })).toBeTruthy()
			expect(EntityHelpers.isCrowdControlled({})).toBeFalsy()
		end)

		it("syncs humanoid health from entity data and clamps overflow", function()
			local env = Helpers.newEnvironment()
			local entity, _, humanoid = makeRigEntity(env, "Char_1", "SyncRig", Vector3.new(0, 0, 0), {
				Health = 250,
				MaxHealth = 120,
			})

			EntityHelpers.syncHumanoidFromEntity(entity)
			expect(humanoid.MaxHealth).toEqual(120)
			expect(humanoid.Health).toEqual(120)
			expect(entity.Health).toEqual(120)

			env:Cleanup()
		end)
	end)

	describe("StateTransitionHelpers", function()
		it("uses ScheduleTransition when the FSM provides it", function()
			local called = nil
			local fsm = {
				ScheduleTransition = function(_self, seconds, targetState)
					called = { seconds = seconds, targetState = targetState }
				end,
			}

			StateTransitionHelpers.scheduleTransitionCompat(fsm, 0.25, "Recover")
			expect(called.seconds).toEqual(0.25)
			expect(called.targetState).toEqual("Recover")
		end)

		it("stores a failure reason and enters the release state when a lock is held", function()
			local fsm = {
				_ccLockHeld = true,
				_failureReason = nil,
				State = "Apply",
				Fail = function()
					error("Fail should not be called")
				end,
			}

			StateTransitionHelpers.failOrRelease(fsm, "lock failure")
			expect(fsm._failureReason).toEqual("lock failure")
			expect(fsm.State).toEqual("ReleaseCCLock")
		end)

		it("fails immediately when no lock is held", function()
			local failedReason = nil
			local fsm = {
				_ccLockHeld = false,
				Fail = function(_self, reason)
					failedReason = reason
				end,
			}

			StateTransitionHelpers.failOrRelease(fsm, "bad state")
			expect(failedReason).toEqual("bad state")
		end)

		it("queues release metadata in the FSM context", function()
			local fsm = {
				Context = {},
				State = "Cast",
			}

			StateTransitionHelpers.queueRelease(fsm, "Cooldown", "cleanup needed")
			expect(fsm.Context._releaseTargetState).toEqual("Cooldown")
			expect(fsm.Context._releaseReason).toEqual("cleanup needed")
			expect(fsm.State).toEqual("ReleaseLock")
		end)

		it("queues rollback state, stores the reason, and logs an error", function()
			local logged = nil
			local fsm = {
				Context = {},
				State = "Validate",
				Log = function(_self, entry)
					logged = entry
				end,
			}

			StateTransitionHelpers.queueRollback(fsm, "validation failed")
			expect(fsm.Context._failureReason).toEqual("validation failed")
			expect(fsm.State).toEqual("Rollback")
			expect(logged.Level).toEqual("ERROR")
			expect(logged.Message).toEqual("validation failed")
		end)
	end)

	describe("ResourceHelpers", function()
		it("deducts mana when enough resource is available", function()
			local entity = { Mana = 30 }
			expect(ResourceHelpers.deductMana(entity, 12)).toBeTruthy()
			expect(entity.Mana).toEqual(18)
		end)

		it("does not deduct mana when the cost exceeds the current amount", function()
			local entity = { Mana = 8 }
			expect(ResourceHelpers.deductMana(entity, 12)).toBeFalsy()
			expect(entity.Mana).toEqual(8)
		end)

		it("treats missing or invalid mana as zero", function()
			local entity = { Mana = "unknown" }
			expect(ResourceHelpers.deductMana(entity, 1)).toBeFalsy()
			expect(entity.Mana).toEqual("unknown")
		end)

		it("restores a resource but clamps to the configured maximum", function()
			local entity = { Mana = 12, MaxMana = 20 }
			local newValue = ResourceHelpers.restoreResource(entity, "Mana", 15, "MaxMana")
			expect(newValue).toEqual(20)
			expect(entity.Mana).toEqual(20)
		end)

		it("clamps health stamina and mana into valid ranges", function()
			local entity = {
				Health = 120,
				MaxHealth = 100,
				Stamina = -5,
				MaxStamina = 50,
				Mana = 70,
				MaxMana = 40,
			}

			ResourceHelpers.clampResources(entity)
			expect(entity.Health).toEqual(100)
			expect(entity.Stamina).toEqual(0)
			expect(entity.Mana).toEqual(40)
		end)
	end)

	describe("IntentHelpers", function()
		it("builds animation payloads with defaults and alternate names", function()
			local payload = IntentHelpers.buildIntentPayload("Animation", {
				AnimationName = "Slash",
			})
			expect(payload).toEqual({
				Name = "Slash",
				Speed = 1,
				FadeTime = 0.1,
			})
		end)

		it("builds sound payloads and coerces ids to strings", function()
			local payload = IntentHelpers.buildIntentPayload("Sound", {
				Id = 12345,
				Volume = 0.8,
			})
			expect(payload).toEqual({
				SoundId = "12345",
				Volume = 0.8,
				Pitch = 1,
			})
		end)

		it("builds effect payloads by cloning and normalizing the effect name", function()
			local rawIntent = {
				EffectName = "HitSpark",
				Duration = 0.3,
			}
			local payload = IntentHelpers.buildIntentPayload("Effect", rawIntent)
			expect(payload).toHaveProperty("Name", "HitSpark")
			expect(payload).toHaveProperty("Duration", 0.3)
			expect(payload.EffectName).toBeNil()
			expect(payload).never.toBe(rawIntent)
		end)

		it("returns nil for unsupported or invalid intent payloads", function()
			expect(IntentHelpers.buildIntentPayload("Animation", { Name = "" })).toBeNil()
			expect(IntentHelpers.buildIntentPayload("Unknown", { Name = "Slash" })).toBeNil()
		end)

		it("appends normalized intents through the shared IntentSchema module", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})

			IntentHelpers.appendIntent(env.Orchestrator, charEntity, "Animation", { Name = "Slash" }, "Source_1", nil, "Lock_1")
			local intents = charEntity:GetContext("_RecordedIntents")
			expect(intents).toHaveLength(1)
			expect(intents[1].Kind).toEqual("Animation")
			expect(intents[1].SourceCharId).toEqual("Source_1")
			expect(intents[1].TargetCharId).toEqual("Source_1")

			env:Cleanup()
		end)

		it("ignores invalid optional intents and appends valid ones", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})

			IntentHelpers.appendOptionalIntent(env.Orchestrator, charEntity, { Kind = 55 }, "Source_1")
			expect(charEntity:GetContext("_RecordedIntents")).toBeNil()

			IntentHelpers.appendOptionalIntent(env.Orchestrator, charEntity, {
				Kind = "Sound",
				SoundId = 555,
			}, "Source_1", nil, "Target_1")
			local intents = charEntity:GetContext("_RecordedIntents")
			expect(intents).toHaveLength(1)
			expect(intents[1].TargetCharId).toEqual("Target_1")
			expect(intents[1].Payload.SoundId).toEqual("555")

			env:Cleanup()
		end)
	end)

	describe("CrowdControlHelpers", function()
		it("acquires the CC lock when it is free", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { CCLock = false })

			local ok, reason = CrowdControlHelpers.acquireCCLock(charEntity)
			expect(ok).toBeTruthy()
			expect(reason).toBeNil()
			expect(charEntity.CCLock).toBeTruthy()

			env:Cleanup()
		end)

		it("rejects acquiring the CC lock when it is already held", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { CCLock = true })

			local ok, reason = CrowdControlHelpers.acquireCCLock(charEntity)
			expect(ok).toBeFalsy()
			expect(reason).toEqual("CCLock already held")

			env:Cleanup()
		end)

		it("reverts the CC lock when persistence fails", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { CCLock = false })
			charEntity:SetUpdateBehavior(false)

			local ok, reason = CrowdControlHelpers.acquireCCLock(charEntity)
			expect(ok).toBeFalsy()
			expect(reason).toEqual("Failed to acquire CCLock")
			expect(charEntity.CCLock).toBeFalsy()

			env:Cleanup()
		end)

		it("applies crowd control flags and persists them", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {})

			expect(CrowdControlHelpers.applyFlags(charEntity, {
				IsStunned = true,
				StunDuration = 2,
			})).toBeTruthy()
			expect(charEntity.IsStunned).toBeTruthy()
			expect(charEntity.StunDuration).toEqual(2)

			env:Cleanup()
		end)

		it("releases the CC lock and persists the unlock", function()
			local env = Helpers.newEnvironment()
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { CCLock = true })

			expect(CrowdControlHelpers.releaseCCLock(charEntity)).toBeTruthy()
			expect(charEntity.CCLock).toBeFalsy()

			env:Cleanup()
		end)
	end)

	describe("ModuleLoader", function()
		it("gets shared modules from the orchestrator module registry", function()
			local env = Helpers.newEnvironment()
			local moduleValue = { Name = "IntentSchema" }
			env:RegisterModule("IntentSchema", moduleValue)

			expect(ModuleLoader.getSharedModule(env.Orchestrator, "IntentSchema")).toBe(moduleValue)

			env:Cleanup()
		end)

		it("returns nil when a shared module cannot be found", function()
			expect(ModuleLoader.getSharedModule({}, "MissingModule")).toBeNil()
		end)

		it("requires shared modules when they exist", function()
			local env = Helpers.newEnvironment()
			local moduleValue = { Name = "DamageCalculator" }
			env:RegisterModule("DamageCalculator", moduleValue)

			expect(ModuleLoader.requireSharedModule(env.Orchestrator, "DamageCalculator")).toBe(moduleValue)

			env:Cleanup()
		end)

		it("throws when a required shared module is missing", function()
			expect(function()
				ModuleLoader.requireSharedModule({}, "MissingModule")
			end).toThrow("Required module not found")
		end)
	end)
end

TR.register(spec)
return spec
