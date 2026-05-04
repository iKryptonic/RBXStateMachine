--!strict

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

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

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local MeleeAttackJob = Helpers.getStateMachine("MeleeAttackJob")
	local DamageJob = Helpers.getStateMachine("DamageJob")
	local BlockJob = Helpers.getStateMachine("BlockJob")

	describe("MeleeAttackJob", function()
		it("should complete happy path", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local attackerModel, _, attackerRoot = Helpers.makeCharacterRig(env, "Attacker")
			local victimModel, _, victimRoot = Helpers.makeCharacterRig(env, "Victim")
			victimRoot.CFrame = CFrame.new(0, 5, -3)

			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = attackerModel,
				UserId = 101,
				PlayerEntityId = "Player_1",
			})
			local victimEntity = Helpers.createCharacterEntity(env, "Char_2", {
				Instance = victimModel,
				UserId = 202,
			})

			local createdDamageJobs = {}
			env.Orchestrator.CreateStateMachine = function(params)
				table.insert(createdDamageJobs, params)
				return {
					Start = function(_, args)
						params._startedWith = args
					end,
				}
			end

			local machine = env.Mock:CreateFSM(MeleeAttackJob, {
				StateMachineId = "Melee_Happy",
				CharacterEntityId = charEntity.EntityId,
				ComboSlot = 1,
			})

			expect(Helpers.stepUntil(env, machine, "Completed", 60)).toBeTruthy()
			expect(charEntity.Stamina).toEqual(95)
			expect(charEntity:GetContext("_MeleePointers")[1]).toEqual(1)
			expect(#createdDamageJobs).toEqual(1)
			expect(createdDamageJobs[1].StateMachineClass).toEqual("DamageJob")
			expect(createdDamageJobs[1].Context.VictimUserId).toEqual(202)
			expect(victimRoot.AssemblyLinearVelocity.Magnitude).toBeGreaterThan(0)

			local sequence = Helpers.getTransitionSequence(env, machine)
			expectSequenceContainsInOrder(expect, sequence, {
				"AcquireLock",
				"ValidateStamina",
				"DeductStamina",
				"ResolveSequence",
				"EmitPhaseAnimation",
				"ScheduleDamageWindow",
				"WaitForDamageWindow",
				"ScanVictims",
				"ProcessVictim",
				"ApplyKnockback",
				"WaitForRecovery",
				"ReleaseLock",
				"Completed",
			})

			env:Cleanup()
		end)

		it("should fail validation when no character entity exists", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local machine = env.Mock:CreateFSM(MeleeAttackJob, {
				StateMachineId = "Melee_NoEntity",
				CharacterEntityId = "Missing_Char",
				ComboSlot = 1,
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("CharacterEntity not found")

			env:Cleanup()
		end)

		it("should release lock and fail when stamina is insufficient", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local attackerModel = Helpers.makeCharacterRig(env, "Attacker")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = attackerModel,
				Stamina = 1,
			})

			local machine = env.Mock:CreateFSM(MeleeAttackJob, {
				StateMachineId = "Melee_Tired",
				CharacterEntityId = charEntity.EntityId,
				ComboSlot = 2,
			})

			expect(Helpers.stepUntil(env, machine, "Failed", 10)).toBeTruthy()
			expect(machine.Failure).toContain("Not enough stamina")
			expect(charEntity.Stamina).toEqual(1)
			expect(charEntity._lockBehavior).toBeTruthy()

			env:Cleanup()
		end)

		it("should silently complete when combat lock is already held", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local attackerModel = Helpers.makeCharacterRig(env, "Attacker")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = attackerModel,
				Stamina = 100,
			})
			charEntity:SetLockBehavior(false)

			local machine = env.Mock:CreateFSM(MeleeAttackJob, {
				StateMachineId = "Melee_Locked",
				CharacterEntityId = charEntity.EntityId,
				ComboSlot = 1,
			})

			env.Mock:StepFrames(5)
			expect(machine.State).never.toEqual("Failed")
			expect(machine.State == "Complete" or machine.State == "Completed").toBeTruthy()
			expect(charEntity.Stamina).toEqual(100)

			env:Cleanup()
		end)
	end)

	describe("DamageJob", function()
		it("should apply damage on happy path", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env, {
				StatusDefs = {
					Guard = { Id = "Guard", DamageReduction = 0.1 },
				},
			})

			local attackerModel = Helpers.makeCharacterRig(env, "Attacker")
			local victimModel, victimHumanoid = Helpers.makeCharacterRig(env, "Victim")

			local attackerEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = attackerModel,
				UserId = 101,
				PlayerEntityId = "Player_1",
			})
			Helpers.createPlayerEntity(env, "Player_1", {})
			local victimEntity = Helpers.createCharacterEntity(env, "Char_2", {
				Instance = victimModel,
				UserId = 202,
				ActiveStatusEffects = {},
			})

			local machine = env.Mock:CreateFSM(DamageJob, {
				StateMachineId = "Damage_Happy",
				AttackerCharEntityId = attackerEntity.EntityId,
				VictimUserId = 202,
				AttackName = "TestStrike",
				BaseDamage = 20,
			})

			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("Completed")
			expect(victimHumanoid.Health).toEqual(80)
			expect(victimEntity.Health).toEqual(80)
			expect(#env.Mock.events).toEqual(1)
			expect(env.Mock.events[1].Event).toEqual("Damage/Applied")

			env:Cleanup()
		end)

		it("should reject duplicate hit nonces", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local attackerModel = Helpers.makeCharacterRig(env, "Attacker")
			local victimModel = Helpers.makeCharacterRig(env, "Victim")
			local attackerEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = attackerModel,
				UserId = 101,
			})
			Helpers.createCharacterEntity(env, "Char_2", {
				Instance = victimModel,
				UserId = 202,
			})

			local first = env.Mock:CreateFSM(DamageJob, {
				StateMachineId = "Damage_First",
				AttackerCharEntityId = attackerEntity.EntityId,
				VictimUserId = 202,
				AttackName = "TestStrike",
				BaseDamage = 10,
			})
			env.Mock:StepFrames(2)

			local second = env.Mock:CreateFSM(DamageJob, {
				StateMachineId = "Damage_Second",
				AttackerCharEntityId = attackerEntity.EntityId,
				VictimUserId = 202,
				AutoStart = false,
			})
			second.Context._attackerUserId = 101
			second.Context._nonce = first.Context._nonce
			second:Start({ State = "CheckHitNonce" })
			env.Mock:StepFrames(1)

			expect(second.State).toEqual("Failed")
			expect(second.Failure).toContain("Duplicate hit nonce")

			env:Cleanup()
		end)

		it("should fail when the victim cannot be resolved", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local attackerModel = Helpers.makeCharacterRig(env, "Attacker")
			local attackerEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = attackerModel,
				UserId = 101,
			})

			local machine = env.Mock:CreateFSM(DamageJob, {
				StateMachineId = "Damage_MissingVictim",
				AttackerCharEntityId = attackerEntity.EntityId,
				VictimUserId = 999,
				BaseDamage = 10,
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("Victim character entity not found")

			env:Cleanup()
		end)
	end)

	describe("BlockJob", function()
		it("should acquire block state and wait for release on happy path", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local model = Helpers.makeCharacterRig(env, "Blocker")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = model,
			})

			local machine = env.Mock:CreateFSM(BlockJob, {
				StateMachineId = "Block_Happy",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(Helpers.stepUntil(env, machine, "WaitForRelease", 10)).toBeTruthy()
			expect(charEntity.IsBlocking).toBeTruthy()
			expect(charEntity.MoveSpeedCap).toEqual(0)

			charEntity.IsBlocking = false
			expect(Helpers.stepUntil(env, machine, "Completed", 10)).toBeTruthy()
			expect(charEntity.MoveSpeedCap).toEqual(16)

			env:Cleanup()
		end)

		it("should fail validation when the character entity is missing", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local machine = env.Mock:CreateFSM(BlockJob, {
				StateMachineId = "Block_NoEntity",
				CharacterEntityId = "Missing_Char",
			})

			expect(machine.State).toEqual("Failed")
			expect(machine.Failure).toContain("CharacterEntity not found")

			env:Cleanup()
		end)

		it("should release block state when key up clears IsBlocking", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local model = Helpers.makeCharacterRig(env, "Blocker")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = model,
			})

			local machine = env.Mock:CreateFSM(BlockJob, {
				StateMachineId = "Block_KeyUp",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(Helpers.stepUntil(env, machine, "WaitForRelease", 10)).toBeTruthy()
			charEntity.IsBlocking = false
			expect(Helpers.stepUntil(env, machine, "Completed", 10)).toBeTruthy()

			local sequence = Helpers.getTransitionSequence(env, machine)
			expectSequenceContainsInOrder(expect, sequence, {
				"AcquireBlockState",
				"ApplyMovementRestriction",
				"BroadcastBlockUpdate",
				"EmitBlockIntent",
				"WaitForRelease",
				"ReleaseBlockState",
				"RestoreMovement",
				"BroadcastUnblockUpdate",
				"Completed",
			})

			env:Cleanup()
		end)
	end)
end

TR.register(spec)
return spec
