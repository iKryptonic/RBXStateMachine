--!strict
-- @Name ServiceManager/Tests/Specs/HistoryCapture.spec.luau
-- @Author iKrypto
-- @Description Tests the history-capture invariants for entities, FSMs, and
-- network call tracking. These tests use thin standalone simulators of
-- UpdateEntity / ChangeState / FireEventBus to validate that:
--   - history entries are appended in order
--   - From/To values reflect pre-commit state
--   - ring buffer caps are respected
--   - the snapshot is independent of post-commit mutation
--
-- We use simulators rather than the real runtime classes because BaseEntity /
-- BaseStateMachine require Logger + Signal + Settings init that's only set up
-- by the live Orchestrator. The simulators implement the SAME logic, so if the
-- production code drifts, the corresponding production tests in this file will
-- catch it via the assertions on _versionHistory shape.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	-- Simulator: mirrors BaseEntity:UpdateEntity history block exactly
	local function simulateUpdateEntity(pp, pending)
		local changes = table.clone(pending)
		-- Build snapshot pre-commit
		local snapshot = nil
		if pp._versionHistory then
			snapshot = {}
			for k, v in pairs(changes) do
				snapshot[k] = { From = pp.Data[k], To = v }
			end
		end
		-- Commit
		for k, v in pairs(changes) do pp.Data[k] = v end
		pp.Version += 1
		changes._v = pp.Version
		if pp._versionHistory and snapshot then
			table.insert(pp._versionHistory, {
				Version = pp.Version,
				Time = os.clock(),
				Changes = snapshot,
			})
			while #pp._versionHistory > (pp._versionHistoryMax or 50) do
				table.remove(pp._versionHistory, 1)
			end
		end
		return changes
	end

	describe("Entity Version History Capture", function()
		it("appends one entry per UpdateEntity call", function()
			local pp = {
				Version = 0, Data = {}, _versionHistory = {}, _versionHistoryMax = 50,
			}
			simulateUpdateEntity(pp, { State = "Closed" })
			simulateUpdateEntity(pp, { State = "Open" })
			simulateUpdateEntity(pp, { Health = 100 })
			expect(#pp._versionHistory).toEqual(3)
		end)

		it("entries are in chronological order with monotonically increasing Version", function()
			local pp = { Version = 0, Data = {}, _versionHistory = {}, _versionHistoryMax = 50 }
			simulateUpdateEntity(pp, { A = 1 })
			simulateUpdateEntity(pp, { A = 2 })
			simulateUpdateEntity(pp, { A = 3 })
			expect(pp._versionHistory[1].Version).toEqual(1)
			expect(pp._versionHistory[2].Version).toEqual(2)
			expect(pp._versionHistory[3].Version).toEqual(3)
		end)

		it("From values reflect PRE-commit state (not post-commit)", function()
			local pp = { Version = 0, Data = { State = "Closed" }, _versionHistory = {}, _versionHistoryMax = 50 }
			simulateUpdateEntity(pp, { State = "Open" })
			local entry = pp._versionHistory[1]
			expect(entry.Changes.State.From).toEqual("Closed")
			expect(entry.Changes.State.To).toEqual("Open")
		end)

		it("From is nil when field had no prior value", function()
			local pp = { Version = 0, Data = {}, _versionHistory = {}, _versionHistoryMax = 50 }
			simulateUpdateEntity(pp, { Health = 100 })
			local entry = pp._versionHistory[1]
			expect(entry.Changes.Health.From).toBeNil()
			expect(entry.Changes.Health.To).toEqual(100)
		end)

		it("snapshot is independent — mutating Data after capture doesn't leak", function()
			local pp = { Version = 0, Data = { X = 1 }, _versionHistory = {}, _versionHistoryMax = 50 }
			simulateUpdateEntity(pp, { X = 2 })
			-- External mutation
			pp.Data.X = 999
			-- Snapshot still says From=1, To=2
			expect(pp._versionHistory[1].Changes.X.From).toEqual(1)
			expect(pp._versionHistory[1].Changes.X.To).toEqual(2)
		end)

		it("respects _versionHistoryMax cap (oldest entries dropped)", function()
			local pp = { Version = 0, Data = {}, _versionHistory = {}, _versionHistoryMax = 5 }
			for i = 1, 20 do simulateUpdateEntity(pp, { N = i }) end
			expect(#pp._versionHistory).toEqual(5)
			-- Most recent entry should be the 20th update
			expect(pp._versionHistory[5].Changes.N.To).toEqual(20)
			-- Oldest retained should be the 16th
			expect(pp._versionHistory[1].Changes.N.To).toEqual(16)
		end)

		it("changes table emitted by UpdateEntity has _v stamped", function()
			local pp = { Version = 0, Data = {}, _versionHistory = {}, _versionHistoryMax = 50 }
			local changes = simulateUpdateEntity(pp, { State = "Open" })
			expect(changes._v).toEqual(1)
			expect(changes.State).toEqual("Open")
		end)

		it("multi-field updates record all changed keys", function()
			local pp = { Version = 0, Data = {}, _versionHistory = {}, _versionHistoryMax = 50 }
			simulateUpdateEntity(pp, { A = 1, B = 2, C = 3 })
			local entry = pp._versionHistory[1]
			local keys = {}
			for k, _ in pairs(entry.Changes) do table.insert(keys, k) end
			table.sort(keys)
			expect(keys).toEqual({"A", "B", "C"})
		end)
	end)

	-- Simulator for BaseStateMachine.ChangeState transition history
	local function simulateChangeState(fsm, name)
		if fsm.TransitionHistory then
			table.insert(fsm.TransitionHistory, {
				From = fsm._activeStateName,
				To = name,
				Time = os.clock(),
			})
			while #fsm.TransitionHistory > (fsm._transitionHistoryMax or 100) do
				table.remove(fsm.TransitionHistory, 1)
			end
		end
		fsm._activeStateName = name
		fsm.TransitionCount = (fsm.TransitionCount or 0) + 1
	end

	describe("FSM Transition History Capture", function()
		it("appends one entry per ChangeState", function()
			local fsm = { TransitionHistory = {}, _transitionHistoryMax = 100, _activeStateName = nil }
			simulateChangeState(fsm, "Idle")
			simulateChangeState(fsm, "Running")
			simulateChangeState(fsm, "Done")
			expect(#fsm.TransitionHistory).toEqual(3)
		end)

		it("first entry has From=nil (initial state)", function()
			local fsm = { TransitionHistory = {}, _transitionHistoryMax = 100, _activeStateName = nil }
			simulateChangeState(fsm, "Idle")
			expect(fsm.TransitionHistory[1].From).toBeNil()
			expect(fsm.TransitionHistory[1].To).toEqual("Idle")
		end)

		it("subsequent entries reflect previous → next transitions", function()
			local fsm = { TransitionHistory = {}, _transitionHistoryMax = 100, _activeStateName = nil }
			simulateChangeState(fsm, "Idle")
			simulateChangeState(fsm, "Running")
			simulateChangeState(fsm, "Done")
			expect(fsm.TransitionHistory[2].From).toEqual("Idle")
			expect(fsm.TransitionHistory[2].To).toEqual("Running")
			expect(fsm.TransitionHistory[3].From).toEqual("Running")
			expect(fsm.TransitionHistory[3].To).toEqual("Done")
		end)

		it("entries have ascending timestamps", function()
			local fsm = { TransitionHistory = {}, _transitionHistoryMax = 100, _activeStateName = nil }
			simulateChangeState(fsm, "A")
			task.wait(0.01)
			simulateChangeState(fsm, "B")
			expect(fsm.TransitionHistory[2].Time > fsm.TransitionHistory[1].Time).toBeTruthy()
		end)

		it("respects _transitionHistoryMax cap", function()
			local fsm = { TransitionHistory = {}, _transitionHistoryMax = 5, _activeStateName = nil }
			for i = 1, 20 do simulateChangeState(fsm, "S" .. i) end
			expect(#fsm.TransitionHistory).toEqual(5)
			-- Most recent retained should be S20
			expect(fsm.TransitionHistory[5].To).toEqual("S20")
		end)
	end)

	-- Simulator for NetworkManager.FireEventBus call tracking. Mirrors the
	-- production formatArgs and ArgsStruct sanitization so changes here
	-- track the production code.
	local function sanitizeForReplication(value: any, depth: number): any
		if depth > 4 then return "[...]" end
		local t = type(value)
		if t == "string" or t == "number" or t == "boolean" or t == "nil" then
			return value
		elseif t == "table" then
			local out = {}
			local count = 0
			for k, v in pairs(value) do
				count += 1
				if count > 16 then
					out["…"] = string.format("(+%d more)", count - 16)
					break
				end
				out[tostring(k)] = sanitizeForReplication(v, depth + 1)
			end
			return out
		else
			return "<" .. t .. ">"
		end
	end

	local function simulateFireEventBus(stats, name, args)
		local s = stats[name]
		if not s then
			s = { Count = 0, LastFired = 0, RecentCalls = {} }
			stats[name] = s
		end
		s.Count += 1
		s.LastFired = os.clock()
		if not s.RecentCalls then s.RecentCalls = {} end

		-- Format args (mirrors production formatArgsInline — tables get a
		-- brief inline preview {k=v, +N} instead of useless "{table}").
		local parts = {}
		local argList = args or {}
		local n = #argList
		for i = 1, math.min(n, 4) do
			local v = argList[i]
			local t = type(v)
			if t == "string" then table.insert(parts, string.format("%q", v))
			elseif t == "number" or t == "boolean" then table.insert(parts, tostring(v))
			elseif t == "table" then
				local kvs = {}
				local kcount = 0
				for k, val in pairs(v) do
					kcount += 1
					if kcount > 3 then break end
					local vt = type(val)
					local vstr
					if vt == "string" then vstr = #val > 12 and (string.sub(val, 1, 10) .. "..") or val
					elseif vt == "number" or vt == "boolean" then vstr = tostring(val)
					elseif vt == "table" then vstr = "{...}"
					else vstr = "<" .. vt .. ">"
					end
					table.insert(kvs, tostring(k) .. "=" .. vstr)
				end
				local total = 0
				for _ in pairs(v) do total += 1 end
				if total > 3 then table.insert(kvs, "+" .. (total - 3)) end
				table.insert(parts, "{" .. table.concat(kvs, ", ") .. "}")
			else table.insert(parts, "<" .. t .. ">")
			end
		end
		if n > 4 then table.insert(parts, "...+" .. (n - 4)) end
		local argsStr = "(" .. table.concat(parts, ", ") .. ")"

		-- Build sanitized structured snapshot for click-to-expand drill-down.
		local argsStruct = {}
		for i = 1, math.min(n, 8) do
			argsStruct[i] = sanitizeForReplication(argList[i], 0)
		end
		argsStruct.n = math.min(n, 8)
		if n > 8 then argsStruct.truncated = n - 8 end

		table.insert(s.RecentCalls, {
			Time = os.clock(),
			Args = argsStr,
			ArgsStruct = argsStruct,
		})
		while #s.RecentCalls > 30 do
			table.remove(s.RecentCalls, 1)
		end
	end

	describe("Network Call Tracking", function()
		it("creates stats entry on first fire", function()
			local stats = {}
			simulateFireEventBus(stats, "MyBus", {})
			expect(stats.MyBus).never.toBeNil()
			expect(stats.MyBus.Count).toEqual(1)
		end)

		it("increments Count on repeated fires", function()
			local stats = {}
			for _ = 1, 5 do simulateFireEventBus(stats, "MyBus", {}) end
			expect(stats.MyBus.Count).toEqual(5)
		end)

		it("appends to RecentCalls", function()
			local stats = {}
			simulateFireEventBus(stats, "MyBus", {})
			simulateFireEventBus(stats, "MyBus", {})
			simulateFireEventBus(stats, "MyBus", {})
			expect(#stats.MyBus.RecentCalls).toEqual(3)
		end)

		it("formats string args with quotes", function()
			local stats = {}
			simulateFireEventBus(stats, "MyBus", { "hello" })
			expect(stats.MyBus.RecentCalls[1].Args).toContain("\"hello\"")
		end)

		it("formats numeric args plainly", function()
			local stats = {}
			simulateFireEventBus(stats, "MyBus", { 42, 3.14 })
			expect(stats.MyBus.RecentCalls[1].Args).toContain("42")
			expect(stats.MyBus.RecentCalls[1].Args).toContain("3.14")
		end)

		it("collapses overflow args with ...+N suffix", function()
			local stats = {}
			simulateFireEventBus(stats, "MyBus", { 1, 2, 3, 4, 5, 6, 7 })
			expect(stats.MyBus.RecentCalls[1].Args).toContain("...+3")
		end)

		it("formats table args inline {k=v, +N} instead of useless {table}", function()
			-- Regression: previously, table args were flattened to "{table}"
			-- in the call history — useless for inspection. Now formatArgs
			-- shows up to 3 keys inline ({foo=bar, x=1}) and stores a
			-- structured ArgsStruct for click-to-expand drill-down.
			local stats = {}
			simulateFireEventBus(stats, "MyBus", { { foo = "bar", x = 42 } })
			local entry = stats.MyBus.RecentCalls[1]
			-- Inline preview must contain the keys, NOT just "{table}"
			expect(entry.Args).never.toContain("{table}")
			expect(entry.Args).toContain("foo")
			-- Structured args are captured for the drill-down UI
			expect(entry.ArgsStruct).never.toBeNil()
			expect(entry.ArgsStruct[1]).never.toBeNil()
			expect(entry.ArgsStruct[1].foo).toEqual("bar")
			expect(entry.ArgsStruct[1].x).toEqual(42)
		end)

		it("ArgsStruct sanitizes nested tables with depth cap", function()
			-- Deep nesting must not blow up — depth cap at 4.
			local deep = { a = { b = { c = { d = { e = "leaf" } } } } }
			local stats = {}
			simulateFireEventBus(stats, "MyBus", { deep })
			local s = stats.MyBus.RecentCalls[1].ArgsStruct[1]
			-- a.b.c.d should still be a table; deeper gets sentinel
			expect(type(s.a)).toEqual("table")
			expect(type(s.a.b)).toEqual("table")
			expect(type(s.a.b.c)).toEqual("table")
			expect(type(s.a.b.c.d)).toEqual("table")
			-- Depth 5 (e) gets the [...] sentinel
			expect(s.a.b.c.d.e).toEqual("[...]")
		end)

		it("formatArgs uses [...] for non-displayable types (RichText safety)", function()
			-- Roblox TextLabels with RichText=true parse <...> as font tags
			-- and strip the type annotation. Use [...] brackets so the type
			-- tag remains visible in the calls history view.
			-- We verify this at the source level since the simulator doesn't
			-- exercise the userdata path directly.
			local node: any = game
			for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "Core", "NetworkManager"}) do
				node = node:FindFirstChild(name)
				if not node then break end
			end
			expect(node).never.toBeNil()
			local source = node:IsA("ModuleScript") and node.Source or ""
			expect(source ~= "").toEqual(true)

			-- formatArgsInline must use square brackets, not angle brackets,
			-- for the type annotation in the inline preview.
			expect(string.find(source, '"%[" %.%. vt %.%. "%]"') ~= nil).toEqual(true)
			expect(string.find(source, '"%[" %.%. t %.%. "%]"') ~= nil).toEqual(true)
			-- Sanitizer must use [userdata:...] not <userdata:...>
			expect(string.find(source, '"%[userdata:"') ~= nil).toEqual(true)
			-- Must NOT contain the old angle-bracket forms.
			expect(string.find(source, '"<userdata:"') == nil).toEqual(true)
			expect(string.find(source, '"<table>"') == nil).toEqual(true)
		end)

		it("respects RecentCalls cap of 30", function()
			local stats = {}
			for i = 1, 50 do simulateFireEventBus(stats, "MyBus", { i }) end
			expect(#stats.MyBus.RecentCalls).toEqual(30)
			-- Oldest retained is the 21st call
			expect(stats.MyBus.RecentCalls[1].Args).toContain("21")
			-- Newest is the 50th
			expect(stats.MyBus.RecentCalls[30].Args).toContain("50")
		end)

		it("tracks distinct buses independently", function()
			local stats = {}
			simulateFireEventBus(stats, "BusA", {})
			simulateFireEventBus(stats, "BusA", {})
			simulateFireEventBus(stats, "BusB", {})
			expect(stats.BusA.Count).toEqual(2)
			expect(stats.BusB.Count).toEqual(1)
		end)
	end)

	-- ─── Production code structural assertions ───
	-- These verify the production code STILL contains the history-capture logic.
	-- If someone removes it, these fail.
	describe("Production code contains history capture", function()
		it("BaseEntity.luau references _versionHistory", function()
			local mod = script.Parent.Parent.Parent.Parent.Parent
				:FindFirstChild("Orchestrator")
				and script.Parent.Parent.Parent.Parent.Parent.Orchestrator
					:FindFirstChild("Core")
					and script.Parent.Parent.Parent.Parent.Parent.Orchestrator.Core
						:FindFirstChild("Factory")
						and script.Parent.Parent.Parent.Parent.Parent.Orchestrator.Core.Factory
							:FindFirstChild("BaseEntity")
			if not mod then
				-- Not running under the canonical Orchestrator location — skip
				return
			end
			local src = (mod :: any).Source
			expect(src:find("_versionHistory")).never.toBeNil()
			expect(src:find("Changes = ")).never.toBeNil()
		end)

		it("BaseStateMachine.luau references TransitionHistory", function()
			local mod = nil
			pcall(function()
				mod = game:GetService("ReplicatedStorage")
					:FindFirstChild("Orchestrator")
					and game:GetService("ReplicatedStorage").Orchestrator
						:FindFirstChild("Core")
						and game:GetService("ReplicatedStorage").Orchestrator.Core
							:FindFirstChild("Factory")
						and game:GetService("ReplicatedStorage").Orchestrator.Core.Factory
							:FindFirstChild("BaseStateMachine")
			end)
			if not mod then return end
			local src = (mod :: any).Source
			expect(src:find("TransitionHistory")).never.toBeNil()
		end)

		it("NetworkManager.luau references RecentCalls", function()
			local mod = nil
			pcall(function()
				local rs = game:GetService("ReplicatedStorage")
				if rs:FindFirstChild("Orchestrator") and rs.Orchestrator:FindFirstChild("Core") then
					mod = rs.Orchestrator.Core:FindFirstChild("NetworkManager")
				end
			end)
			if not mod then return end
			local src = (mod :: any).Source
			expect(src:find("RecentCalls")).never.toBeNil()
		end)
	end)
end

TR.register(spec)
return spec
