--!strict
-- @Name ServiceManager/Tests/Specs/Chaos.spec.luau
-- @Author iKrypto
-- @Description Seeded stress + chaos tests with invariant assertions.
-- These tests exercise navigation, mass-data churn, FSM thrashing and
-- assert structural invariants survive abuse.

local TR = require(script.Parent.Parent.TestRunner)
local MockNexus = require(script.Parent.Parent.Mocks.MockNexus)
local MockOrchestrator = require(script.Parent.Parent.Mocks.MockOrchestrator)
local AnalyticsEngine = require(script.Parent.Parent.Parent.AnalyticsEngine)
local TasksModule = require(script.Parent.Parent.Parent.Subsystems.TasksModule)
local FSMModule = require(script.Parent.Parent.Parent.Subsystems.FSMModule)
local EntityModule = require(script.Parent.Parent.Parent.Subsystems.EntityModule)
local LogsModule = require(script.Parent.Parent.Parent.Subsystems.LogsModule)
local ConsoleModule = require(script.Parent.Parent.Parent.Subsystems.ConsoleModule)
local ReactiveStore = require(script.Parent.Parent.Parent.ReactiveStore)
local ConnectionBag = require(script.Parent.Parent.Parent.ConnectionBag)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	-- Seeded RNG so chaos is reproducible
	local function makeRng(seed: number)
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	describe("Chaos - Mass entity churn", function()
		it("EntityModule survives 1000 entity inserts/sorts", function()
			local mod = EntityModule.new()
			local rng = makeRng(42)
			for i = 1, 1000 do
				mod._entityCache["E" .. i] = {
					ClassName = "Class" .. (math.floor(rng() * 5)),
					IsValid = rng() > 0.1,
					CreatedAt = i,
				}
			end
			local sorted = mod:_GetSorted(mod._entityCache)
			expect(#sorted).toEqual(1000)
			-- Search filter still works on huge sets
			mod._searchText = "E1"
			local filtered = mod:_GetSorted(mod._entityCache)
			-- E1, E10..E19, E100..E199, E1000 — many matches
			expect(#filtered).toBeGreaterThan(100)
		end)

		it("FSMModule sort + filter stable on 500 FSMs", function()
			local mod = FSMModule.new()
			local rng = makeRng(7)
			local source = {}
			for i = 1, 500 do
				source["F" .. i] = {
					CurrentState = "S" .. math.floor(rng() * 8),
					Transitions = math.floor(rng() * 100),
					Priority = math.floor(rng() * 5) + 1,
				}
			end
			mod._sortMode = "Transitions"
			local sorted = mod:_GetSortedFiltered(source)
			expect(#sorted).toEqual(500)
			-- Verify sort order
			for i = 2, math.min(#sorted, 100) do
				expect(sorted[i - 1].Data.Transitions >= sorted[i].Data.Transitions).toBeTruthy()
			end
		end)
	end)

	describe("Chaos - AnalyticsEngine multi-cycle stability", function()
		it("100 cycles do not produce duplicate insights", function()
			local fsms = {
				A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }),
				B = MockOrchestrator.makeFSM("B", { stateDuration = 60 }),
			}
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			for _ = 1, 100 do nexus._analyticsEngine:RunCycle(nexus) end
			local active = nexus._analyticsEngine:GetActiveInsights()
			-- Count fsm_stall insights — should still be exactly 2
			local stallCount = 0
			for _, ins in ipairs(active) do
				if ins.Id:find("fsm_stall_") then stallCount += 1 end
			end
			expect(stallCount).toEqual(2)
			-- RepeatCount escalates
			local insA = nexus._analyticsEngine:GetInsight("fsm_stall_A")
			expect((insA :: any).RepeatCount).toEqual(100)
		end)

		it("dismissed insights stay dismissed across 50 cycles", function()
			local fsms = { A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }) }
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			nexus._analyticsEngine:RunCycle(nexus)
			nexus._analyticsEngine:DismissInsight("fsm_stall_A")
			for _ = 1, 50 do nexus._analyticsEngine:RunCycle(nexus) end
			local active = nexus._analyticsEngine:GetActiveInsights()
			for _, ins in ipairs(active) do
				expect(ins.Id).never.toEqual("fsm_stall_A")
			end
		end)

		it("changing FSM state mid-stream removes stale insights", function()
			local fsms = { A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }) }
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ fsms = fsms }) })
			nexus._analyticsEngine:RunCycle(nexus)
			-- "Resolve" the stall by reducing duration
			fsms.A.StateDuration = 1
			-- Simulate aging: pretend 11 seconds have passed by reaching into _insights
			local engine = nexus._analyticsEngine
			engine._insights["fsm_stall_A"].Timestamp = os.clock() - 11
			engine:RunCycle(nexus)
			local stale = engine:GetInsight("fsm_stall_A")
			expect(stale).toBeNil()
		end)
	end)

	describe("Chaos - LogsModule extreme volume", function()
		it("filters 5000-log buffer in <100ms", function()
			local mod = LogsModule.new()
			for i = 1, 5000 do
				table.insert(mod._logCache, {
					Level = if i % 4 == 0 then "ERROR" else "INFO",
					Message = "log entry " .. i,
					Timestamp = i,
				})
			end
			mod._activeFilter = "ERROR"
			local start = os.clock()
			mod:_ApplyFilters()
			local elapsedMs = (os.clock() - start) * 1000
			expect(elapsedMs).toBeLessThan(100)
			-- Output respects display cap
			expect(#mod._filteredLogs).toBeLessThan(201)
		end)
	end)

	describe("Chaos - ConnectionBag rapid add/dispose", function()
		it("rapid add/dispose cycle produces no leaks", function()
			local bag = ConnectionBag.new()
			for cycle = 1, 100 do
				for j = 1, 50 do
					bag:Add({ Disconnect = function() end })
				end
				expect(bag:Count()).toEqual(50)
				bag:DisconnectAll()
				expect(bag:Count()).toEqual(0)
			end
		end)
	end)

	describe("Chaos - ReactiveStore subscriber storm", function()
		it("100 subscribers receive all batched updates", function()
			local store = ReactiveStore.new({})
			local fired = 0
			for _ = 1, 100 do
				store:Subscribe("key", function() fired += 1 end)
			end
			store:BatchUpdate(function()
				store:Set("key", 1)
			end)
			task.wait()
			expect(fired).toEqual(100)
		end)
	end)

	describe("Chaos - Console rapid command storm", function()
		it("executes 200 commands without crash", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			for i = 1, 200 do
				mod:ExecuteCommand("help", nexus)
			end
			-- Output buffer respects cap
			expect(#mod._outputBuffer).toBeLessThan(501)
			-- History buffer respects cap
			expect(#mod._commandHistory).toBeLessThan(101)
		end)
	end)

	describe("Invariants - structural assertions", function()
		it("sorted/filtered tasks produce no duplicate names", function()
			local mod = TasksModule.new()
			for i = 1, 100 do
				mod._taskCache["Task" .. i] = { Name = "Task" .. i, Priority = i % 5 }
			end
			local sorted = mod:_GetSortedFilteredTasks()
			local seen = {}
			for _, item in ipairs(sorted) do
				expect(seen[item.Name]).toBeNil()
				seen[item.Name] = true
			end
		end)

		it("AnalyticsEngine never produces nil insights", function()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({
					fsms = { A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }) },
					tasks = { Slow = MockOrchestrator.makeTask("Slow", { avgMs = 12 }) },
				}),
			})
			nexus._analyticsEngine:RunCycle(nexus)
			local active = nexus._analyticsEngine:GetActiveInsights()
			for _, ins in ipairs(active) do
				expect(ins).never.toBeNil()
				expect(ins.Id).never.toBeNil()
				expect(ins.Severity).never.toBeNil()
				expect(ins.Subsystem).never.toBeNil()
				expect(ins.Title).never.toBeNil()
			end
		end)

		it("Analytics severity is always one of CRITICAL/WARNING/INFO/SUGGESTION", function()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({
					fsms = {
						A = MockOrchestrator.makeFSM("A", { stateDuration = 60 }),
						F = MockOrchestrator.makeFSM("F", { hasFailed = true }),
					},
					tasks = { Slow = MockOrchestrator.makeTask("Slow", { avgMs = 12 }) },
				}),
				fps = 12,
			})
			nexus._analyticsEngine:RunCycle(nexus)
			local active = nexus._analyticsEngine:GetActiveInsights()
			local valid = { CRITICAL = true, WARNING = true, INFO = true, SUGGESTION = true }
			for _, ins in ipairs(active) do
				expect(valid[ins.Severity]).toBeTruthy()
			end
		end)
	end)
end

TR.register(spec)
return spec
