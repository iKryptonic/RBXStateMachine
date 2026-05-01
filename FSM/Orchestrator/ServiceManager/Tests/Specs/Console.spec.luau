--!strict
-- @Name ServiceManager/Tests/Specs/Console.spec.luau
-- @Author iKrypto

local TR = require(script.Parent.Parent.TestRunner)
local MockNexus = require(script.Parent.Parent.Mocks.MockNexus)
local MockOrchestrator = require(script.Parent.Parent.Mocks.MockOrchestrator)
local ConsoleModule = require(script.Parent.Parent.Parent.Subsystems.ConsoleModule)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("ConsoleModule", function()
	describe("Built-in commands", function()
		it("registers 12+ built-in commands", function()
			local mod = ConsoleModule.new()
			local count = 0
			for _ in pairs(mod._registeredCommands) do count += 1 end
			expect(count).toBeGreaterThan(11)
		end)

		it("includes core commands: help, clear, echo, version, mode, tasks, fsm, entities, network, perf, switch", function()
			local mod = ConsoleModule.new()
			for _, cmdName in ipairs({"help","clear","echo","version","mode","tasks","fsm","entities","network","perf","switch"}) do
				expect(mod._registeredCommands[cmdName]).never.toBeNil()
			end
		end)
	end)

	describe("Autocomplete", function()
		it("_GetCompletions returns prefix matches", function()
			local mod = ConsoleModule.new()
			local matches = mod:_GetCompletions("he")
			expect(#matches).toBeGreaterThan(0)
			expect(matches).toContain("help")
		end)

		it("returns empty array on empty input", function()
			local mod = ConsoleModule.new()
			local matches = mod:_GetCompletions("")
			expect(#matches).toEqual(0)
		end)

		it("returns empty array on no match", function()
			local mod = ConsoleModule.new()
			local matches = mod:_GetCompletions("zzznotacommand")
			expect(#matches).toEqual(0)
		end)

		it("returns alphabetically sorted matches", function()
			local mod = ConsoleModule.new()
			local matches = mod:_GetCompletions("e")
			-- Should include "echo" and "entities"
			expect(#matches).toBeGreaterThan(1)
			expect(matches[1] < matches[2]).toBeTruthy()
		end)
	end)

	describe("ExecuteCommand", function()
		it("echoes the command to the output buffer", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			mod:ExecuteCommand("help", nexus)
			-- buffer should have at least: echoed cmd + result lines
			expect(#mod._outputBuffer).toBeGreaterThan(1)
			-- First line should contain the command we typed
			local found = false
			for _, line in ipairs(mod._outputBuffer) do
				if line.Text:find("help") then found = true; break end
			end
			expect(found).toBeTruthy()
		end)

		it("rejects unknown commands with error", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			mod:ExecuteCommand("notarealcommand", nexus)
			local foundError = false
			for _, line in ipairs(mod._outputBuffer) do
				if line.Level == "ERROR" then foundError = true; break end
			end
			expect(foundError).toBeTruthy()
		end)

		it("adds executed commands to history", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			expect(#mod._commandHistory).toEqual(0)
			mod:ExecuteCommand("help", nexus)
			expect(#mod._commandHistory).toEqual(1)
			expect(mod._commandHistory[1]).toEqual("help")
		end)

		it("ignores empty input", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			mod:ExecuteCommand("", nexus)
			expect(#mod._commandHistory).toEqual(0)
		end)

		it("trims whitespace via gmatch parsing", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			mod:ExecuteCommand("  echo  hi  ", nexus)
			-- Should have echoed "hi" as result
			local foundResult = false
			for _, line in ipairs(mod._outputBuffer) do
				if line.Level == "RESULT" and line.Text:find("hi") then foundResult = true; break end
			end
			expect(foundResult).toBeTruthy()
		end)

		it("clear command empties the buffer", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			mod:ExecuteCommand("help", nexus)
			expect(#mod._outputBuffer).toBeGreaterThan(0)
			mod:ExecuteCommand("clear", nexus)
			-- After clear, only the system message remains
			expect(#mod._outputBuffer).toBeLessThan(5)
		end)
	end)

	describe("Built-in command behavior", function()
		it("tasks list returns no-tasks message when scheduler is empty", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new({ tasks = {} }) })
			mod:ExecuteCommand("tasks list", nexus)
			local found = false
			for _, line in ipairs(mod._outputBuffer) do
				if line.Text:find("no tasks") then found = true; break end
			end
			expect(found).toBeTruthy()
		end)

		it("tasks list prints registered tasks", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({
					tasks = {
						MyTask = MockOrchestrator.makeTask("MyTask", { status = "running" }),
					},
				}),
			})
			mod:ExecuteCommand("tasks list", nexus)
			local found = false
			for _, line in ipairs(mod._outputBuffer) do
				if line.Text:find("MyTask") then found = true; break end
			end
			expect(found).toBeTruthy()
		end)

		it("fsm list prints state machine summary", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({
					fsms = {
						MyFSM = MockOrchestrator.makeFSM("MyFSM", { state = "Running" }),
					},
				}),
			})
			mod:ExecuteCommand("fsm list", nexus)
			local found = false
			for _, line in ipairs(mod._outputBuffer) do
				if line.Text:find("MyFSM") then found = true; break end
			end
			expect(found).toBeTruthy()
		end)

		it("switch validates subsystem names (case-insensitive)", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			mod:ExecuteCommand("switch tasks", nexus)
			expect(nexus._activeSubsystem).toEqual("TASKS")
			mod:ExecuteCommand("switch FSM", nexus)
			expect(nexus._activeSubsystem).toEqual("FSM")
		end)

		it("switch rejects invalid subsystem", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			local before = nexus._activeSubsystem
			mod:ExecuteCommand("switch nonexistent", nexus)
			-- nexus subsystem unchanged
			expect(nexus._activeSubsystem).toEqual(before)
		end)

		it("mode without args prints current mode", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ contextMode = "client", orchestrator = MockOrchestrator.new() })
			mod:ExecuteCommand("mode", nexus)
			local found = false
			for _, line in ipairs(mod._outputBuffer) do
				if line.Text:find("client") then found = true; break end
			end
			expect(found).toBeTruthy()
		end)

		it("mode server switches context", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ contextMode = "client", orchestrator = MockOrchestrator.new() })
			mod:ExecuteCommand("mode server", nexus)
			expect(nexus._contextMode).toEqual("server")
		end)
	end)

	describe("History buffer", function()
		it("respects MAX_HISTORY cap", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
			for i = 1, 150 do
				mod:ExecuteCommand("help", nexus)
			end
			-- MAX_HISTORY is 100
			expect(#mod._commandHistory).toBeLessThan(101)
		end)
	end)

	describe("Smart Autocomplete (position-aware)", function()
		it("token 1: suggests command names matching prefix", function()
			local mod = ConsoleModule.new()
			local results = mod:_GetSmartCompletions("hel", nil)
			expect(#results).toBeGreaterThan(0)
			local found = false
			for _, r in ipairs(results) do
				if r.text == "help" then found = true; break end
			end
			expect(found).toBeTruthy()
		end)

		it("token 1 suggestions include hint (description)", function()
			local mod = ConsoleModule.new()
			local results = mod:_GetSmartCompletions("hel", nil)
			expect(results[1].hint).never.toBeNil()
		end)

		it("token 2 with trailing space: suggests subcommands", function()
			local mod = ConsoleModule.new()
			local results = mod:_GetSmartCompletions("tasks ", nil)
			local subs = {}
			for _, r in ipairs(results) do table.insert(subs, r.text) end
			expect(subs).toContain("list")
			expect(subs).toContain("info")
			expect(subs).toContain("run")
			expect(subs).toContain("kill")
		end)

		it("token 2 with prefix: filters subcommands", function()
			local mod = ConsoleModule.new()
			local results = mod:_GetSmartCompletions("tasks li", nil)
			-- Should only match "list"
			expect(#results).toBeGreaterThan(0)
			expect(results[1].text).toEqual("list")
		end)

		it("token 3: dynamic provider yields task names", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({
					tasks = {
						MyTaskAlpha = MockOrchestrator.makeTask("MyTaskAlpha"),
						OtherTask = MockOrchestrator.makeTask("OtherTask"),
					},
				}),
			})
			local results = mod:_GetSmartCompletions("tasks info My", nexus)
			expect(#results).toBeGreaterThan(0)
			local found = false
			for _, r in ipairs(results) do
				if r.text == "MyTaskAlpha" then found = true; break end
			end
			expect(found).toBeTruthy()
		end)

		it("token 3: dynamic provider yields fsm ids", function()
			local mod = ConsoleModule.new()
			local nexus = MockNexus.new({
				orchestrator = MockOrchestrator.new({
					fsms = {
						DoorFSM = MockOrchestrator.makeFSM("DoorFSM"),
						WindowFSM = MockOrchestrator.makeFSM("WindowFSM"),
					},
				}),
			})
			local results = mod:_GetSmartCompletions("fsm cancel ", nexus)
			expect(#results).toEqual(2)
		end)

		it("scores prefix match higher than substring match", function()
			local mod = ConsoleModule.new()
			-- "hel" should rank "help" before any other command containing 'hel'
			local results = mod:_GetSmartCompletions("hel", nil)
			expect(results[1].text).toEqual("help")
		end)

		it("returns empty list for completely unknown query", function()
			local mod = ConsoleModule.new()
			local results = mod:_GetSmartCompletions("zzznonexistentxxx", nil)
			expect(#results).toEqual(0)
		end)

		it("subcommand for switch returns subsystem names", function()
			local mod = ConsoleModule.new()
			local results = mod:_GetSmartCompletions("switch ", nil)
			local names = {}
			for _, r in ipairs(results) do table.insert(names, r.text) end
			expect(names).toContain("tasks")
			expect(names).toContain("fsm")
			expect(names).toContain("logs")
		end)
	end)

	describe("Match highlighting", function()
		it("wraps matched prefix in <u><b>", function()
			local mod = ConsoleModule.new()
			local result = mod:_HighlightMatch("HelloWorld", "Hello")
			expect(result).toContain("<u><b>Hello</b></u>")
		end)

		it("wraps matched substring", function()
			local mod = ConsoleModule.new()
			local result = mod:_HighlightMatch("FooBarBaz", "Bar")
			expect(result).toContain("<u><b>Bar</b></u>")
		end)

		it("returns candidate unchanged when no match", function()
			local mod = ConsoleModule.new()
			local result = mod:_HighlightMatch("Hello", "xyz")
			expect(result).toEqual("Hello")
		end)

		it("returns candidate unchanged when query is empty", function()
			local mod = ConsoleModule.new()
			local result = mod:_HighlightMatch("Hello", "")
			expect(result).toEqual("Hello")
		end)
	end)

	describe("Output buffer", function()
		it("respects MAX_OUTPUT_LINES cap", function()
			local mod = ConsoleModule.new()
			for i = 1, 600 do
				mod:_PushLine("INFO", "line " .. i)
			end
			expect(#mod._outputBuffer).toBeLessThan(501)
		end)
	end)

	-- ── Render-pipeline integration tests ─────────────────────────────
	-- These tests catch a class of bug that pure logic-level tests can't:
	-- the render watermark (_lastRenderCount) is an incremental optimization
	-- that assumes the OutputScroll frame still holds the labels it counted.
	-- When the navigator destroys the layer's container (e.g., on context
	-- switch / NavigateToRoot) and ConsoleModule:BuildRootLayer rebuilds the
	-- OutputScroll fresh, the watermark goes stale — _RenderOutput would
	-- early-exit with "already rendered N" against an empty new scroll,
	-- making the console appear cleared. Pure-logic tests miss this because
	-- they never build a real Frame and never destroy/rebuild it.
	describe("Render pipeline (frame lifecycle)", function()
		local function buildContainer(): Frame
			local sg = Instance.new("ScreenGui")
			sg.Parent = game:GetService("CoreGui")
			local content = Instance.new("ScrollingFrame")
			content.Name = "Content"
			content.Size = UDim2.new(0, 400, 0, 300)
			content.Parent = sg
			local outer = Instance.new("Frame")
			outer.Name = "OuterLayer"
			outer.Size = UDim2.new(1, 0, 1, 0)
			content.Parent = outer
			outer.Parent = sg
			return outer
		end

		local function findScroll(outer: Frame): ScrollingFrame?
			local content = outer:FindFirstChild("Content")
			return content and content:FindFirstChild("OutputScroll") :: ScrollingFrame?
		end

		local function countLabels(scroll: ScrollingFrame?): number
			if not scroll then return 0 end
			local n = 0
			for _, c in ipairs(scroll:GetChildren()) do
				if c:IsA("TextLabel") then n += 1 end
			end
			return n
		end

		it("BuildRootLayer renders pre-existing buffer lines into a fresh scroll", function()
			local mod = ConsoleModule.new()
			-- Push lines BEFORE any layer is built — this is the exact pattern
			-- of context-switch divider lines + persisted history lines.
			for i = 1, 5 do
				mod:_PushLine("INFO", "pre-build line " .. i)
			end

			local outer = buildContainer()
			mod:BuildRootLayer(outer, { Nexus = MockNexus.new() })

			local scroll = findScroll(outer)
			expect(scroll).never.toBeNil()
			-- Lines pushed BEFORE BuildRootLayer must appear in the scroll.
			-- Plus the 3-line banner that BuildRootLayer's first-run path adds
			-- when the buffer is empty — but here it's NOT empty so banner is skipped.
			expect(countLabels(scroll)).toEqual(5)

			outer.Parent:Destroy()
		end)

		it("rebuilding the layer (simulating NavigateToRoot) re-renders all buffer lines", function()
			-- This is the EXACT bug scenario: layer is built, lines accumulate,
			-- then NavigateToRoot destroys the layer's frame and rebuilds it.
			-- Without the _lastRenderCount reset, the new scroll stays empty.
			local mod = ConsoleModule.new()

			-- Seed the buffer BEFORE first build so we have predictable content.
			for i = 1, 7 do
				mod:_PushLine("INFO", "persistent line " .. i)
			end

			-- First build — _RenderOutput is called at end of BuildRootLayer
			-- and renders all 7 lines. _lastRenderCount becomes 7.
			local outer1 = buildContainer()
			mod:BuildRootLayer(outer1, { Nexus = MockNexus.new() })
			local scroll1 = findScroll(outer1)
			expect(scroll1).never.toBeNil()
			local rendered1 = countLabels(scroll1)
			expect(rendered1).toEqual(7)

			-- Destroy the entire container — mimics what ZAxisNavigator does
			-- on NavigateToRoot. The OutputScroll is gone but the module's
			-- _outputBuffer + _lastRenderCount are untouched.
			outer1.Parent:Destroy()

			-- Rebuild on a fresh container — _scrollFrame must be reset and
			-- _RenderOutput must repopulate the new scroll.
			local outer2 = buildContainer()
			mod:BuildRootLayer(outer2, { Nexus = MockNexus.new() })
			local scroll2 = findScroll(outer2)
			expect(scroll2).never.toBeNil()
			-- THIS is the assertion that was failing before the fix:
			-- the new scroll must contain all 7 buffered lines.
			expect(countLabels(scroll2)).toEqual(7)

			outer2.Parent:Destroy()
		end)

		it("multiple consecutive rebuilds keep all buffer lines visible (context-switch loop)", function()
			-- Simulates the user toggling client ↔ server repeatedly.
			-- Each toggle calls NavigateToRoot which rebuilds the layer.
			local mod = ConsoleModule.new()
			for i = 1, 8 do
				mod:_PushLine("INFO", "persistent line " .. i)
			end

			local previous: ScreenGui? = nil
			for cycle = 1, 4 do
				local outer = buildContainer()
				mod:BuildRootLayer(outer, { Nexus = MockNexus.new() })
				local scroll = findScroll(outer)
				expect(scroll).never.toBeNil()
				-- Every rebuild must render exactly 8 lines (no growth, no loss).
				expect(countLabels(scroll)).toEqual(8)
				if previous then previous:Destroy() end
				previous = outer.Parent :: ScreenGui
			end
			if previous then previous:Destroy() end
		end)

		it("inputBox auto-strips leading whitespace (defensive against platform input quirks)", function()
			-- Regression: real users reported a leading space appearing in the
			-- command bar after pressing Enter, which broke autocomplete on
			-- the next input (token 1 became "" so suggestions were wrong).
			-- The exact platform-input race that injects the space couldn't
			-- be reproduced synthetically, but a defensive strip in the Text
			-- changed signal eliminates the symptom regardless of cause.
			local mod = ConsoleModule.new()
			local outer = buildContainer()
			mod:BuildRootLayer(outer, { Nexus = MockNexus.new() })

			local inputBar = outer:FindFirstChild("Content")
				and outer.Content:FindFirstChild("InputBar")
			expect(inputBar).never.toBeNil()
			local inputBox = inputBar:FindFirstChild("CommandInput") :: TextBox
			expect(inputBox).never.toBeNil()

			-- Simulate the bug: text appears with a leading space.
			inputBox.Text = " help"
			-- Yield once so the GetPropertyChangedSignal listener runs.
			task.wait()
			expect(inputBox.Text).toEqual("help")

			-- Multiple leading spaces should also be stripped.
			inputBox.Text = "   ver"
			task.wait()
			expect(inputBox.Text).toEqual("ver")

			-- Internal/trailing spaces are preserved (legitimate for command args).
			inputBox.Text = "echo hello world"
			task.wait()
			expect(inputBox.Text).toEqual("echo hello world")

			-- A single trailing space (used for "ready for next token" autocomplete) is preserved.
			inputBox.Text = "tasks "
			task.wait()
			expect(inputBox.Text).toEqual("tasks ")

			outer.Parent:Destroy()
		end)

		it("FocusLost(enterPressed=true) trims whitespace before executing command", function()
			-- Defense-in-depth: even if leading whitespace somehow slips past
			-- the GetPropertyChangedSignal strip, the FocusLost handler also
			-- trims so the executed command and history entry are clean.
			local mod = ConsoleModule.new()
			local outer = buildContainer()
			mod:BuildRootLayer(outer, { Nexus = MockNexus.new() })

			local inputBox = outer.Content.InputBar.CommandInput :: TextBox

			-- Focus first so ReleaseFocus(true) actually fires FocusLost.
			inputBox:CaptureFocus()
			task.wait(0.1)
			-- After CaptureFocus, set padded text. The property-changed listener
			-- will strip leading whitespace; trailing remains until FocusLost.
			inputBox.Text = "  help  "
			task.wait(0.05)
			inputBox:ReleaseFocus(true)
			task.wait(0.2)

			-- The history must record the trimmed form, not the padded one.
			local lastCmd = mod._commandHistory[#mod._commandHistory]
			expect(lastCmd).toEqual("help")

			outer.Parent:Destroy()
		end)

		it("post-Enter recapture is delayed by a frame to avoid in-flight key race", function()
			-- Source-level guard: the FocusLost(enterPressed=true) handler must
			-- defer CaptureFocus by at least ONE FULL FRAME (task.delay(0)
			-- rather than task.defer) so Roblox's input pipeline finishes
			-- routing the in-flight Enter key BEFORE the box is re-focused.
			-- task.defer can run in the same frame, before the Enter key has
			-- been consumed — leading to the key being applied to the freshly
			-- re-focused box and inserting a stray character.
			local node: any = game
			for _, name in ipairs({"ReplicatedStorage", "Orchestrator", "ServiceManager", "Subsystems", "ConsoleModule"}) do
				node = node:FindFirstChild(name)
				if not node then break end
			end
			expect(node).never.toBeNil()
			local source = node:IsA("ModuleScript") and node.Source or ""
			expect(source ~= "").toEqual(true)

			-- Must use task.delay(0, ...) for refocus, NOT task.defer.
			expect(string.find(source, "task%.delay%(0, function%(%)%s*if inputBox") ~= nil).toEqual(true)
			-- Must mark _postEnterRefocus so the Focused handler can scrub.
			expect(string.find(source, "self%._postEnterRefocus = true") ~= nil).toEqual(true)
			-- Focused handler must check _postEnterRefocus and clean leading whitespace.
			expect(string.find(source, "if self%._postEnterRefocus then") ~= nil).toEqual(true)
		end)
	end)
end)

end -- close spec function

TR.register(spec)
return spec
