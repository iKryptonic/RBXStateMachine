--!strict
-- @Name ServiceManager/Tests/Specs/ZAxisNavigator.spec.luau
-- @Author iKrypto
-- @Description Tests for ZAxisNavigator drill-down stack and the recent
-- RebuildCurrentLayer mutate-in-place fix. The fix is critical because
-- click handlers attached during a builder run capture the context table;
-- if RebuildCurrentLayer creates a fresh merged copy, the next click writes
-- to a transient table that's discarded, so visualizer playback step
-- changes (and any other click-driven state) silently get lost.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local Navigator = require(game:GetService("ReplicatedStorage").Orchestrator.ServiceManager.ZAxisNavigator)

	local function makeRoot(): Frame
		local f = Instance.new("Frame")
		f.Size = UDim2.new(0, 600, 0, 400)
		return f
	end

	-- Helper: resets the animation guard between synchronous operations so
	-- tests don't no-op due to a leftover _animating=true from the previous
	-- _AnimateExpand (whose tween hasn't fired its Completed callback yet).
	local function newNav()
		local nav = Navigator.new(makeRoot())
		return nav
	end
	local function settle(nav)
		(nav :: any)._animating = false
	end

	describe("ZAxisNavigator", function()
		describe("RegisterRootLayer + NavigateToRoot", function()
			it("registers a root layer and renders it on NavigateToRoot", function()
				local nav = newNav()
				local builderCalls = 0
				nav:RegisterRootLayer("TASKS", "Tasks", function(_frame, _ctx)
					builderCalls += 1
				end)
				nav:NavigateToRoot("TASKS")
				expect(builderCalls).toEqual(1)
				expect(nav:GetCurrentDepth()).toEqual(0)
				nav:Destroy()
			end)

			it("collapses everything before re-rendering root", function()
				local nav = newNav()
				nav:RegisterRootLayer("TASKS", "Tasks", function() end)
				nav:RegisterRootLayer("FSM", "FSM", function() end)
				nav:NavigateToRoot("TASKS")
				settle(nav)
				nav:ExpandLayer({
					Id = "tasks.detail.X",
					ParentId = "TASKS",
					Label = "X",
					Builder = function() end,
					Context = { K = 1 },
				})
				settle(nav)
				expect(nav:GetCurrentDepth()).toEqual(1)
				nav:NavigateToRoot("FSM")
				expect(nav:GetCurrentDepth()).toEqual(0)
				nav:Destroy()
			end)
		end)

		describe("ExpandLayer", function()
			it("pushes a new drill-down with parent's depth + 1", function()
				local nav = newNav()
				nav:RegisterRootLayer("FSM", "FSM", function() end)
				nav:NavigateToRoot("FSM")
				settle(nav)

				nav:ExpandLayer({
					Id = "fsm.detail.X",
					ParentId = "FSM",
					Label = "X",
					Builder = function() end,
					Context = {},
				})
				settle(nav)
				expect(nav:GetCurrentDepth()).toEqual(1)

				nav:ExpandLayer({
					Id = "fsm.viz.X",
					ParentId = "fsm.detail.X",
					Label = "Graph",
					Builder = function() end,
					Context = {},
				})
				settle(nav)
				expect(nav:GetCurrentDepth()).toEqual(2)
				nav:Destroy()
			end)

			it("invokes the builder with frame + the original context table", function()
				local nav = newNav()
				nav:RegisterRootLayer("FSM", "FSM", function() end)
				nav:NavigateToRoot("FSM")
				settle(nav)

				local seenCtx
				local origCtx = { K = 42, Nested = { A = 1 } }
				nav:ExpandLayer({
					Id = "fsm.detail.X",
					ParentId = "FSM",
					Label = "X",
					Builder = function(_f, ctx) seenCtx = ctx end,
					Context = origCtx,
				})
				settle(nav)
				expect(rawequal(seenCtx, origCtx)).toEqual(true)
				nav:Destroy()
			end)
		end)

		describe("RebuildCurrentLayer mutate-in-place (regression for visualizer stepping)", function()
			it("passes the SAME context reference to the builder on every rebuild", function()
				local nav = newNav()
				nav:RegisterRootLayer("FSM", "FSM", function() end)
				nav:NavigateToRoot("FSM")
				settle(nav)

				local refs = {}
				local origCtx = { Stage = 0 }
				nav:ExpandLayer({
					Id = "fsm.viz.X",
					ParentId = "FSM",
					Label = "Graph",
					Builder = function(_f, ctx)
						refs[#refs + 1] = ctx
					end,
					Context = origCtx,
				})
				settle(nav)

				nav:RebuildCurrentLayer()
				nav:RebuildCurrentLayer()
				nav:RebuildCurrentLayer()

				expect(#refs).toEqual(4)
				expect(rawequal(refs[1], origCtx)).toEqual(true)
				expect(rawequal(refs[2], refs[1])).toEqual(true)
				expect(rawequal(refs[3], refs[1])).toEqual(true)
				expect(rawequal(refs[4], refs[1])).toEqual(true)
				nav:Destroy()
			end)

			it("preserves mutations made by click handlers across rebuilds", function()
				local nav = newNav()
				nav:RegisterRootLayer("FSM", "FSM", function() end)
				nav:NavigateToRoot("FSM")
				settle(nav)

				-- Use a counter table so we don't lose nil entries (table.insert
				-- with nil is a no-op, which previously made the test misleading).
				local seenSteps: { [number]: any } = {}
				local buildCount = 0
				local capturedCtx
				nav:ExpandLayer({
					Id = "fsm.viz.X",
					ParentId = "FSM",
					Label = "Graph",
					Builder = function(_f, ctx)
						buildCount += 1
						seenSteps[buildCount] = ctx.PlaybackStep
						capturedCtx = ctx
					end,
					Context = { PlaybackStep = nil },
				})
				settle(nav)
				expect(buildCount).toEqual(1)
				expect(seenSteps[1]).toEqual(nil)

				capturedCtx.PlaybackStep = 5
				nav:RebuildCurrentLayer()
				expect(buildCount).toEqual(2)
				expect(seenSteps[2]).toEqual(5)

				capturedCtx.PlaybackStep = 10
				nav:RebuildCurrentLayer()
				expect(buildCount).toEqual(3)
				expect(seenSteps[3]).toEqual(10)

				capturedCtx.PlaybackStep = nil
				nav:RebuildCurrentLayer()
				expect(buildCount).toEqual(4)
				expect(seenSteps[4]).toEqual(nil)
				nav:Destroy()
			end)

			it("merges externally-passed keys INTO existing context (does not replace)", function()
				local nav = newNav()
				nav:RegisterRootLayer("FSM", "FSM", function() end)
				nav:NavigateToRoot("FSM")
				settle(nav)

				local lastCtx
				nav:ExpandLayer({
					Id = "fsm.viz.X",
					ParentId = "FSM",
					Label = "Graph",
					Builder = function(_f, ctx) lastCtx = ctx end,
					Context = { Stage = 0, FSMId = "X", LiveUpdate = false },
				})
				settle(nav)

				nav:RebuildCurrentLayer({ Nexus = "PassedIn", Stage = 99 })
				expect(lastCtx.Stage).toEqual(99)
				expect(lastCtx.FSMId).toEqual("X")
				expect(lastCtx.Nexus).toEqual("PassedIn")
				expect(lastCtx.LiveUpdate).toEqual(false)
				nav:Destroy()
			end)

			it("is a no-op when stack is empty", function()
				local nav = newNav()
				nav:RebuildCurrentLayer()
				nav:RebuildCurrentLayer({ Nexus = "X" })
				nav:Destroy()
			end)

			it("initializes layer.Context to {} when missing (root layers don't have Context by default)", function()
				local nav = newNav()
				nav:RegisterRootLayer("TASKS", "Tasks", function() end)
				nav:NavigateToRoot("TASKS")
				settle(nav)
				nav:RebuildCurrentLayer({ Nexus = "X" })
				nav:Destroy()
			end)
		end)

		describe("CollapseToLayer", function()
			it("destroys layers above the target depth", function()
				local nav = newNav()
				nav:RegisterRootLayer("FSM", "FSM", function() end)
				nav:NavigateToRoot("FSM")
				settle(nav)

				nav:ExpandLayer({
					Id = "L1", ParentId = "FSM", Label = "L1",
					Builder = function() end, Context = {},
				})
				settle(nav)
				nav:ExpandLayer({
					Id = "L2", ParentId = "L1", Label = "L2",
					Builder = function() end, Context = {},
				})
				settle(nav)
				expect(nav:GetCurrentDepth()).toEqual(2)
				nav:CollapseToLayer("L1")
				expect(nav:GetCurrentDepth()).toEqual(1)
				nav:Destroy()
			end)
		end)

		describe("Destroy", function()
			it("clears all layers and stack", function()
				local nav = newNav()
				nav:RegisterRootLayer("FSM", "FSM", function() end)
				nav:NavigateToRoot("FSM")
				settle(nav)
				nav:ExpandLayer({
					Id = "L1", ParentId = "FSM", Label = "L1",
					Builder = function() end, Context = {},
				})
				settle(nav)
				nav:Destroy()
				nav:Destroy()
			end)
		end)
	end)
end

TR.register(spec)
return spec
