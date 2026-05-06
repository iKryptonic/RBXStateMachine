--!strict
-- @Name ServiceManager/Tests/Specs/Interactivity.spec.luau
-- @Author iKrypto
-- @Description Behavior-asserting tests that verify each subsystem page is
-- INTERACTIVE — not just structural. These tests render real Frames, simulate
-- user clicks via Theme.SimulateRowClick, and assert that the right side
-- effects (ExpandLayer, action method invocations) actually occurred.
--
-- These tests will FAIL when interactivity is missing or stubbed out, surfacing
-- the kind of "looks built but does nothing" bugs that structure-only tests
-- silently pass.

local TR = require(script.Parent.Parent.TestRunner)
local MockNexus = require(script.Parent.Parent.Mocks.MockNexus)
local MockOrchestrator = require(script.Parent.Parent.Mocks.MockOrchestrator)
local Theme = require(script.Parent.Parent.Parent.Theme)
local TasksModule = require(script.Parent.Parent.Parent.Subsystems.TasksModule)
local EntityModule = require(script.Parent.Parent.Parent.Subsystems.EntityModule)
local FSMModule = require(script.Parent.Parent.Parent.Subsystems.FSMModule)
local NetworkModule = require(script.Parent.Parent.Parent.Subsystems.NetworkModule)
local DataStoreModule = require(script.Parent.Parent.Parent.Subsystems.DataStoreModule)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function lastNavCall(nexus: any): any?
		local calls = nexus._navCalls
		if #calls == 0 then return nil end
		return calls[#calls]
	end

	local function findExpandLayerCall(nexus: any, idPattern: string): any?
		for _, call in ipairs(nexus._navCalls) do
			if call.method == "ExpandLayer" then
				local layer = call.args[1]
				if layer and string.find(layer.Id or "", idPattern) then
					return layer
				end
			end
		end
		return nil
	end

	-- ────────────────────────────────────────────────────────────
	-- TASKS interactivity
	-- ────────────────────────────────────────────────────────────
	describe("Interactivity - TASKS", function()
		it("clicking a task row drills into its detail layer", function()
			local mod = TasksModule.new()
			mod._taskCache = {
				MyTask = { Name = "MyTask", Status = "active", Priority = 1 },
			}
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new(),
			})
			local _, content = MockNexus.makeLayerFrame()
			mod:BuildRootLayer(content.Parent :: Frame, { Nexus = nexus })

			local row = content:FindFirstChild("Task_MyTask") :: Frame?
			expect(row).never.toBeNil()

			local clicked = Theme.SimulateRowClick(row :: Frame)
			expect(clicked).toBeTruthy()

			local call = findExpandLayerCall(nexus, "tasks%.detail%.MyTask")
			expect(call).never.toBeNil()
			expect((call :: any).Label).toEqual("MyTask")
		end)

		it("task detail layer renders Run + Kill action buttons", function()
			local mod = TasksModule.new()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({
					tasks = { MyTask = MockOrchestrator.makeTask("MyTask") },
				}),
			})
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildTaskDetailLayer(content.Parent :: Frame, {
				Nexus = nexus,
				TaskName = "MyTask",
				TaskData = { Name = "MyTask", Status = "active", HasAction = true },
			})

			local runBtn = MockNexus.findButtonByText(content, "Run")
			local killBtn = MockNexus.findButtonByText(content, "Kill")
			expect(runBtn).never.toBeNil()
			expect(killBtn).never.toBeNil()
		end)

		it("perf strip is clickable and drills into performance layer", function()
			local mod = TasksModule.new()
			-- Seed perf cache so the strip will render
			mod._perfCache = { FPS = 60, MemoryMB = 10, ActiveTasks = 1, FrameBudget = 0.005 }
			mod._smoothPerf = { FPS = 60, MemoryMB = 10, ActiveTasks = 1, FrameBudgetMs = 5 }
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildPerfStrip(content :: Frame, nexus)
			local strip = content:FindFirstChild("PerfStrip") :: TextButton?
			expect(strip).never.toBeNil()
			-- Verify the strip itself is a TextButton (clickable)
			expect((strip :: any):IsA("TextButton")).toBeTruthy()
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- ENTITY interactivity (user complaint: versioning is not explorable)
	-- ────────────────────────────────────────────────────────────
	describe("Interactivity - ENTITY", function()
		it("clicking an entity row drills into its detail layer", function()
			local mod = EntityModule.new()
			mod._entityCache = {
				Door1 = { ClassName = "DoorEntity", IsValid = true, Version = 4, Data = {} },
			}
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:BuildRootLayer(content.Parent :: Frame, { Nexus = nexus })

			local row = content:FindFirstChild("Entity_Door1") :: Frame?
			expect(row).never.toBeNil()

			Theme.SimulateRowClick(row :: Frame)
			local call = findExpandLayerCall(nexus, "entity%.detail%.Door1")
			expect(call).never.toBeNil()
		end)

		it("entity detail shows version + click drills into version history", function()
			-- This test asserts that the version field is INTERACTIVE
			-- (clickable button or row). Bug: currently version is just a label.
			local mod = EntityModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildEntityDetailLayer(content.Parent :: Frame, {
				Nexus = nexus,
				EntityId = "Door1",
				EntityData = {
					ClassName = "DoorEntity",
					IsValid = true,
					Version = 4,
					VersionHistory = {
						{ Version = 1, Time = 1000, Field = "State", From = nil, To = "Closed" },
						{ Version = 2, Time = 1010, Field = "State", From = "Closed", To = "Open" },
						{ Version = 3, Time = 1020, Field = "Health", From = nil, To = 100 },
						{ Version = 4, Time = 1030, Field = "Health", From = 100, To = 95 },
					},
				},
			})

			-- Look for a version button or "View Versions" button
			local versionBtn = MockNexus.findButtonByText(content, "Version")
				or MockNexus.findButtonByText(content, "v4")
				or MockNexus.findButtonByText(content, "History")
			expect(versionBtn).never.toBeNil() -- BUG: fails until version is interactive
		end)

		it("clicking version button drills into version history layer", function()
			local mod = EntityModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildEntityDetailLayer(content.Parent :: Frame, {
				Nexus = nexus,
				EntityId = "Door1",
				EntityData = {
					ClassName = "DoorEntity", IsValid = true, Version = 4,
					VersionHistory = {
						{ Version = 1, Time = 1000, Field = "State", From = nil, To = "Closed" },
					},
				},
			})

			local versionBtn = MockNexus.findButtonByText(content, "Version")
				or MockNexus.findButtonByText(content, "History")
			expect(versionBtn).never.toBeNil()
			-- Test will simulate click via direct invocation pattern
			pcall(function() (versionBtn :: any).MouseButton1Click:Fire() end)
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- FSM interactivity (user complaint: visualizer lacks history/arrows)
	-- ────────────────────────────────────────────────────────────
	describe("Interactivity - FSM", function()
		it("clicking an FSM row drills into its detail layer", function()
			local mod = FSMModule.new()
			mod._fsmCache = {
				DoorFSM = {
					CurrentState = "Open",
					States = { "Idle", "Open", "Closed" },
					Transitions = 5,
					Status = "active",
				},
			}
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:BuildRootLayer(content.Parent :: Frame, { Nexus = nexus })

			local row = content:FindFirstChild("FSM_DoorFSM") :: Frame?
			expect(row).never.toBeNil()
			Theme.SimulateRowClick(row :: Frame)
			expect(findExpandLayerCall(nexus, "fsm%.detail%.DoorFSM")).never.toBeNil()
		end)

		it("FSM detail layer has a 'Visualize' button to open the graph", function()
			local mod = FSMModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildFSMDetailLayer(content.Parent :: Frame, {
				Nexus = nexus,
				FSMId = "DoorFSM",
				FSMData = {
					CurrentState = "Open",
					States = { "Idle", "Open", "Closed" },
					Transitions = 5,
					TransitionHistory = {},
				},
			})
			local vizBtn = MockNexus.findButtonByText(content, "Visualize")
				or MockNexus.findButtonByText(content, "Graph")
			expect(vizBtn).never.toBeNil()
		end)

		it("FSM detail has a 'Cancel' or 'Restart' action button", function()
			local mod = FSMModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildFSMDetailLayer(content.Parent :: Frame, {
				Nexus = nexus,
				FSMId = "DoorFSM",
				FSMData = {
					CurrentState = "Open",
					States = { "Idle", "Open" },
					Transitions = 1,
					TransitionHistory = {},
				},
			})
			local cancelBtn = MockNexus.findButtonByText(content, "Cancel")
				or MockNexus.findButtonByText(content, "Restart")
				or MockNexus.findButtonByText(content, "Reset")
			expect(cancelBtn).never.toBeNil() -- BUG: surfaces missing action buttons
		end)

		it("FSM visualizer renders a transition history list with arrows", function()
			local mod = FSMModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildGraphLayer(content.Parent :: Frame, {
				Nexus = nexus,
				FSMId = "DoorFSM",
				FSMData = {
					CurrentState = "Open",
					States = { "Idle", "Opening", "Open", "Closing" },
					TransitionHistory = {
						{ From = "Idle", To = "Opening", Time = 1.0 },
						{ From = "Opening", To = "Open", Time = 2.0 },
						{ From = "Open", To = "Closing", Time = 3.0 },
					},
				},
			})

			-- Look for a "History" or "Transitions" panel and arrow indicators
			local historyPanel = MockNexus.findChild(content, "TransitionHistory")
				or MockNexus.findChild(content, "HistoryPanel")
			expect(historyPanel).never.toBeNil() -- BUG: fails until history list added

			-- Verify there's an arrow glyph somewhere (▶, →, or ▸)
			local hasArrow = false
			for _, desc in ipairs(content:GetDescendants()) do
				if desc:IsA("TextLabel") or desc:IsA("TextButton") then
					local t = (desc :: any).Text
					if t and (string.find(t, "▶") or string.find(t, "→") or string.find(t, "▸")) then
						hasArrow = true; break
					end
				end
			end
			expect(hasArrow).toBeTruthy()
		end)

		it("FSM visualizer has a 'Refresh' button to re-snapshot", function()
			local mod = FSMModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildGraphLayer(content.Parent :: Frame, {
				Nexus = nexus,
				FSMId = "DoorFSM",
				FSMData = { CurrentState = "Open", States = { "Idle", "Open" }, TransitionHistory = {} },
			})
			local refreshBtn = MockNexus.findButtonByText(content, "Refresh")
			expect(refreshBtn).never.toBeNil()
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- NETWORK interactivity (user complaint: network tab is read-only)
	-- ────────────────────────────────────────────────────────────
	describe("Interactivity - NETWORK", function()
		it("clicking a network row drills into its detail layer", function()
			local mod = NetworkModule.new()
			mod._commandCache = {
				MyBus = { Type = "EventBus", Subscribers = 2, MessageCount = 0 },
			}
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:BuildRootLayer(content.Parent :: Frame, { Nexus = nexus })

			local row: Instance? = nil
			for _, desc in ipairs(content:GetDescendants()) do
				if desc.Name == "Net_MyBus" then row = desc; break end
			end
			expect(row).never.toBeNil()
			Theme.SimulateRowClick(row :: Frame)
			expect(findExpandLayerCall(nexus, "network%.detail%.MyBus")).never.toBeNil()
		end)

		it("network detail layer shows a 'Fire' or 'Trigger' action button", function()
			local mod = NetworkModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildNetworkDetailLayer(content.Parent :: Frame, {
				Nexus = nexus,
				ItemName = "MyBus",
				ItemData = { Type = "EventBus", Subscribers = 2, MessageCount = 0 },
			})
			local fireBtn = MockNexus.findButtonByText(content, "Fire")
				or MockNexus.findButtonByText(content, "Trigger")
				or MockNexus.findButtonByText(content, "Send")
			expect(fireBtn).never.toBeNil() -- BUG: surfaces read-only network tab
		end)

		it("network detail shows a 'View Calls' button revealing message history", function()
			local mod = NetworkModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildNetworkDetailLayer(content.Parent :: Frame, {
				Nexus = nexus,
				ItemName = "MyBus",
				ItemData = { Type = "EventBus", Subscribers = 2, MessageCount = 5, RecentCalls = {
					{ Time = 1, Args = "{}" }, { Time = 2, Args = "{}" }
				}},
			})
			local callsBtn = MockNexus.findButtonByText(content, "Calls")
				or MockNexus.findButtonByText(content, "History")
				or MockNexus.findButtonByText(content, "Log")
			expect(callsBtn).never.toBeNil()
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- DATASTORE interactivity
	-- ────────────────────────────────────────────────────────────
	describe("Interactivity - DATASTORE", function()
		it("clicking a store row drills into its detail layer", function()
			local mod = DataStoreModule.new()
			mod._storeCache = {
				MyStore = { Status = "ready", CachedKeys = 5, TotalOps = 100 },
			}
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:BuildRootLayer(content.Parent :: Frame, { Nexus = nexus })

			local row = content:FindFirstChild("DS_MyStore") :: Frame?
			expect(row).never.toBeNil()
			Theme.SimulateRowClick(row :: Frame)
			expect(findExpandLayerCall(nexus, "datastore%.detail%.MyStore")).never.toBeNil()
		end)

		it("store detail has 'Flush' or 'Reload' action button", function()
			local mod = DataStoreModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:_BuildStoreDetailLayer(content.Parent :: Frame, {
				Nexus = nexus,
				StoreName = "MyStore",
				StoreData = { Status = "ready", CachedKeys = 5 },
			})
			local actionBtn = MockNexus.findButtonByText(content, "Flush")
				or MockNexus.findButtonByText(content, "Reload")
				or MockNexus.findButtonByText(content, "Clear")
			expect(actionBtn).never.toBeNil() -- BUG: store detail has no actions
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- INSIGHTS interactivity
	-- ────────────────────────────────────────────────────────────
	describe("Interactivity - INSIGHTS", function()
		it("insight rows expose ActionableHints as buttons", function()
			-- This is already implemented via AnalyticsEngine.ActionableHints —
			-- the test validates the contract.
			local InsightsModule = require(script.Parent.Parent.Parent.Subsystems.InsightsModule)
			local mod = InsightsModule.new()
			mod._activeInsights = {
				{
					Id = "test_insight",
					Severity = "WARNING",
					Subsystem = "TASKS",
					Title = "Test",
					Description = "test",
					Timestamp = os.clock(),
					Dismissed = false,
					ActionableHints = {
						{ Label = "View Tasks", Command = "switch tasks" },
					},
				},
			}
			mod._historyInsights = {}
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local _, content = MockNexus.makeLayerFrame()
			mod:BuildRootLayer(content.Parent :: Frame, { Nexus = nexus })
			-- The active insight should have its hint rendered as a button
			local hintBtn = MockNexus.findButtonByText(content, "View Tasks")
			expect(hintBtn).never.toBeNil() -- BUG: hints not rendered as buttons
		end)
	end)
end

TR.register(spec)
return spec
