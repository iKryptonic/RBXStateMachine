--!strict
-- @Name ServiceManager/Tests/Specs/CombatFSMTermination.spec.luau
-- @Author iKrypto
-- @Description Regression tests for combat FSM termination on UpdateEntity(false).

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

	local function hasWarn(logs, needle: string): boolean
		for _, entry in ipairs(logs) do
			if entry.Level == "WARN" and type(entry.Message) == "string" and string.find(entry.Message, needle, 1, true) then
				return true
			end
		end
		return false
	end

	describe("combat termination guards", function()
		it("AttackJob rollback warns instead of failing when UpdateEntity returns false", function()
			local job, states = loadJob("AttackJob")
			expect(job.terminalStates).toEqual({ "Completed", "Failed" })
			local charEntity = Helpers.makeCharacterEntity({
				_updateResult = false,
				CanMove = false,
				MoveSpeedCap = 0,
				MouseLocked = true,
			})
			local fsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				Id = "Attack_Termination",
				Context = {
					_characterEntity = charEntity,
					_constraintsApplied = true,
					_priorConstraints = {
						CanMove = true,
						MoveSpeedCap = 16,
						MouseLocked = false,
					},
				},
			})

			states.RollbackConstraints.Definition.OnEnter(nil, fsm)

			expect(fsm.Failure).toBeNil()
			expect(fsm.State).toEqual("ReleaseCombatLock")
			expect(hasWarn(fsm.Logs, "attack constraint rollback")).toBeTruthy()
		end)

		it("BlockJob broadcast states warn instead of failing when UpdateEntity returns false", function()
			local job, states = loadJob("BlockJob")
			expect(job.terminalStates).toEqual({ "Completed", "Failed" })
			local charEntity = Helpers.makeCharacterEntity({
				_updateResult = false,
				MoveSpeedCap = 0,
			})
			local fsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				CharacterEntity = charEntity,
				CharacterEntityId = "Char_Block",
			})

			states.BroadcastBlockUpdate.Definition.OnEnter(nil, fsm)
			expect(fsm.Failure).toBeNil()
			expect(fsm.State).toEqual("EmitBlockIntent")
			expect(hasWarn(fsm.Logs, "block broadcast")).toBeTruthy()

			fsm.State = nil
			table.clear(fsm.Logs)
			states.BroadcastUnblockUpdate.Definition.OnEnter(nil, fsm)
			expect(fsm.Failure).toBeNil()
			expect(fsm.State).toEqual("Completed")
			expect(hasWarn(fsm.Logs, "unblock broadcast")).toBeTruthy()
		end)

		it("MovementConstraintJob apply patch warns instead of failing when UpdateEntity returns false", function()
			local job, states = loadJob("MovementConstraintJob")
			expect(job.terminalStates).toEqual({ "Completed", "Failed" })
			local charEntity = Helpers.makeCharacterEntity({ _updateResult = false })
			local fsm = Helpers.makeFSM(Helpers.makeOrchestrator(), {
				CharacterEntity = charEntity,
				CanMove = false,
				MoveSpeedCap = 0,
				MouseLocked = true,
			})

			states.ApplyPatch.Definition.OnEnter(nil, fsm)

			expect(fsm.Failure).toBeNil()
			expect(fsm.State).toEqual("WaitDuration")
			expect(hasWarn(fsm.Logs, "movement constraint apply")).toBeTruthy()
		end)
	end)
end

TR.register(spec)
return spec
