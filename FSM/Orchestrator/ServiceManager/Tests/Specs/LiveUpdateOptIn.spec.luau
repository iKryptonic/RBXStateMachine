--!strict
-- @Name ServiceManager/Tests/Specs/LiveUpdateOptIn.spec.luau
-- @Author iKrypto
-- @Description Source-level guard tests for the LiveUpdate opt-in flag that
-- determines whether ServiceBrain rebuilds drill-down layers each tick. The
-- LiveUpdate convention is shared between ServiceBrain (which gates the rebuild)
-- and FSMModule._BuildGraphLayer (which sets the flag based on PlaybackMode).
-- Without these in lockstep, the visualizer's live mode silently doesn't update.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local function getSource(modulePath: { string }): string
		local node: any = game
		for _, name in ipairs(modulePath) do
			node = node:FindFirstChild(name)
			if not node then return "" end
		end
		return node:IsA("ModuleScript") and node.Source or ""
	end

	describe("ServiceBrain LiveUpdate opt-in (source-level guards)", function()
		it("ServiceBrain skips drill-down rebuilds without LiveUpdate", function()
			local source = getSource({"ReplicatedStorage", "Orchestrator", "ServiceManager", "ServiceBrain"})
			expect(source ~= "").toEqual(true)
			-- The brain must check Context.LiveUpdate before rebuilding depth>0 layers.
			expect(string.find(source, "LiveUpdate") ~= nil).toEqual(true)
			-- And it must early-return for non-LiveUpdate drill-downs.
			expect(string.find(source, "if not liveOptIn then") ~= nil
				or string.find(source, "if not %(?liveOptIn") ~= nil).toEqual(true)
		end)

		it("FSMModule._BuildGraphLayer sets Context.LiveUpdate from PlaybackMode", function()
			local source = getSource({"ReplicatedStorage", "Orchestrator", "ServiceManager", "Subsystems", "FSMModule"})
			expect(source ~= "").toEqual(true)
			-- The visualizer must opt-in to live updates when in live mode.
			expect(string.find(source, "context%.LiveUpdate") ~= nil).toEqual(true)
			expect(string.find(source, "PlaybackMode == \"live\"") ~= nil).toEqual(true)
		end)

		it("ZAxisNavigator.RebuildCurrentLayer mutates layer.Context in place (no fresh table)", function()
			local source = getSource({"ReplicatedStorage", "Orchestrator", "ServiceManager", "ZAxisNavigator"})
			expect(source ~= "").toEqual(true)
			-- The mutate-in-place fix is critical for visualizer step persistence.
			-- Sentinel: comment block we wrote when fixing the bug.
			expect(string.find(source, "mutate%-in%-place") ~= nil
				or string.find(source, "mutates `layer%.Context`") ~= nil
				or string.find(source, "canonical reference") ~= nil).toEqual(true)
			-- Negative: must NOT contain the old `mergedCtx` pattern.
			expect(string.find(source, "local mergedCtx") == nil).toEqual(true)
		end)

		it("FSMModule._BuildContextEntryRow drills into nested tables (interactable [Table] entries)", function()
			-- Regression: previously, nested tables in ContextSnapshot showed
			-- as "[Table]" — useless for inspection. Now the sanitizer
			-- recursively preserves structure (depth ≤ 3) and the dashboard
			-- renders table-typed entries as click-to-expand buttons.
			local source = getSource({"ReplicatedStorage", "Orchestrator", "ServiceManager", "Subsystems", "FSMModule"})
			expect(source ~= "").toEqual(true)
			expect(string.find(source, "_BuildContextEntryRow") ~= nil).toEqual(true)
			-- Must have the resize listener for the graph container.
			expect(string.find(source, "GetPropertyChangedSignal%(\"AbsoluteSize\"%)") ~= nil).toEqual(true)
			expect(string.find(source, "_lastResizeRebuild") ~= nil).toEqual(true)
		end)

		it("BaseStateMachine sanitize recursively preserves table structure (no [Table] stub)", function()
			local source = getSource({"ReplicatedStorage", "Orchestrator", "Core", "Factory", "BaseStateMachine"})
			expect(source ~= "").toEqual(true)
			-- The sanitizer must recurse with depth cap, not collapse tables.
			expect(string.find(source, "MAX_DEPTH") ~= nil).toEqual(true)
			expect(string.find(source, "describeClassy") ~= nil).toEqual(true)
			-- Depth cap must allow deep drill-down (≥ 8 levels) since
			-- the inline tree expander supports arbitrary depth via
			-- shift-on-expand and the prior cap of 3 was too shallow
			-- for real-world entity graphs.
			expect(string.find(source, "MAX_DEPTH = 8") ~= nil
				or string.find(source, "MAX_DEPTH%s*=%s*[89]") ~= nil
				or string.find(source, "MAX_DEPTH%s*=%s*1%d") ~= nil).toEqual(true)
		end)

		it("FSMModule._BuildContextEntryRow uses live row.LayoutOrder (not stale capture)", function()
			-- Regression: when expanding a sibling row B AFTER a sibling row A
			-- (where A precedes B), B's row.LayoutOrder shifts but the captured
			-- `layoutOrder` parameter stays stale. Using the captured value
			-- as the shift gate caused B to shift itself, putting it BELOW
			-- its own children. The fix reads row.LayoutOrder live inside
			-- the click handler.
			local source = getSource({"ReplicatedStorage", "Orchestrator", "ServiceManager", "Subsystems", "FSMModule"})
			expect(source ~= "").toEqual(true)
			-- Must capture live order at click time.
			expect(string.find(source, "local myOrder = row%.LayoutOrder") ~= nil).toEqual(true)
			-- Must use myOrder (not layoutOrder) inside the click closure
			-- shift gates.
			expect(string.find(source, "c%.LayoutOrder > myOrder") ~= nil).toEqual(true)
		end)

		it("FSMModule._BuildContextEntryRow propagates ALL ancestor subtrees (cascade collapse)", function()
			-- Regression: the prior implementation passed only the IMMEDIATE
			-- parent's subtree to children. Grandchildren registered only in
			-- their direct parent's subtree, so collapsing a grandparent
			-- left grandchildren orphaned in the DOM. The fix passes a list
			-- of every ancestor subtree down the chain; descendants register
			-- in all of them.
			local source = getSource({"ReplicatedStorage", "Orchestrator", "ServiceManager", "Subsystems", "FSMModule"})
			expect(source ~= "").toEqual(true)
			expect(string.find(source, "ancestorSubtrees") ~= nil).toEqual(true)
			expect(string.find(source, "descentSubtrees") ~= nil).toEqual(true)
		end)

		it("ConsoleModule resets _lastRenderCount when rebuilding OutputScroll (no stale watermark)", function()
			-- Regression: the console output buffer is preserved across
			-- context switches and navigator drops, but _RenderOutput()
			-- uses an incremental watermark (_lastRenderCount). When
			-- BuildRootLayer rebuilds the OutputScroll fresh (e.g., on
			-- NavigateToRoot during context switch), the watermark stayed
			-- at its previous value, so _RenderOutput() bailed out with
			-- "already rendered N lines" — leaving the new scroll frame
			-- empty even though the buffer was intact. The fix resets
			-- _lastRenderCount = 0 right after assigning the new scroll.
			local source = getSource({"ReplicatedStorage", "Orchestrator", "ServiceManager", "Subsystems", "ConsoleModule"})
			expect(source ~= "").toEqual(true)
			-- Must explicitly reset the watermark in BuildRootLayer when
			-- a fresh OutputScroll is created.
			expect(string.find(source, "self%._scrollFrame = outputScroll") ~= nil).toEqual(true)
			-- The reset must occur at the point where the scroll is built
			-- (so that subsequent _RenderOutput() repopulates from buffer).
			local scrollAssignIdx = string.find(source, "self%._scrollFrame = outputScroll")
			expect(scrollAssignIdx ~= nil).toEqual(true)
			-- Look for the watermark reset within ~600 chars after the assignment.
			local windowEnd = math.min(#source, (scrollAssignIdx or 1) + 600)
			local window = string.sub(source, (scrollAssignIdx or 1), windowEnd)
			expect(string.find(window, "self%._lastRenderCount = 0") ~= nil).toEqual(true)
		end)
	end)
end

TR.register(spec)
return spec
