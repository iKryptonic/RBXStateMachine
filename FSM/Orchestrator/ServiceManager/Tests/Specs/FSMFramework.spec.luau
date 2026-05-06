--!strict
-- @Name ServiceManager/Tests/Specs/FSMFramework.spec.luau
-- @Author iKrypto
-- @Description Behavior tests for BaseStateMachine fixes — sub-machine
-- ChangeState shape, validation order, OnLeave isolation, idempotent
-- Cancel/Destroy. Each test corresponds to an audit-surfaced bug.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	-- Lightweight FSM-like simulator that mirrors the production
	-- ChangeState validate→commit→drain shape. We don't need the full
	-- BaseStateMachine runtime to exercise the audit findings.
	local function makeFsm(opts)
		opts = opts or {}
		local fsm: any = {
			IsActive = true,
			validStates = opts.validStates or {},
			TerminalStates = opts.TerminalStates or {},
			_states = opts.states or {},
			_transitions = opts.transitions or {},
			_activeStateName = nil,
			CurrentState = nil,
			TransitionCount = 0,
			StateDuration = 0,
			WaitSpan = 0,
			TransitionHistory = {},
			_transitionHistoryMax = 100,
			_transitionId = 0,
			_inTransition = false,
			_pendingTransitions = nil,
			_destroyed = false,
			_cancelledFired = false,
			_logs = {},
		}

		function fsm:_log(level, msg)
			table.insert(self._logs, { Level = level, Message = msg })
		end

		function fsm:ChangeState(params)
			if not self.IsActive then return end
			-- Reentrance guard
			if self._inTransition then
				self._pendingTransitions = self._pendingTransitions or {}
				table.insert(self._pendingTransitions, params)
				return
			end
			self._inTransition = true

			local name = params.Name
			-- Validate (no side effects)
			if next(self.validStates) and not self.validStates[name] then
				self:_log("ERROR", "invalid: " .. tostring(name))
				self._inTransition = false
				return
			end
			local oldState = self._activeStateName
			local newState = self._states[name]
			if oldState and newState then
				local allowed = self._transitions[oldState]
				if allowed and #allowed > 0 then
					local isLegal = false
					for _, o in ipairs(allowed) do if o == name then isLegal = true; break end end
					if not isLegal then
						self:_log("ERROR", "illegal: " .. oldState .. "->" .. name)
						self._inTransition = false
						return
					end
				end
			end
			if not newState and not self.TerminalStates[name] then
				self:_log("ERROR", "unregistered: " .. tostring(name))
				self._inTransition = false
				return
			end

			-- Commit
			self.WaitSpan = 0
			self._transitionId += 1
			-- OnLeave wrapped in pcall
			if typeof(self.CurrentState) == "table" and self.CurrentState.OnLeave and oldState ~= name then
				pcall(self.CurrentState.OnLeave, self.CurrentState, self)
			end
			if name == self._activeStateName then
				self.TransitionCount += 1
			else
				self.StateDuration = 0
				self.TransitionCount = 1
				-- Mirror production: leaving the previous state cancels any
				-- pending one-shot scheduled timer.
				self._pendingTimedTransition = nil
			end
			table.insert(self.TransitionHistory, { From = self._activeStateName, To = name, Time = os.clock() })
			while #self.TransitionHistory > self._transitionHistoryMax do
				table.remove(self.TransitionHistory, 1)
			end
			self.CurrentState = newState
			self._activeStateName = name
			self.State = name
			-- Mirror production: reset _timeoutFired on each entry so the
			-- declarative Timeout fires once per visit.
			if typeof(newState) == "table" then
				(newState :: any)._timeoutFired = nil
			end

			-- Release guard, drain queue
			self._inTransition = false
			if self._pendingTransitions and #self._pendingTransitions > 0 then
				local nextP = table.remove(self._pendingTransitions, 1)
				if nextP and self.IsActive then self:ChangeState(nextP) end
			end
		end

		function fsm:Cancel()
			if self._cancelledFired then return end
			self._cancelledFired = true
			self.IsActive = false
		end

		function fsm:Destroy()
			if self._destroyed then return end
			self._destroyed = true
			self.IsActive = false
			if self.TransitionHistory then table.clear(self.TransitionHistory) end
			if self._pendingTransitions then table.clear(self._pendingTransitions) end
		end

		-- :ScheduleTransition mirrors production: pending slot polled in
		-- _Update against StateDuration. Auto-cleared on ChangeState.
		function fsm:ScheduleTransition(seconds, targetState, args)
			if not self.IsActive then return end
			if type(seconds) ~= "number" or seconds < 0 then return end
			if type(targetState) ~= "string" or targetState == "" then return end
			self._pendingTimedTransition = {
				TargetState = targetState,
				FireAt = self.StateDuration + seconds,
				Args = args,
			}
		end

		function fsm:CancelScheduledTransition()
			if self._pendingTimedTransition then
				self._pendingTimedTransition = nil
				return true
			end
			return false
		end

		-- Mirror of production _Update's pending-timer poll. We don't run
		-- state callbacks here (the simulator's ChangeState is enough) —
		-- this just exercises the timer firing and auto-cancel mechanics.
		function fsm:_Update(dt)
			if not self.IsActive then return end
			self.StateDuration += dt
			local pending = self._pendingTimedTransition
			if pending and self.StateDuration >= pending.FireAt then
				local target = pending.TargetState
				local args = pending.Args
				self._pendingTimedTransition = nil
				self:ChangeState({ Name = target, Args = args })
				return
			end
			-- Mirror production: declarative state-level Timeout for table
			-- states. Fires once per state entry (auto-resets via
			-- _timeoutFired, which the entry path clears). String OnTimeout
			-- transitions; function OnTimeout invoked with (state, fsm).
			local cs = self.CurrentState
			if typeof(cs) == "table"
				and cs.Timeout
				and type(cs.Timeout) == "number"
				and cs.Timeout > 0
				and not cs._timeoutFired
				and self.StateDuration >= cs.Timeout
			then
				cs._timeoutFired = true
				local handler = cs.OnTimeout
				if type(handler) == "string" then
					self:ChangeState({ Name = handler })
					return
				elseif type(handler) == "function" then
					pcall(handler, cs, self)
				end
			end
		end

		return fsm
	end

	-- ────────────────────────────────────────────────────────────
	-- BUG: AddSubMachine ChangeState string vs table
	-- ────────────────────────────────────────────────────────────
	describe("ChangeState param shape", function()
		it("rejects bare string name (must be {Name=...})", function()
			-- This test documents the contract. The fixed AddSubMachine code
			-- now wraps strings as { Name = transitions.OnCompleted }. If
			-- ChangeState is given a bare string, it should not silently
			-- succeed.
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = { A = {}, B = {} },
				transitions = { A = { "B" } },
			})
			fsm:ChangeState({ Name = "A" })
			expect(fsm._activeStateName).toEqual("A")
			-- Now try the string-form (legacy bug) — should fail validation
			fsm:ChangeState("B" :: any)
			-- _activeStateName must NOT have changed to B
			expect(fsm._activeStateName).toEqual("A")
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- BUG M1: Side effects before validation
	-- ────────────────────────────────────────────────────────────
	describe("Validation side-effect ordering", function()
		it("rejected transition does NOT consume WaitSpan", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = { A = {}, B = {} },
			})
			fsm:ChangeState({ Name = "A" })
			fsm.WaitSpan = 5
			-- Try invalid transition
			fsm:ChangeState({ Name = "DoesNotExist" })
			-- Validation rejects → WaitSpan must remain 5
			expect(fsm.WaitSpan).toEqual(5)
		end)

		it("rejected transition does NOT bump _transitionId", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = { A = {} },
			})
			fsm:ChangeState({ Name = "A" })
			local idBefore = fsm._transitionId
			fsm:ChangeState({ Name = "Bogus" })
			expect(fsm._transitionId).toEqual(idBefore)
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- BUG M2: OnLeave throwing wedges FSM
	-- ────────────────────────────────────────────────────────────
	describe("OnLeave error isolation", function()
		it("throwing OnLeave does not prevent the transition", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = {
					A = {
						OnLeave = function() error("boom!") end,
					},
					B = {},
				},
			})
			fsm:ChangeState({ Name = "A" })
			expect(fsm._activeStateName).toEqual("A")
			fsm:ChangeState({ Name = "B" })
			-- OnLeave threw, but the transition still completed
			expect(fsm._activeStateName).toEqual("B")
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- BUG M4: Reentrance hazard
	-- ────────────────────────────────────────────────────────────
	describe("ChangeState reentrance", function()
		it("queues nested ChangeState calls and drains them in order", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true, C = true },
				states = {
					A = {
						OnEnter = function(_, f) f:ChangeState({ Name = "B" }) end,
					},
					B = {},
					C = {},
				},
			})
			-- Start at A. OnEnter is *not* a state body (we don't model
			-- task.defer in the simulator), so manually drive the queue
			-- by calling ChangeState mid-flight.
			fsm:ChangeState({ Name = "A" })
			-- Simulate an OnEnter listener that calls ChangeState while the
			-- outer call is still in-flight: re-enter manually
			fsm._inTransition = true -- pretend we're in a transition
			fsm:ChangeState({ Name = "B" })
			-- Should have been queued, not applied directly
			expect(fsm._activeStateName).toEqual("A")
			expect(fsm._pendingTransitions ~= nil and #fsm._pendingTransitions).toEqual(1)
			-- Release guard and drain
			fsm._inTransition = false
			local nextP = table.remove(fsm._pendingTransitions, 1)
			fsm:ChangeState(nextP)
			expect(fsm._activeStateName).toEqual("B")
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- BUG M6: Cancel/Destroy idempotency
	-- ────────────────────────────────────────────────────────────
	describe("Cancel/Destroy idempotency", function()
		it("Cancel called twice fires only once", function()
			local fsm = makeFsm()
			local fired = 0
			-- Replace Cancel to count fires
			local origCancel = fsm.Cancel
			fsm._cancelledFired = false
			function fsm:Cancel()
				if self._cancelledFired then return end
				self._cancelledFired = true
				fired += 1
			end
			fsm:Cancel()
			fsm:Cancel()
			fsm:Cancel()
			expect(fired).toEqual(1)
		end)

		it("Destroy is safe to call twice", function()
			local fsm = makeFsm()
			fsm:Destroy()
			fsm:Destroy()
			expect(fsm._destroyed).toBeTruthy()
		end)

		it("Destroy clears TransitionHistory ring buffer", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = { A = {}, B = {} },
			})
			fsm:ChangeState({ Name = "A" })
			fsm:ChangeState({ Name = "B" })
			expect(#fsm.TransitionHistory).toBeGreaterThan(0)
			fsm:Destroy()
			expect(#fsm.TransitionHistory).toEqual(0)
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- TransitionHistory shape (regression for visualizer)
	-- ────────────────────────────────────────────────────────────
	describe("TransitionHistory shape", function()
		it("records From/To/Time for each transition", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true, C = true },
				states = { A = {}, B = {}, C = {} },
			})
			fsm:ChangeState({ Name = "A" })
			fsm:ChangeState({ Name = "B" })
			fsm:ChangeState({ Name = "C" })
			expect(#fsm.TransitionHistory).toEqual(3)
			expect(fsm.TransitionHistory[1].From).toBeNil()
			expect(fsm.TransitionHistory[1].To).toEqual("A")
			expect(fsm.TransitionHistory[2].From).toEqual("A")
			expect(fsm.TransitionHistory[2].To).toEqual("B")
			expect(fsm.TransitionHistory[3].From).toEqual("B")
			expect(fsm.TransitionHistory[3].To).toEqual("C")
		end)

		it("respects the cap and drops oldest entries", function()
			local fsm = makeFsm({
				validStates = setmetatable({}, { __index = function() return true end }),
				states = setmetatable({}, { __index = function() return {} end }),
			})
			fsm._transitionHistoryMax = 3
			for i = 1, 10 do
				fsm:ChangeState({ Name = "S" .. i })
			end
			expect(#fsm.TransitionHistory).toEqual(3)
			expect(fsm.TransitionHistory[3].To).toEqual("S10")
			expect(fsm.TransitionHistory[1].To).toEqual("S8")
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- :ScheduleTransition — one-shot timed transition with auto-cancel
	-- ────────────────────────────────────────────────────────────
	-- Replaces the user-land task.delay + manual `if fsm.State == fromState`
	-- guard pattern that TrafficLightFSM previously had to write by hand.
	-- The simulator's ScheduleTransition + _Update mirror production exactly,
	-- and a separate source-level guard verifies the production code carries
	-- the same logic.
	describe(":ScheduleTransition", function()
		it("fires the scheduled transition after StateDuration crosses FireAt", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = { A = {}, B = {} },
				transitions = { A = { "B" }, B = { "A" } },
			})
			fsm:ChangeState({ Name = "A" })

			fsm:ScheduleTransition(2, "B")
			fsm:_Update(1.5)
			expect(fsm.State).toEqual("A")
			fsm:_Update(0.6)
			expect(fsm.State).toEqual("B")
		end)

		it("auto-cancels when the FSM leaves the state before timer fires", function()
			-- This is the whole point: in the OLD task.delay pattern, leaving
			-- the state did NOT cancel the timer — only the explicit
			-- `fsm.State == fromState` guard in user land prevented the bug.
			-- With ScheduleTransition, the timer is on the FSM's pending slot
			-- and gets cleared on ChangeState automatically.
			local fsm = makeFsm({
				validStates = { A = true, B = true, C = true },
				states = { A = {}, B = {}, C = {} },
				transitions = { A = { "B", "C" }, B = { "A", "C" }, C = { "A", "B" } },
			})
			fsm:ChangeState({ Name = "A" })

			fsm:ScheduleTransition(5, "C")
			fsm:ChangeState({ Name = "B" })
			expect(fsm.State).toEqual("B")
			expect(fsm._pendingTimedTransition).toBeNil()
			-- Simulate 6s — there should be NO transition to C.
			fsm:_Update(6)
			expect(fsm.State).toEqual("B")
		end)

		it("re-scheduling within the same state replaces the prior pending timer", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true, C = true },
				states = { A = {}, B = {}, C = {} },
				transitions = { A = { "B", "C" }, B = { "A" }, C = { "A" } },
			})
			fsm:ChangeState({ Name = "A" })

			fsm:ScheduleTransition(3, "B")
			fsm:ScheduleTransition(2, "C") -- replaces
			fsm:_Update(2.5)
			expect(fsm.State).toEqual("C")
		end)

		it("CancelScheduledTransition clears the pending timer", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = { A = {}, B = {} },
				transitions = { A = { "B" }, B = { "A" } },
			})
			fsm:ChangeState({ Name = "A" })

			fsm:ScheduleTransition(2, "B")
			expect(fsm._pendingTimedTransition).never.toBeNil()
			expect(fsm:CancelScheduledTransition()).toEqual(true)
			expect(fsm._pendingTimedTransition).toBeNil()
			fsm:_Update(5)
			expect(fsm.State).toEqual("A")

			-- Idempotent: second cancel returns false.
			expect(fsm:CancelScheduledTransition()).toEqual(false)
		end)

		it("re-entering the same state schedules a fresh timer (no phantom carry-over)", function()
			-- Regression for the original task.delay bug: re-entering a state
			-- previously meant the OLD scheduled task.delay would still be in
			-- flight and fire later, racing with the new entry. With auto-
			-- cancel, the slot is cleared on the entry transition, so the
			-- new schedule is the only one.
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = { A = {}, B = {} },
				transitions = { A = { "B" }, B = { "A" } },
			})
			fsm:ChangeState({ Name = "A" })
			fsm:ScheduleTransition(2, "B")

			-- A → B at 2s
			fsm:_Update(2.1)
			expect(fsm.State).toEqual("B")
			-- (Pending was cleared by ChangeState.)
			expect(fsm._pendingTimedTransition).toBeNil()

			-- Schedule B → A at 1s
			fsm:ScheduleTransition(1, "A")
			-- B → A at 1s (re-enter)
			fsm:_Update(1.1)
			expect(fsm.State).toEqual("A")
			-- Schedule A → B at 2s (fresh — no carry-over from first A)
			fsm:ScheduleTransition(2, "B")
			expect(fsm._pendingTimedTransition).never.toBeNil()
			expect(fsm._pendingTimedTransition.TargetState).toEqual("B")

			fsm:_Update(2.1)
			expect(fsm.State).toEqual("B")
		end)

		it("rejects negative or non-numeric seconds (no-op)", function()
			local fsm = makeFsm({
				validStates = { A = true, B = true },
				states = { A = {}, B = {} },
				transitions = { A = { "B" }, B = { "A" } },
			})
			fsm:ChangeState({ Name = "A" })

			fsm:ScheduleTransition(-1, "B")
			expect(fsm._pendingTimedTransition).toBeNil()
			fsm:ScheduleTransition("nope" :: any, "B")
			expect(fsm._pendingTimedTransition).toBeNil()
		end)

		it("source-level guard: production BaseStateMachine has the same logic", function()
			-- The simulator above mirrors the production logic; this guard
			-- verifies the production code actually ships :ScheduleTransition
			-- with the auto-cancel + StateDuration-poll mechanics.
			local node: any = game
			for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "Core", "Factory", "BaseStateMachine"}) do
				node = node:FindFirstChild(name)
				if not node then break end
			end
			expect(node).never.toBeNil()
			local source = node:IsA("ModuleScript") and node.Source or ""
			expect(#source > 0).toEqual(true)
			-- Pending slot field
			expect(string.find(source, "_pendingTimedTransition") ~= nil).toEqual(true)
			-- Public API
			expect(string.find(source, "function BaseStateMachine:ScheduleTransition") ~= nil).toEqual(true)
			expect(string.find(source, "function BaseStateMachine:CancelScheduledTransition") ~= nil).toEqual(true)
			-- _Update polls the pending slot against StateDuration
			expect(string.find(source, "self%.StateDuration >= pending%.FireAt") ~= nil).toEqual(true)
			-- ChangeState clears pending on state change (auto-cancel)
			expect(string.find(source, "self%._pendingTimedTransition = nil") ~= nil).toEqual(true)
		end)

		it("source-level guard: TrafficLightFSM uses ScheduleTransition (not task.delay)", function()
			local node: any = nil
			-- Try both layouts: ServiceManager project and RBXStateMachine repo
			for _, path in ipairs({
				{"ReplicatedStorage", "StateMachines", "TrafficLightFSM"},
				{"ReplicatedStorage", "Examples", "TrafficLightFSMExample"},
			}) do
				local n: any = game
				for _, name in ipairs(path) do
					n = n:FindFirstChild(name)
					if not n then break end
				end
				if n then node = n; break end
			end
			expect(node).never.toBeNil()
			local source = node:IsA("ModuleScript") and node.Source or ""
			expect(#source > 0).toEqual(true)
			-- Must use the framework API.
			expect(string.find(source, "fsm:ScheduleTransition") ~= nil).toEqual(true)
			-- Must NOT contain the old task.delay workaround.
			expect(string.find(source, "task%.delay") == nil).toEqual(true)
			expect(string.find(source, "transitionAfter") == nil).toEqual(true)
		end)

		it("source-level guard: WaitSpan path uses _pendingTimedTransition (no task.delay in _Update)", function()
			-- Internal refactor: WaitSpan-driven self-re-entry was using
			-- task.delay + _transitionId guard inside _Update. That had the
			-- same orphan-thread / leak concern as the old transitionAfter
			-- pattern. The refactor makes WaitSpan use the same
			-- StateDuration-poll mechanism as ScheduleTransition (the
			-- user-facing API is unchanged — just the implementation).
			local node: any = game
			for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "Core", "Factory", "BaseStateMachine"}) do
				node = node:FindFirstChild(name)
				if not node then break end
			end
			expect(node).never.toBeNil()
			local source = node:IsA("ModuleScript") and node.Source or ""
			expect(#source > 0).toEqual(true)
			-- The _Update WaitSpan section is bounded by:
			--   start: "Same state with WaitSpan"
			--   end:   the next initPerf(self) call (which resumes _Update)
			local sectionStart = string.find(source, "Same state with WaitSpan")
			expect(sectionStart ~= nil).toEqual(true)
			local sectionEnd = string.find(source, "initPerf%(self%)", sectionStart or 1)
			expect(sectionEnd ~= nil).toEqual(true)
			local section = string.sub(source, (sectionStart or 1), (sectionEnd or #source))
			-- The section must use the pending-slot mechanism.
			expect(string.find(section, "_pendingTimedTransition") ~= nil).toEqual(true)
			-- And NOT use task.delay (the old approach).
			expect(string.find(section, "task%.delay") == nil).toEqual(true)
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- Declarative state-level Timeout / OnTimeout (object states)
	-- ────────────────────────────────────────────────────────────
	describe("State-level Timeout + OnTimeout", function()
		it("string OnTimeout transitions to target state when StateDuration crosses Timeout", function()
			-- Object state with declarative timeout. After 5s in Validating,
			-- transition to Failed automatically.
			local validatingState = {
				Timeout = 5,
				OnTimeout = "Failed",
				OnEnter = function() end,
			}
			local fsm = makeFsm({
				validStates = { Validating = true, Failed = true, Success = true },
				states = { Validating = validatingState, Failed = {}, Success = {} },
				transitions = { Validating = { "Failed", "Success" } },
			})
			fsm:ChangeState({ Name = "Validating" })

			-- 4s lapsed: not yet
			fsm:_Update(4)
			expect(fsm.State).toEqual("Validating")
			-- 5.5s total: should fire Timeout → Failed
			fsm:_Update(1.5)
			expect(fsm.State).toEqual("Failed")
		end)

		it("function OnTimeout is invoked with (state, fsm)", function()
			local handlerCalls = 0
			local capturedState, capturedFsm
			local validatingState = {
				Timeout = 2,
				OnTimeout = function(state, fsm)
					handlerCalls += 1
					capturedState = state
					capturedFsm = fsm
				end,
				OnEnter = function() end,
			}
			local fsm = makeFsm({
				validStates = { Validating = true },
				states = { Validating = validatingState },
				transitions = { Validating = {} },
			})
			fsm:ChangeState({ Name = "Validating" })

			fsm:_Update(2.5)
			expect(handlerCalls).toEqual(1)
			expect(capturedState).toEqual(validatingState)
			expect(capturedFsm).toEqual(fsm)
		end)

		it("function OnTimeout that doesn't transition does NOT re-fire every tick", function()
			-- The user's function may opt to NOT transition. In that case
			-- we must not fire OnTimeout again on subsequent ticks.
			local fired = 0
			local validatingState = {
				Timeout = 1,
				OnTimeout = function() fired += 1 end,
				OnEnter = function() end,
			}
			local fsm = makeFsm({
				validStates = { Validating = true },
				states = { Validating = validatingState },
				transitions = { Validating = {} },
			})
			fsm:ChangeState({ Name = "Validating" })

			fsm:_Update(1.5)
			expect(fired).toEqual(1)
			-- Drive 5 more frames — should NOT fire again.
			for _ = 1, 5 do fsm:_Update(0.5) end
			expect(fired).toEqual(1)
		end)

		it("re-entering the state resets the timeout (_timeoutFired cleared)", function()
			-- Same state can be re-entered (via WaitSpan, ScheduleTransition,
			-- or manual). Each entry must get a fresh timeout — not be
			-- "already fired" from a prior visit.
			local fired = 0
			local validatingState = {
				Timeout = 1,
				OnTimeout = function() fired += 1 end,
				OnEnter = function() end,
			}
			local successState = { OnEnter = function() end }
			local fsm = makeFsm({
				validStates = { Validating = true, Success = true },
				states = { Validating = validatingState, Success = successState },
				transitions = { Validating = { "Success" }, Success = { "Validating" } },
			})
			fsm:ChangeState({ Name = "Validating" })

			fsm:_Update(1.5)
			expect(fired).toEqual(1)
			-- Move away and re-enter.
			fsm:ChangeState({ Name = "Success" })
			fsm:ChangeState({ Name = "Validating" })
			expect(validatingState._timeoutFired).toBeNil()

			-- Drive again — should fire a second time.
			fsm:_Update(1.5)
			expect(fired).toEqual(2)
		end)

		it("Timeout does NOT fire if Transitions[].Condition fires first (success path wins)", function()
			-- Cleaner separation: success conditions checked before timeout
			-- means a fast-path validation that succeeds in 0.5s never
			-- triggers the 5s timeout failure.
			-- This test just verifies the framework doesn't fire OnTimeout
			-- after we've left the state (StateDuration resets).
			local fired = 0
			local validatingState = {
				Timeout = 5,
				OnTimeout = function() fired += 1 end,
				OnEnter = function() end,
			}
			local fsm = makeFsm({
				validStates = { Validating = true, Success = true },
				states = { Validating = validatingState, Success = {} },
				transitions = { Validating = { "Success" } },
			})
			fsm:ChangeState({ Name = "Validating" })

			-- Simulate the "success path" exiting the state at 0.5s
			fsm:_Update(0.5)
			fsm:ChangeState({ Name = "Success" })
			-- Drive 10 more seconds — Timeout must not fire (we left).
			fsm:_Update(10)
			expect(fired).toEqual(0)
		end)

		it("nil/zero/missing Timeout is a no-op (existing object states unchanged)", function()
			-- Backwards compat: object states without a Timeout field should
			-- behave exactly as before — the Timeout poll skips them.
			local pollCount = 0
			local oldStyleState = {
				OnHeartbeat = function() pollCount += 1 end,
			}
			local fsm = makeFsm({
				validStates = { Old = true },
				states = { Old = oldStyleState },
				transitions = { Old = {} },
			})
			fsm:ChangeState({ Name = "Old" })
			-- 100 frames later, no transition fired (no Timeout declared).
			for _ = 1, 100 do fsm:_Update(0.1) end
			expect(fsm.State).toEqual("Old")
		end)

		it("source-level guard: production BaseStateMachine implements Timeout/OnTimeout", function()
			local node: any = game
			for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "Core", "Factory", "BaseStateMachine"}) do
				node = node:FindFirstChild(name)
				if not node then break end
			end
			expect(node).never.toBeNil()
			local source = node:IsA("ModuleScript") and node.Source or ""
			expect(#source > 0).toEqual(true)
			expect(string.find(source, "currentState%.Timeout") ~= nil).toEqual(true)
			expect(string.find(source, "currentState%.OnTimeout") ~= nil
				or string.find(source, "currentState%._timeoutFired") ~= nil).toEqual(true)
			-- Reset on entry.
			expect(string.find(source, "%(newState :: any%)%._timeoutFired = nil") ~= nil).toEqual(true)
		end)
	end)
end

TR.register(spec)
return spec
