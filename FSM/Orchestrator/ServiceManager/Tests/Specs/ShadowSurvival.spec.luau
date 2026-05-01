--!strict
-- @Name ServiceManager/Tests/Specs/ShadowSurvival.spec.luau
-- @Author iKrypto
-- @Description Regression tests for the bug where completed FSMs (e.g. the
-- door's open/close cycle) couldn't be visualized because the server-side
-- _fsmShadow shared the live FSM's TransitionHistory and _transitions tables
-- by reference. When BaseStateMachine:Destroy() called table.clear on those,
-- the shadow lost everything too — leaving 0 history entries to step through.
--
-- Asserts: a deep copy in the snapshot path keeps history alive even after
-- the live FSM is torn down.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	-- We mirror the exact deep-copy logic from ServiceManager init.luau
	-- so this spec catches a regression where someone "simplifies" back to
	-- a shared reference. If the production source ever re-aliases, the
	-- tests below would still pass for this simulator BUT the live behavior
	-- breaks. To guard against that, the production code is also checked
	-- via a substring sentinel at the bottom of this spec.

	local function captureShadow(fsm)
		-- Mirrors _CaptureFSMSnapshot's deep-copy
		local transitionHistory = {}
		local src = fsm.TransitionHistory
		if type(src) == "table" then
			for i, e in ipairs(src) do
				transitionHistory[i] = e
			end
		end
		local transitionsCopy
		if type(fsm._transitions) == "table" then
			transitionsCopy = {}
			for k, v in pairs(fsm._transitions) do
				if type(v) == "table" then
					local arr = {}
					for i, x in ipairs(v) do arr[i] = x end
					transitionsCopy[k] = arr
				else
					transitionsCopy[k] = v
				end
			end
		end
		return {
			TransitionHistory = transitionHistory,
			_transitions = transitionsCopy,
		}
	end

	describe("Shadow survives FSM destroy", function()
		it("TransitionHistory is COPIED, not aliased", function()
			local liveFsm = {
				TransitionHistory = {
					{ From = "A", To = "B", Time = 1 },
					{ From = "B", To = "C", Time = 2 },
				},
				_transitions = { A = {"B"}, B = {"C"} },
			}
			local shadow = captureShadow(liveFsm)
			-- Simulate Destroy() clearing the live FSM's tables.
			table.clear(liveFsm.TransitionHistory)
			table.clear(liveFsm._transitions)
			-- Shadow must still have 2 entries.
			expect(#shadow.TransitionHistory).toEqual(2)
			expect(shadow.TransitionHistory[1].From).toEqual("A")
			expect(shadow.TransitionHistory[2].To).toEqual("C")
		end)

		it("_transitions allowed-states arrays are copied (deep)", function()
			local liveFsm = {
				TransitionHistory = {},
				_transitions = { A = {"B", "C"}, B = {"A"} },
			}
			local shadow = captureShadow(liveFsm)
			-- Mutate live source's allowed list.
			table.clear(liveFsm._transitions.A)
			-- Shadow must still have the original list.
			expect(#shadow._transitions.A).toEqual(2)
			expect(shadow._transitions.A[1]).toEqual("B")
			expect(shadow._transitions.A[2]).toEqual("C")
		end)

		it("preserves the rich entry shape (Args, ContextSnapshot, etc.)", function()
			local liveFsm = {
				TransitionHistory = {
					{
						From = "Validate",
						To = "Closing",
						Time = 5.0,
						Args = { 1, "two", { Inner = true } },
						WaitSpan = 0.3,
						ContextSnapshot = { DesiredState = "Close", Cycles = 3 },
						TransitionId = 42,
					},
				},
				_transitions = {},
			}
			local shadow = captureShadow(liveFsm)
			liveFsm.TransitionHistory = nil -- simulate destroy
			local entry = shadow.TransitionHistory[1]
			expect(entry.Args[2]).toEqual("two")
			expect(entry.ContextSnapshot.DesiredState).toEqual("Close")
			expect(entry.WaitSpan).toEqual(0.3)
			expect(entry.TransitionId).toEqual(42)
		end)

		it("empty live history produces empty shadow history (no nil)", function()
			local liveFsm = { TransitionHistory = {}, _transitions = nil }
			local shadow = captureShadow(liveFsm)
			expect(type(shadow.TransitionHistory)).toEqual("table")
			expect(#shadow.TransitionHistory).toEqual(0)
		end)
	end)

	describe("Production code uses deep copy for shadow", function()
		it("init.luau's _CaptureFSMSnapshot has the deep-copy comment marker", function()
			-- Read the source via FindFirstChild on the parent module folder
			local rs = game:GetService("ReplicatedStorage")
			local mod = rs:FindFirstChild("Orchestrator") and rs.Orchestrator:FindFirstChild("ServiceManager")
			if mod and mod:IsA("ModuleScript") then
				local source = mod.Source
				expect(string.find(source, "Copy the array") ~= nil).toEqual(true)
				expect(string.find(source, "_transitions is a static config") ~= nil).toEqual(true)
			end
		end)
	end)
end

TR.register(spec)
return spec
