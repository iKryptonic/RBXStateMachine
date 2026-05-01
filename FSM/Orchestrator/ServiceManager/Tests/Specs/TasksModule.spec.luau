--!strict
-- @Name ServiceManager/Tests/Specs/TasksModule.spec.luau
-- @Author iKrypto
-- @Description Filter/sort logic tests for the TASKS subsystem.

local TR = require(script.Parent.Parent.TestRunner)
local MockNexus = require(script.Parent.Parent.Mocks.MockNexus)
local MockOrchestrator = require(script.Parent.Parent.Mocks.MockOrchestrator)
local TasksModule = require(script.Parent.Parent.Parent.Subsystems.TasksModule)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function makeNexusWithTasks(tasks): any
		local orch = MockOrchestrator.new({ tasks = tasks })
		return MockNexus.new({ orchestrator = orch })
	end

	describe("TasksModule", function()
	describe("Status detection (ACTIVE vs IDLE vs RUNNING vs ERROR)", function()
		it("flags a task as ACTIVE when run count increased since last fetch", function()
			local mod = TasksModule.new()
			local taskDef = MockOrchestrator.makeTask("Tick", { recurring = true })
			taskDef.RunCount = 0
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ tasks = { Tick = taskDef } }),
			})
			mod:FetchData(nexus)
			expect(mod._taskCache.Tick.Status).toEqual("idle")
			-- Simulate the task running 5 times between fetches
			taskDef.RunCount = 5
			mod:FetchData(nexus)
			expect(mod._taskCache.Tick.Status).toEqual("active")
		end)

		it("flags a task as IDLE when run count is unchanged for a while", function()
			local mod = TasksModule.new()
			local taskDef = MockOrchestrator.makeTask("Quiet", { recurring = true })
			taskDef.RunCount = 100
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ tasks = { Quiet = taskDef } }),
			})
			mod._lastActiveTime["Quiet"] = os.clock() - 999
			mod._prevRunCounts["Quiet"] = 100
			mod:FetchData(nexus)
			expect(mod._taskCache.Quiet.Status).toEqual("idle")
		end)

		it("flags a task as ERROR when ErrorCount > 0", function()
			local mod = TasksModule.new()
			local taskDef = MockOrchestrator.makeTask("Bad")
			taskDef.RunCount = 5
			taskDef.ErrorCount = 3
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ tasks = { Bad = taskDef } }),
			})
			mod:FetchData(nexus)
			expect(mod._taskCache.Bad.Status).toEqual("error")
			expect(mod._taskCache.Bad.Errors).toEqual(3)
		end)

		it("flags a task as RUNNING when caught mid-execution", function()
			local mod = TasksModule.new()
			local taskDef = MockOrchestrator.makeTask("Live", { recurring = true })
			local orch = MockOrchestrator.new({ tasks = { Live = taskDef } })
			orch.Scheduler._running = { Live = { startTime = os.clock() } }
			local nexus = MockNexus.new({ orchestrator = orch })
			mod:FetchData(nexus)
			expect(mod._taskCache.Live.Status).toEqual("running")
		end)

		it("RUNNING takes precedence over ACTIVE on the same instant", function()
			local mod = TasksModule.new()
			local taskDef = MockOrchestrator.makeTask("BothFlags")
			taskDef.RunCount = 10
			local orch = MockOrchestrator.new({ tasks = { BothFlags = taskDef } })
			orch.Scheduler._running = { BothFlags = { startTime = os.clock() } }
			local nexus = MockNexus.new({ orchestrator = orch })
			mod._lastActiveTime["BothFlags"] = os.clock()
			mod._prevRunCounts["BothFlags"] = 5
			mod:FetchData(nexus)
			expect(mod._taskCache.BothFlags.Status).toEqual("running")
		end)

		it("ERROR takes precedence over RUNNING/ACTIVE", function()
			local mod = TasksModule.new()
			local taskDef = MockOrchestrator.makeTask("BadButRunning")
			taskDef.RunCount = 100
			taskDef.ErrorCount = 1
			local orch = MockOrchestrator.new({ tasks = { BadButRunning = taskDef } })
			orch.Scheduler._running = { BadButRunning = { startTime = os.clock() } }
			local nexus = MockNexus.new({ orchestrator = orch })
			mod:FetchData(nexus)
			expect(mod._taskCache.BadButRunning.Status).toEqual("error")
		end)

		it("removes stale entries from prevRunCounts when task disappears", function()
			local mod = TasksModule.new()
			mod._prevRunCounts["GoneTask"] = 50
			mod._lastActiveTime["GoneTask"] = os.clock()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ tasks = {} }),
			})
			mod:FetchData(nexus)
			expect(mod._prevRunCounts["GoneTask"]).toBeNil()
			expect(mod._lastActiveTime["GoneTask"]).toBeNil()
		end)
	end)

	-- ── Server-context Status detection ─────────────────────────────
	-- Regression: the server-context branch of FetchData was a passthrough
	-- on `taskDef.Status` — but the Scheduler never sets a Status field on
	-- task objects (it only tracks RunCount/TotalRunTime). Result: every
	-- task in server mode showed as IDLE, even the GlobalStateMachineHeartbeat
	-- that fires every frame. The branch must now derive Status the same
	-- way the client branch does (RunCount deltas + ACTIVE_WINDOW).
	describe("Status detection — SERVER context", function()
		it("derives ACTIVE from RunCount delta on server snapshot", function()
			local mod = TasksModule.new()
			-- Snapshot tick 1: task has run 0 times.
			local nexus = MockNexus.new({
				contextMode = "server",
				orchestrator = MockOrchestrator.new({ tasks = {} }),
				serverData = {
					Tasks = {
						List = {
							GlobalStateMachineHeartbeat = {
								Name = "GlobalStateMachineHeartbeat",
								RunCount = 0,
								IsRecurringTask = true,
								Priority = 1,
								Event = "Heartbeat",
							},
						},
						Performance = { FPS = 60, MemoryMB = 0, ActiveTasks = 1 },
					},
				},
			})
			mod:FetchData(nexus)
			expect(mod._taskCache.GlobalStateMachineHeartbeat.Status).toEqual("idle")

			-- Snapshot tick 2: task has run 100 times since.
			nexus._serverData.Tasks.List.GlobalStateMachineHeartbeat.RunCount = 100
			mod:FetchData(nexus)
			expect(mod._taskCache.GlobalStateMachineHeartbeat.Status).toEqual("active")
		end)

		it("derives RUNNING from snapshot's IsRunning flag (server mid-execution)", function()
			local mod = TasksModule.new()
			local nexus = MockNexus.new({
				contextMode = "server",
				orchestrator = MockOrchestrator.new({ tasks = {} }),
				serverData = {
					Tasks = {
						List = {
							LiveTask = {
								Name = "LiveTask",
								RunCount = 5,
								IsRunning = true,
								IsRecurringTask = true,
							},
						},
						Performance = {},
					},
				},
			})
			mod:FetchData(nexus)
			expect(mod._taskCache.LiveTask.Status).toEqual("running")
		end)

		it("derives ERROR from snapshot's Errors count (server)", function()
			local mod = TasksModule.new()
			local nexus = MockNexus.new({
				contextMode = "server",
				orchestrator = MockOrchestrator.new({ tasks = {} }),
				serverData = {
					Tasks = {
						List = {
							BadTask = {
								Name = "BadTask",
								RunCount = 5,
								Errors = 3,
							},
						},
						Performance = {},
					},
				},
			})
			mod:FetchData(nexus)
			expect(mod._taskCache.BadTask.Status).toEqual("error")
			expect(mod._taskCache.BadTask.Errors).toEqual(3)
		end)

		it("ExecutionCount in server snapshot maps to Scheduler's RunCount", function()
			-- Regression: the server snapshot used to read taskDef.ExecutionCount,
			-- but the Scheduler tracks RunCount. The fix: snapshot now passes
			-- both RunCount and ExecutionCount aliased to the same value, and
			-- TasksModule prefers RunCount with ExecutionCount fallback.
			local mod = TasksModule.new()
			local nexus = MockNexus.new({
				contextMode = "server",
				orchestrator = MockOrchestrator.new({ tasks = {} }),
				serverData = {
					Tasks = {
						List = {
							CountedTask = {
								Name = "CountedTask",
								RunCount = 42,
								-- ExecutionCount intentionally omitted —
								-- the snapshot must propagate it from RunCount
								-- and the consumer must accept either.
							},
						},
						Performance = {},
					},
				},
			})
			mod:FetchData(nexus)
			expect(mod._taskCache.CountedTask.ExecutionCount).toEqual(42)
		end)

		it("client and server branches produce equivalent Status for equivalent input", function()
			-- Cross-branch parity: a task running with the same RunCount delta
			-- must produce the same Status in BOTH contexts. The original bug
			-- was that the server branch was a passthrough while the client
			-- branch did delta tracking — so the same task showed ACTIVE in
			-- client mode and IDLE in server mode.
			local clientMod = TasksModule.new()
			local serverMod = TasksModule.new()

			-- Client tick 1
			local clientTaskDef = MockOrchestrator.makeTask("Parity", { recurring = true })
			clientTaskDef.RunCount = 0
			local clientNexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({ tasks = { Parity = clientTaskDef } }),
			})
			clientMod:FetchData(clientNexus)

			-- Server tick 1
			local serverNexus = MockNexus.new({
				contextMode = "server",
				orchestrator = MockOrchestrator.new({ tasks = {} }),
				serverData = {
					Tasks = {
						List = {
							Parity = { Name = "Parity", RunCount = 0, IsRecurringTask = true },
						},
						Performance = {},
					},
				},
			})
			serverMod:FetchData(serverNexus)

			expect(clientMod._taskCache.Parity.Status).toEqual(serverMod._taskCache.Parity.Status)

			-- Tick 2: same delta on both
			clientTaskDef.RunCount = 30
			clientMod:FetchData(clientNexus)
			serverNexus._serverData.Tasks.List.Parity.RunCount = 30
			serverMod:FetchData(serverNexus)

			expect(clientMod._taskCache.Parity.Status).toEqual("active")
			expect(serverMod._taskCache.Parity.Status).toEqual("active")
			expect(clientMod._taskCache.Parity.Status).toEqual(serverMod._taskCache.Parity.Status)
		end)

		it("ACTIVE_WINDOW adapts to task cadence (5s-recurring task stays ACTIVE between ticks)", function()
			-- A task with TaskExecutionDelay = 5s ticks once every 5 seconds.
			-- With a fixed 3s ACTIVE_WINDOW, it would be IDLE for ~2s of every
			-- 5s cycle (annoying flicker). The fix: window = max(3, 2 * Delay)
			-- → 10s for a 5s-recurring task → stays ACTIVE between ticks.
			local mod = TasksModule.new()
			local nexus = MockNexus.new({
				contextMode = "server",
				orchestrator = MockOrchestrator.new({ tasks = {} }),
				serverData = {
					Tasks = {
						List = {
							SlowPoll = {
								Name = "SlowPoll",
								RunCount = 1,
								IsRecurringTask = true,
								TaskExecutionDelay = 5,
								Delay = 5,
							},
						},
						Performance = {},
					},
				},
			})
			-- Tick 1: delta from 0 → 1, lastActiveTime is recorded.
			mod:FetchData(nexus)
			expect(mod._taskCache.SlowPoll.Status).toEqual("active")

			-- Simulate 4s passing without runCount change. With the OLD fixed
			-- 3s window this would already be IDLE; with the new 10s adaptive
			-- window (2 * 5s delay) it should still be ACTIVE.
			mod._lastActiveTime["SlowPoll"] = os.clock() - 4
			mod:FetchData(nexus)
			expect(mod._taskCache.SlowPoll.Status).toEqual("active")

			-- Simulate 11s passing — now beyond even the adaptive window.
			mod._lastActiveTime["SlowPoll"] = os.clock() - 11
			mod:FetchData(nexus)
			expect(mod._taskCache.SlowPoll.Status).toEqual("idle")
		end)

		it("ACTIVE_WINDOW floor is 3s for fast/zero-delay tasks (heartbeat doesn't shrink to 0)", function()
			-- A heartbeat task has Delay = 0. Without a floor, the window
			-- would be max(3, 0) = 3s — fine. But a task with Delay = 0.5
			-- shouldn't shrink to a 1s window (would flicker on dropped frames).
			-- Floor at 3s.
			local mod = TasksModule.new()
			local nexus = MockNexus.new({
				contextMode = "server",
				orchestrator = MockOrchestrator.new({ tasks = {} }),
				serverData = {
					Tasks = {
						List = {
							FastTask = {
								Name = "FastTask",
								RunCount = 1,
								IsRecurringTask = true,
								Delay = 0.5,
							},
						},
						Performance = {},
					},
				},
			})
			mod:FetchData(nexus)
			expect(mod._taskCache.FastTask.Status).toEqual("active")

			-- 2.5s lapsed — would be IDLE if window were 1s (2 * 0.5),
			-- but the 3s floor keeps it ACTIVE.
			mod._lastActiveTime["FastTask"] = os.clock() - 2.5
			mod:FetchData(nexus)
			expect(mod._taskCache.FastTask.Status).toEqual("active")
		end)
	end)

	-- ── Scheduler→snapshot round-trip guard ──────────────────────────
	-- The original bug was a field-name mismatch at the snapshot boundary:
	-- Scheduler tracks task.RunCount, but the snapshot generator read
	-- task.ExecutionCount (which is always nil). No test exercised the
	-- snapshot generator, so the mismatch was invisible.
	describe("Server snapshot generator (source-level)", function()
		it("reads RunCount (the real Scheduler field) not ExecutionCount", function()
			local node: any = game
			for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "ServiceManager"}) do
				node = node:FindFirstChild(name)
				if not node then break end
			end
			expect(node).never.toBeNil()
			-- The init.luau is a ModuleScript on the same node
			local init = node and node:IsA("ModuleScript") and node or (node and node:FindFirstChild("init"))
			-- Roblox usually folds init.luau into the parent ModuleScript.
			local source = (node and node:IsA("ModuleScript") and node.Source) or ""
			expect(#source > 0).toEqual(true)
			-- Snapshot must read taskDef.RunCount (the actual field name).
			expect(string.find(source, "taskDef%.RunCount") ~= nil).toEqual(true)
			-- And it must include LastRunTime (Scheduler now records this).
			expect(string.find(source, "taskDef%.LastRunTime") ~= nil).toEqual(true)
			-- And IsRunning derived from Scheduler._running.
			expect(string.find(source, "running%[name%]") ~= nil).toEqual(true)
		end)

		it("Scheduler._internalExecute records LastRunTime", function()
			local node: any = game
			for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "Core", "Scheduler"}) do
				node = node:FindFirstChild(name)
				if not node then break end
			end
			expect(node).never.toBeNil()
			local source = node:IsA("ModuleScript") and node.Source or ""
			expect(#source > 0).toEqual(true)
			-- The execution path must stamp LastRunTime so the dashboard
			-- can derive an "active" state without needing delta tracking.
			expect(string.find(source, "t%.LastRunTime = start") ~= nil
				or string.find(source, "t%.LastRunTime = os_clock") ~= nil).toEqual(true)
		end)
	end)

	describe("EMA smoothing & direction", function()
		it("smooths FPS toward target via EMA", function()
			local mod = TasksModule.new()
			mod._smoothPerf.FPS = 60
			mod._perfCache = { FPS = 30, MemoryMB = 0, ActiveTasks = 0, FrameBudget = 0 }
			mod:_UpdateSmoothedPerf()
			-- After one EMA step, smoothed should be between previous and target
			expect(mod._smoothPerf.FPS).toBeLessThan(60)
			expect(mod._smoothPerf.FPS).toBeGreaterThan(30)
		end)

		it("converges to target over many steps", function()
			local mod = TasksModule.new()
			mod._smoothPerf.FPS = 60
			mod._perfCache = { FPS = 30, MemoryMB = 0, ActiveTasks = 0, FrameBudget = 0 }
			for _ = 1, 50 do mod:_UpdateSmoothedPerf() end
			expect(mod._smoothPerf.FPS).toBeCloseTo(30, 0.5)
		end)

		it("detects upward FPS direction", function()
			local mod = TasksModule.new()
			mod._prevPerf.FPS = 30
			mod._perfCache = { FPS = 60, MemoryMB = 0, ActiveTasks = 0, FrameBudget = 0 }
			mod:_UpdateSmoothedPerf()
			expect(mod._perfDirections.FPS).toEqual(1)
		end)

		it("detects downward FPS direction", function()
			local mod = TasksModule.new()
			mod._prevPerf.FPS = 60
			mod._perfCache = { FPS = 30, MemoryMB = 0, ActiveTasks = 0, FrameBudget = 0 }
			mod:_UpdateSmoothedPerf()
			expect(mod._perfDirections.FPS).toEqual(-1)
		end)

		it("reports stable direction within threshold", function()
			local mod = TasksModule.new()
			mod._prevPerf.FPS = 60
			mod._perfCache = { FPS = 60.1, MemoryMB = 0, ActiveTasks = 0, FrameBudget = 0 }
			mod:_UpdateSmoothedPerf()
			expect(mod._perfDirections.FPS).toEqual(0)
		end)

		it("tracks memory direction (up = bad)", function()
			local mod = TasksModule.new()
			mod._prevPerf.MemoryMB = 100
			mod._perfCache = { FPS = 60, MemoryMB = 200, ActiveTasks = 0, FrameBudget = 0 }
			mod:_UpdateSmoothedPerf()
			expect(mod._perfDirections.MemoryMB).toEqual(1)
		end)
	end)

	describe("_GetSortedFilteredTasks", function()
		it("returns all tasks when search is empty", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				A = { Name = "A", Status = "idle", Priority = 1 },
				B = { Name = "B", Status = "running", Priority = 2 },
				C = { Name = "C", Status = "idle", Priority = 3 },
			}
			local sorted = mod:_GetSortedFilteredTasks()
			expect(#sorted).toEqual(3)
		end)

		it("filters by search text in name", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				FooTask = { Name = "FooTask", Status = "idle", Priority = 1 },
				BarTask = { Name = "BarTask", Status = "idle", Priority = 2 },
			}
			mod._searchText = "foo"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(#sorted).toEqual(1)
			expect(sorted[1].Name).toEqual("FooTask")
		end)

		it("filters by search text in status", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				A = { Name = "A", Status = "running", Priority = 1 },
				B = { Name = "B", Status = "idle", Priority = 2 },
			}
			mod._searchText = "running"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(#sorted).toEqual(1)
			expect(sorted[1].Name).toEqual("A")
		end)

		it("filters by search text in event", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				A = { Name = "A", Event = "Heartbeat", Priority = 1 },
				B = { Name = "B", Event = "Stepped", Priority = 2 },
			}
			mod._searchText = "stepped"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(#sorted).toEqual(1)
			expect(sorted[1].Name).toEqual("B")
		end)

		it("search is case-insensitive", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				FOOBAR = { Name = "FOOBAR", Status = "idle", Priority = 1 },
			}
			mod._searchText = "foobar"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(#sorted).toEqual(1)
		end)

		it("sorts by Priority ascending (default)", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				A = { Name = "A", Status = "idle", Priority = 5 },
				B = { Name = "B", Status = "idle", Priority = 1 },
				C = { Name = "C", Status = "idle", Priority = 3 },
			}
			mod._sortMode = "Priority"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(sorted[1].Name).toEqual("B")
			expect(sorted[2].Name).toEqual("C")
			expect(sorted[3].Name).toEqual("A")
		end)

		it("sorts by Name alphabetically", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				Charlie = { Name = "Charlie", Priority = 1 },
				Alpha = { Name = "Alpha", Priority = 1 },
				Bravo = { Name = "Bravo", Priority = 1 },
			}
			mod._sortMode = "Name"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(sorted[1].Name).toEqual("Alpha")
			expect(sorted[2].Name).toEqual("Bravo")
			expect(sorted[3].Name).toEqual("Charlie")
		end)

		it("sorts by Executions descending", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				A = { Name = "A", ExecutionCount = 5 },
				B = { Name = "B", ExecutionCount = 100 },
				C = { Name = "C", ExecutionCount = 50 },
			}
			mod._sortMode = "Executions"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(sorted[1].Name).toEqual("B")
			expect(sorted[2].Name).toEqual("C")
			expect(sorted[3].Name).toEqual("A")
		end)

		it("sorts by AvgTime descending", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				Slow = { Name = "Slow", AvgTimeMs = 10 },
				Fast = { Name = "Fast", AvgTimeMs = 0.5 },
				Med = { Name = "Med", AvgTimeMs = 4 },
			}
			mod._sortMode = "AvgTime"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(sorted[1].Name).toEqual("Slow")
			expect(sorted[3].Name).toEqual("Fast")
		end)

		it("sorts by Status alphabetically", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				A = { Name = "A", Status = "running" },
				B = { Name = "B", Status = "idle" },
				C = { Name = "C", Status = "error" },
			}
			mod._sortMode = "Status"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(sorted[1].Data.Status).toEqual("error")
			expect(sorted[2].Data.Status).toEqual("idle")
			expect(sorted[3].Data.Status).toEqual("running")
		end)

		it("returns empty list when no task matches", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				A = { Name = "A", Status = "idle" },
			}
			mod._searchText = "doesnotexist"
			local sorted = mod:_GetSortedFilteredTasks()
			expect(#sorted).toEqual(0)
		end)
	end)

	describe("FetchData", function()
		it("populates _perfCache with FPS, MemoryMB, ActiveTasks", function()
			local nexus = makeNexusWithTasks({
				A = MockOrchestrator.makeTask("A"),
				B = MockOrchestrator.makeTask("B"),
			})
			local mod = TasksModule.new()
			mod:FetchData(nexus)
			expect(mod._perfCache.FPS).toEqual(60)
			expect(mod._perfCache.ActiveTasks).toEqual(2)
			expect(mod._perfCache.MemoryMB).toBeGreaterThan(0)
		end)

		it("appends to _perfHistory and caps at 60 entries", function()
			local nexus = makeNexusWithTasks({})
			local mod = TasksModule.new()
			for _ = 1, 75 do
				mod:FetchData(nexus)
			end
			expect(#mod._perfHistory).toBeLessThan(61)
		end)
	end)
end)

end -- close spec function

TR.register(spec)
return spec
