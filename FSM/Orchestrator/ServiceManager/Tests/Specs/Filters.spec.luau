--!strict
-- @Name ServiceManager/Tests/Specs/Filters.spec.luau
-- @Author iKrypto
-- @Description Comprehensive filter/sort spec covering all modules that expose
-- search/level/sort filtering. Each subsystem's filter is tested in isolation
-- by populating its private cache directly.

local TR = require(script.Parent.Parent.TestRunner)
local FSMModule = require(script.Parent.Parent.Parent.Subsystems.FSMModule)
local EntityModule = require(script.Parent.Parent.Parent.Subsystems.EntityModule)
local LogsModule = require(script.Parent.Parent.Parent.Subsystems.LogsModule)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("Filters - FSMModule", function()
	it("filters FSMs by id substring", function()
		local mod = FSMModule.new()
		local source = {
			DoorFSM = { CurrentState = "Open" },
			WindowFSM = { CurrentState = "Closed" },
		}
		mod._searchText = "door"
		local sorted = mod:_GetSortedFiltered(source)
		expect(#sorted).toEqual(1)
		expect(sorted[1].Id).toEqual("DoorFSM")
	end)

	it("filters FSMs by current state", function()
		local mod = FSMModule.new()
		local source = {
			A = { CurrentState = "Running" },
			B = { CurrentState = "Idle" },
			C = { CurrentState = "Failed" },
		}
		mod._searchText = "running"
		local sorted = mod:_GetSortedFiltered(source)
		expect(#sorted).toEqual(1)
	end)

	it("sorts by Name alphabetically", function()
		local mod = FSMModule.new()
		mod._sortMode = "Name"
		local source = {
			Charlie = {},
			Alpha = {},
			Bravo = {},
		}
		local sorted = mod:_GetSortedFiltered(source)
		expect(sorted[1].Id).toEqual("Alpha")
		expect(sorted[3].Id).toEqual("Charlie")
	end)

	it("sorts by State alphabetically", function()
		local mod = FSMModule.new()
		mod._sortMode = "State"
		local source = {
			A = { CurrentState = "Running" },
			B = { CurrentState = "Idle" },
			C = { CurrentState = "Failed" },
		}
		local sorted = mod:_GetSortedFiltered(source)
		expect(sorted[1].Data.CurrentState).toEqual("Failed")
	end)

	it("sorts by Transitions descending", function()
		local mod = FSMModule.new()
		mod._sortMode = "Transitions"
		local source = {
			A = { Transitions = 5 },
			B = { Transitions = 100 },
			C = { Transitions = 50 },
		}
		local sorted = mod:_GetSortedFiltered(source)
		expect(sorted[1].Id).toEqual("B")
	end)

	-- ── Context-strict FSM filtering (the GUI's CLIENT/SERVER toggle is
	--    a strict filter — server-side FSMs must NOT appear in client mode
	--    and vice versa, even though server snapshots are polled at all times).
	it("FetchData in client mode only includes client-VM FSMs", function()
		local MockOrchestrator = require(script.Parent.Parent.Mocks.MockOrchestrator)
		local MockNexus = require(script.Parent.Parent.Mocks.MockNexus)

		-- Mock a client FSM (registered in the local Factory registry)
		local clientFsm = setmetatable({
			Id = "ClientDoorFSM",
			_states = { Closed = {}, Open = {} },
			CurrentState = "Closed",
			TransitionHistory = {},
			_transitionCount = 0,
		}, {})

		local orchestrator = MockOrchestrator.new({
			fsms = { ClientDoorFSM = clientFsm },
		})
		-- Mock a server FSM in the snapshot
		local nexus = MockNexus.new({
			contextMode = "client",
			orchestrator = orchestrator,
			serverData = {
				FSM = {
					List = {
						ServerTrafficLight = {
							CurrentState = "Red",
							States = { "Red", "Green", "Yellow" },
							Transitions = 10,
							Status = "active",
						},
					},
				},
			},
		})

		local mod = FSMModule.new()
		mod:FetchData(nexus)

		-- Client FSM should be present
		expect(mod._fsmCache["ClientDoorFSM"]).never.toBeNil()
		-- Server FSM should NOT appear in client mode (the bug we fixed)
		expect(mod._fsmCache["ServerTrafficLight"]).toBeNil()
		expect(mod._completedFSMs["ServerTrafficLight"]).toBeNil()
		expect(mod._failedFSMs["ServerTrafficLight"]).toBeNil()
	end)

	it("FetchData in server mode only includes server-VM FSMs", function()
		local MockOrchestrator = require(script.Parent.Parent.Mocks.MockOrchestrator)
		local MockNexus = require(script.Parent.Parent.Mocks.MockNexus)

		local clientFsm = setmetatable({
			Id = "ClientDoorFSM",
			_states = { Closed = {} },
			CurrentState = "Closed",
			TransitionHistory = {},
			_transitionCount = 0,
		}, {})

		local orchestrator = MockOrchestrator.new({
			fsms = { ClientDoorFSM = clientFsm },
		})
		local nexus = MockNexus.new({
			contextMode = "server",
			orchestrator = orchestrator,
			serverData = {
				FSM = {
					List = {
						ServerTrafficLight = {
							CurrentState = "Red",
							States = { "Red", "Green", "Yellow" },
							Transitions = 10,
							Status = "active",
						},
					},
				},
			},
		})

		local mod = FSMModule.new()
		mod:FetchData(nexus)

		-- Server FSM should be present
		expect(mod._fsmCache["ServerTrafficLight"]).never.toBeNil()
		expect(mod._fsmCache["ServerTrafficLight"].Origin).toEqual("server")
		-- Client FSM should NOT appear in server mode
		expect(mod._fsmCache["ClientDoorFSM"]).toBeNil()
		expect(mod._completedFSMs["ClientDoorFSM"]).toBeNil()
		expect(mod._failedFSMs["ClientDoorFSM"]).toBeNil()
	end)
end)

describe("Filters - EntityModule", function()
	it("filters entities by id substring", function()
		local mod = EntityModule.new()
		local source = {
			Door1 = { ClassName = "DoorEntity", IsValid = true },
			Window1 = { ClassName = "WindowEntity", IsValid = true },
		}
		mod._searchText = "door"
		local sorted = mod:_GetSorted(source)
		expect(#sorted).toEqual(1)
		expect(sorted[1].Id).toEqual("Door1")
	end)

	it("filters entities by class name", function()
		local mod = EntityModule.new()
		local source = {
			A = { ClassName = "PlayerEntity" },
			B = { ClassName = "NPCEntity" },
		}
		mod._searchText = "npc"
		local sorted = mod:_GetSorted(source)
		expect(#sorted).toEqual(1)
		expect(sorted[1].Data.ClassName).toEqual("NPCEntity")
	end)

	it("sorts by Type", function()
		local mod = EntityModule.new()
		mod._sortMode = "Type"
		local source = {
			A = { ClassName = "ZetaEntity" },
			B = { ClassName = "AlphaEntity" },
		}
		local sorted = mod:_GetSorted(source)
		expect(sorted[1].Data.ClassName).toEqual("AlphaEntity")
	end)

	it("sorts by Status (valid first)", function()
		local mod = EntityModule.new()
		mod._sortMode = "Status"
		local source = {
			Dead = { IsValid = false },
			Alive = { IsValid = true },
		}
		local sorted = mod:_GetSorted(source)
		expect(sorted[1].Id).toEqual("Alive")
	end)
end)

describe("Filters - LogsModule", function()
	local function buildLogs()
		return {
			{ Level = "INFO", Message = "Initializing system", Timestamp = 0, Source = "Boot" },
			{ Level = "WARN", Message = "Memory threshold exceeded", Timestamp = 1, Source = "Memory" },
			{ Level = "ERROR", Message = "Connection failed", Timestamp = 2, Source = "Network" },
			{ Level = "DEBUG", Message = "Debug trace point", Timestamp = 3, Source = "Boot" },
			{ Level = "INFO", Message = "Player joined", Timestamp = 4, Source = "Players" },
		}
	end

	it("ALL filter shows all logs", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "ALL"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(5)
	end)

	it("INFO filter shows only INFO logs", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "INFO"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(2)
	end)

	it("ERROR filter shows only ERROR logs", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "ERROR"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(1)
		expect(mod._filteredLogs[1].Source).toEqual("Network")
	end)

	it("WARN filter shows only WARN logs", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "WARN"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(1)
	end)

	it("DEBUG filter shows only DEBUG logs", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "DEBUG"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(1)
	end)

	it("text search filters by message substring", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "ALL"
		mod._searchText = "memory"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(1)
	end)

	it("text search filters by source", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "ALL"
		mod._searchText = "boot"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(2)
	end)

	it("level + text filters compose (AND logic)", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "INFO"
		mod._searchText = "player"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(1)
		expect(mod._filteredLogs[1].Source).toEqual("Players")
	end)

	it("returns empty when no log matches", function()
		local mod = LogsModule.new()
		mod._logCache = buildLogs()
		mod._activeFilter = "ALL"
		mod._searchText = "nonexistentterm"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toEqual(0)
	end)

	it("respects MAX_DISPLAY_LOGS cap", function()
		local mod = LogsModule.new()
		local logs = {}
		for i = 1, 500 do
			table.insert(logs, { Level = "INFO", Message = "log " .. i, Timestamp = i })
		end
		mod._logCache = logs
		mod._activeFilter = "ALL"
		mod:_ApplyFilters()
		expect(#mod._filteredLogs).toBeLessThan(201)
	end)
end)

describe("Filters - NetworkModule (no duplicate cards)", function()
	local NetworkModule = require(script.Parent.Parent.Parent.Subsystems.NetworkModule)

	it("_GetAllItems doesn't double-render entries that are in both _commandCache and _serverCallbacks", function()
		-- Regression: ServerRequest names ended up in both _commandCache
		-- (with full info — RecentCalls, MessageCount) AND _serverCallbacks
		-- (a stub) — and _GetAllItems iterated both, producing duplicate
		-- cards on the network root layer.
		local mod = NetworkModule.new()
		mod._commandCache = {
			GetState = { Name = "GetState", Type = "ServerRequest", MessageCount = 5 },
			SetData = { Name = "SetData", Type = "ServerRequest", MessageCount = 3 },
		}
		mod._eventBusCache = {}
		mod._serverCallbacks = {
			GetState = { Name = "GetState", Type = "ServerRequest", HasCallback = true },
			SetData = { Name = "SetData", Type = "ServerRequest", HasCallback = true },
		}

		local items = mod:_GetAllItems()
		expect(#items).toEqual(2) -- not 4

		local names = {}
		for _, item in ipairs(items) do
			names[item.Name] = (names[item.Name] or 0) + 1
		end
		expect(names["GetState"]).toEqual(1)
		expect(names["SetData"]).toEqual(1)
	end)

	it("_BuildCallsHistoryLayer escapes angle brackets in args before RichText rendering", function()
		-- Regression: historic call entries (captured before the [...] format
		-- fix) may contain "<userdata:CFrame>" / "<Vector3>" in entry.Args.
		-- The TextLabel that renders them has RichText=true, which would
		-- parse those as malformed font tags — stripping the type info and
		-- corrupting the rest of the label. The fix escapes < and > before
		-- embedding into the RichText label.
		local node: any = game
		for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "ServiceManager", "Subsystems", "NetworkModule"}) do
			node = node:FindFirstChild(name)
			if not node then break end
		end
		expect(node).never.toBeNil()
		local source = node:IsA("ModuleScript") and node.Source or ""
		expect(source ~= "").toEqual(true)

		-- Must escape < and > in the args display string before composing
		-- the RichText label.
		expect(string.find(source, 'rawArgsStr:gsub%("<", "&lt;"%):gsub%(">", "&gt;"%)') ~= nil).toEqual(true)
		-- _RenderStructuredArg must also escape (defends against historic
		-- ArgsStruct values like "<userdata:CFrame>").
		expect(string.find(source, 'local function escape%(s: string%)') ~= nil).toEqual(true)
	end)

	it("hasNested check falls back to #argsStruct when .n is nil (RemoteFunction serialization)", function()
		-- Regression: Roblox RemoteFunctions strip the explicit `n` key from
		-- mixed tables when the array length matches it. After receiving a
		-- snapshot, argsStruct.n is often nil even though argsStruct[1..N]
		-- are populated. The hasNested check must use #argsStruct as fallback,
		-- otherwise nested-table args never become click-to-expand.
		local node: any = game
		for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "ServiceManager", "Subsystems", "NetworkModule"}) do
			node = node:FindFirstChild(name)
			if not node then break end
		end
		local source = node:IsA("ModuleScript") and node.Source or ""
		expect(source ~= "").toEqual(true)
		-- Both the row's hasNested guard and the renderer's argCount must
		-- fall back to # when .n is missing.
		expect(string.find(source, "argsStruct%.n or #argsStruct") ~= nil).toEqual(true)
		expect(string.find(source, "args%.n or #args") ~= nil).toEqual(true)
	end)
end)

end -- close spec function

TR.register(spec)
return spec
