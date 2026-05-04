--!strict
-- @Name ServiceManager/Tests/Specs/EquipLocking.spec.luau
-- @Author iKrypto
-- @Description Contract tests for equip lock acquisition, retry, and release.

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.Parent.Mocks.StateMachineSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function loadJob(name: string)
		local job = Helpers.requireStateMachine(name)
		return job, Helpers.captureStates(job)
	end

	local function assertRetryAndRelease(jobName: string)
		local job, states = loadJob(jobName)
		expect(job.validStates).toContain("AcquireEquipLock")
		expect(job.validStates).toContain("ReleaseEquipLock")

		local charEntity = Helpers.makeCharacterEntity({
			EntityId = jobName .. "_Char",
			EquipLock = { Right = true },
		})
		local orchestrator = Helpers.makeOrchestrator({
			entities = { [jobName .. "_Char"] = charEntity },
		})
		local retryFsm = Helpers.makeFSM(orchestrator, {
			CharacterEntityId = jobName .. "_Char",
			Hand = "Right",
			Context = {},
		})

		states.AcquireEquipLock.Definition.OnEnter(nil, retryFsm)
		expect(retryFsm.State).toEqual("AcquireEquipLock")
		expect(retryFsm.WaitSpan).toEqual(0.3)
		expect(retryFsm.Context._equipLockRetryCount).toEqual(1)

		charEntity.EquipLock = { Right = true }
		local releaseFsm = Helpers.makeFSM(orchestrator, {
			CharacterEntityId = jobName .. "_Char",
			Hand = "Right",
			Context = {
				_equipLockHeld = true,
				_failureReason = "lock timeout",
			},
		})
		states.ReleaseEquipLock.Definition.OnEnter(nil, releaseFsm)
		expect(charEntity.EquipLock.Right).toBeNil()
		expect(releaseFsm.Context._equipLockHeld).toEqual(false)
		expect(releaseFsm.State).toEqual("Failed")
		return states
	end

	describe("equip locking contracts", function()
		it("EquipJob exposes acquire/release/rollback states", function()
			local states = assertRetryAndRelease("EquipJob")
			expect(states.Rollback).never.toBeNil()
			expect(states.Rollback.Transitions).toContain("ReleaseEquipLock")
		end)

		it("UnEquipJob exposes acquire/release/rollback states", function()
			local states = assertRetryAndRelease("UnEquipJob")
			expect(states.Rollback).never.toBeNil()
			expect(states.Rollback.Transitions).toContain("ReleaseEquipLock")
		end)
	end)
end

TR.register(spec)
return spec
