--!strict
-- @Name ServiceManager/Tests/Specs/AnalyticsEngine.spec.luau
-- @Author iKrypto

local TR = require(script.Parent.Parent.TestRunner)
local MockNexus = require(script.Parent.Parent.Mocks.MockNexus)
local MockOrchestrator = require(script.Parent.Parent.Mocks.MockOrchestrator)
local AnalyticsEngine = require(script.Parent.Parent.Parent.AnalyticsEngine)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("AnalyticsEngine", function()
	describe("Multi-emit", function()
		it("emits one insight per stalled FSM", function()
			local fsms = {
				A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }),
				B = MockOrchestrator.makeFSM("B", { stateDuration = 50 }),
				C = MockOrchestrator.makeFSM("C", { stateDuration = 5 }),
			}
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ fsms = fsms }),
			})
			nexus._analyticsEngine:RunCycle(nexus)
			local insights = nexus._analyticsEngine:GetActiveInsights()
			local stallCount = 0
			for _, ins in ipairs(insights) do
				if ins.Id:find("fsm_stall_") then stallCount += 1 end
			end
			expect(stallCount).toEqual(2) -- A and B, not C
		end)

		it("emits one insight per slow task", function()
			local tasks = {
				Slow1 = MockOrchestrator.makeTask("Slow1", { avgMs = 10 }),
				Slow2 = MockOrchestrator.makeTask("Slow2", { avgMs = 12 }),
				Fast  = MockOrchestrator.makeTask("Fast", { avgMs = 1 }),
			}
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ tasks = tasks }),
			})
			nexus._analyticsEngine:RunCycle(nexus)
			local insights = nexus._analyticsEngine:GetActiveInsights()
			local bottleneckCount = 0
			for _, ins in ipairs(insights) do
				if ins.Id:find("task_bottleneck_") then bottleneckCount += 1 end
			end
			expect(bottleneckCount).toEqual(2)
		end)

		it("emits one insight per orphan event bus", function()
			local buses = {
				Orphan1 = MockOrchestrator.makeBus({ subscribers = 0 }),
				Orphan2 = MockOrchestrator.makeBus({ subscribers = 0 }),
				Active  = MockOrchestrator.makeBus({ subscribers = 3 }),
			}
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ buses = buses }),
			})
			nexus._analyticsEngine:RunCycle(nexus)
			local insights = nexus._analyticsEngine:GetActiveInsights()
			local orphanCount = 0
			for _, ins in ipairs(insights) do
				if ins.Id:find("orphan_bus_") then orphanCount += 1 end
			end
			expect(orphanCount).toEqual(2)
		end)
	end)

	describe("Insight lifecycle", function()
		it("preserves dismissed state across cycles", function()
			local fsms = { A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }) }
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			nexus._analyticsEngine:RunCycle(nexus)
			nexus._analyticsEngine:DismissInsight("fsm_stall_A")
			-- Re-run, should still be dismissed
			nexus._analyticsEngine:RunCycle(nexus)
			local active = nexus._analyticsEngine:GetActiveInsights()
			for _, ins in ipairs(active) do
				expect(ins.Id).never.toEqual("fsm_stall_A")
			end
		end)

		it("snoozes insights for the given duration", function()
			local fsms = { A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }) }
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			nexus._analyticsEngine:RunCycle(nexus)
			nexus._analyticsEngine:SnoozeInsight("fsm_stall_A", 60)
			nexus._analyticsEngine:RunCycle(nexus)
			local active = nexus._analyticsEngine:GetActiveInsights()
			for _, ins in ipairs(active) do
				expect(ins.Id).never.toEqual("fsm_stall_A")
			end
			-- Snoozed insight is still in registry
			local snoozed = nexus._analyticsEngine:GetInsight("fsm_stall_A")
			expect(snoozed).never.toBeNil()
			expect((snoozed :: any).Snoozed).toBeTruthy()
		end)

		it("increments RepeatCount on repeated emissions", function()
			local fsms = { A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }) }
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			nexus._analyticsEngine:RunCycle(nexus)
			nexus._analyticsEngine:RunCycle(nexus)
			nexus._analyticsEngine:RunCycle(nexus)
			local ins = nexus._analyticsEngine:GetInsight("fsm_stall_A")
			expect((ins :: any).RepeatCount).toEqual(3)
		end)

		it("escalates severity from WARNING to CRITICAL after 10 repeats", function()
			local fsms = { A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }) }
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			for _ = 1, 10 do nexus._analyticsEngine:RunCycle(nexus) end
			local ins = nexus._analyticsEngine:GetInsight("fsm_stall_A")
			expect((ins :: any).Severity).toEqual("CRITICAL")
		end)
	end)

	describe("Sorting", function()
		it("sorts CRITICAL before WARNING before INFO before SUGGESTION", function()
			local fsms = {
				StallA = MockOrchestrator.makeFSM("StallA", { stateDuration = 60 }),
			}
			local tasks = {
				BotA = MockOrchestrator.makeTask("BotA", { avgMs = 12 }),
			}
			local buses = {
				OrphA = MockOrchestrator.makeBus({ subscribers = 0 }),
			}
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ fsms = fsms, tasks = tasks, buses = buses }),
			})
			nexus._analyticsEngine:RunCycle(nexus)
			local active = nexus._analyticsEngine:GetActiveInsights()
			-- First should be CRITICAL (task bottleneck)
			expect(active[1].Severity).toEqual("CRITICAL")
		end)
	end)

	describe("ActionableHints", function()
		it("attaches actionable hints with command strings to insights", function()
			local fsms = { A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }) }
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			nexus._analyticsEngine:RunCycle(nexus)
			local ins = nexus._analyticsEngine:GetInsight("fsm_stall_A")
			expect((ins :: any).ActionableHints).never.toBeNil()
			expect(#(ins :: any).ActionableHints).toBeGreaterThan(0)
			local first = (ins :: any).ActionableHints[1]
			expect(first.Label).never.toBeNil()
			expect(first.Command).toContain("fsm cancel")
		end)
	end)

	describe("New rules", function()
		it("Rule 7: detects failed FSMs", function()
			local fsms = {
				Failed = MockOrchestrator.makeFSM("Failed", { hasFailed = true }),
				Good = MockOrchestrator.makeFSM("Good", { hasFailed = false }),
			}
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			nexus._analyticsEngine:RunCycle(nexus)
			local ins = nexus._analyticsEngine:GetInsight("fsm_failed_Failed")
			expect(ins).never.toBeNil()
		end)

		it("Rule 8: detects empty scheduler", function()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ tasks = {} }),
			})
			nexus._analyticsEngine:RunCycle(nexus)
			local ins = nexus._analyticsEngine:GetInsight("scheduler_no_tasks")
			expect(ins).never.toBeNil()
		end)

		it("Rule 8: does NOT fire when at least one task is registered", function()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({
					tasks = { A = MockOrchestrator.makeTask("A") },
				}),
			})
			nexus._analyticsEngine:RunCycle(nexus)
			local ins = nexus._analyticsEngine:GetInsight("scheduler_no_tasks")
			expect(ins).toBeNil()
		end)

		it("Rule 10: detects FPS degradation", function()
			local nexus = MockNexus.new({ fps = 12 })
			nexus._analyticsEngine:RunCycle(nexus)
			local ins = nexus._analyticsEngine:GetInsight("fps_degraded")
			expect(ins).never.toBeNil()
			expect((ins :: any).Severity).toEqual("CRITICAL")
		end)
	end)

	describe("Rule count", function()
		it("registers all 10 builtin rules", function()
			local engine = AnalyticsEngine.new()
			expect(engine:GetRuleCount()).toEqual(10)
		end)
	end)
end)

end -- close spec function

TR.register(spec)
return spec
