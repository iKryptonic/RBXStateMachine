--!strict
-- @Name ServiceManager/Tests/Specs/ContextDrillDown.spec.luau
-- @Author iKrypto
-- @Description Behavior tests for the inline expand/collapse tree in the FSM
-- visualizer's step-detail panel. Verifies arbitrary-depth drill-down using the
-- shift-on-expand + subtree tracking algorithm, and the critical bug fix where
-- the click handler must use `row.LayoutOrder` (live) not the captured
-- `layoutOrder` parameter to handle out-of-order sibling expansion.

local TR = require(script.Parent.Parent.TestRunner)

-- Mirror of the production algorithm (FSMModule._BuildContextEntryRow) using
-- plain tables instead of Frames, so the test runs without GUI dependencies.
-- Each "row" is a table { LayoutOrder = number, Children = {row,...} | nil,
-- IsExpanded = bool, Subtree = {row,...}, Value = table | scalar, Key = string,
-- Depth = number, ParentSubtree = {row,...} | nil }.
-- The "parent" is a list of rows. We mirror the live-order fix exactly.

local function buildRow(parentList, key, value, depth, layoutOrder, ancestorSubtrees)
	local row = {
		LayoutOrder = layoutOrder,
		Key = key,
		Value = value,
		Depth = depth,
		IsExpanded = false,
		Subtree = {},
		AncestorSubtrees = ancestorSubtrees,
	}
	table.insert(parentList, row)
	if ancestorSubtrees then
		for _, st in ipairs(ancestorSubtrees) do
			table.insert(st, row)
		end
	end
	return row
end

local function clickRow(parentList, row)
	if type(row.Value) ~= "table" then return end
	row.IsExpanded = not row.IsExpanded
	local myOrder = row.LayoutOrder
	if row.IsExpanded then
		local n = 0
		for _ in pairs(row.Value) do n += 1 end
		for _, c in ipairs(parentList) do
			if c ~= row and c.LayoutOrder > myOrder then
				c.LayoutOrder += n
			end
		end
		-- Build descent list = ancestors + own subtree
		local descent = {}
		if row.AncestorSubtrees then
			for _, st in ipairs(row.AncestorSubtrees) do
				table.insert(descent, st)
			end
		end
		table.insert(descent, row.Subtree)

		local subIdx = 0
		for k, v in pairs(row.Value) do
			subIdx += 1
			buildRow(parentList, tostring(k), v, row.Depth + 1, myOrder + subIdx, descent)
		end
	else
		local removedCount = #row.Subtree
		local doomed = {}
		for _, c in ipairs(row.Subtree) do doomed[c] = true end
		-- Remove from parentList
		local kept = {}
		for _, c in ipairs(parentList) do
			if not doomed[c] then table.insert(kept, c) end
		end
		table.clear(parentList)
		for _, c in ipairs(kept) do table.insert(parentList, c) end
		-- Remove from any ancestor subtrees too
		if row.AncestorSubtrees then
			for _, st in ipairs(row.AncestorSubtrees) do
				local stKept = {}
				for _, c in ipairs(st) do
					if not doomed[c] then table.insert(stKept, c) end
				end
				table.clear(st)
				for _, c in ipairs(stKept) do table.insert(st, c) end
			end
		end
		table.clear(row.Subtree)
		for _, c in ipairs(parentList) do
			if c ~= row and c.LayoutOrder > myOrder + removedCount then
				c.LayoutOrder -= removedCount
			end
		end
	end
end

local function sortedKeys(rows: {any}): {string}
	local copy = {}
	for _, r in ipairs(rows) do table.insert(copy, r) end
	table.sort(copy, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	local out = {}
	for _, r in ipairs(copy) do table.insert(out, r.Key) end
	return out
end

local function ordersTable(rows: {any}): {[string]: number}
	local out = {}
	for _, r in ipairs(rows) do out[r.Key] = r.LayoutOrder end
	return out
end

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("ContextDrillDown — inline expand/collapse with shift-on-expand", function()
		it("expanding a leaf row with table value inserts children in order", function()
			local rows = {}
			buildRow(rows, "A", "scalar1", 0, 1, nil)
			buildRow(rows, "B", { x = 1, y = 2 }, 0, 2, nil)
			buildRow(rows, "C", "scalar3", 0, 3, nil)

			-- Expand B
			clickRow(rows, rows[2])

			local order = sortedKeys(rows)
			expect(order[1]).toEqual("A")
			expect(order[2]).toEqual("B")
			-- B's children come next (order between x and y depends on pairs())
			-- but they must both appear before C
			expect(order[3] == "x" or order[3] == "y").toEqual(true)
			expect(order[4] == "x" or order[4] == "y").toEqual(true)
			expect(order[5]).toEqual("C")
		end)

		it("collapsing restores order and destroys children", function()
			local rows = {}
			buildRow(rows, "A", "scalar1", 0, 1, nil)
			buildRow(rows, "B", { x = 1, y = 2 }, 0, 2, nil)
			buildRow(rows, "C", "scalar3", 0, 3, nil)

			clickRow(rows, rows[2])
			expect(#rows).toEqual(5)
			-- B is at index 2 in `rows` (insertion order). Get the B row.
			local b
			for _, r in ipairs(rows) do
				if r.Key == "B" then b = r end
			end
			clickRow(rows, b)

			expect(#rows).toEqual(3)
			local order = sortedKeys(rows)
			expect(order[1]).toEqual("A")
			expect(order[2]).toEqual("B")
			expect(order[3]).toEqual("C")
		end)

		it("sibling expansion AFTER another sibling — the live-order bug", function()
			-- This is the bug we fixed: A is at order 3, B at order 4.
			-- User expands A first (1 child). Now B's row.LayoutOrder is 5.
			-- User then expands B. If we use the captured `layoutOrder=4`,
			-- the shift gate `c.LayoutOrder > 4` would catch B itself
			-- (currently at 5), shifting B BELOW its own children.
			-- With the fix using `myOrder = row.LayoutOrder`, B reads its
			-- live position (5) and correctly skips itself.
			local rows = {}
			buildRow(rows, "X", "leaf1", 0, 1, nil)
			buildRow(rows, "Y", "leaf2", 0, 2, nil)
			buildRow(rows, "A", { a1 = "child" }, 0, 3, nil)
			buildRow(rows, "B", { b1 = 1, b2 = 2 }, 0, 4, nil)
			buildRow(rows, "Z", "leaf3", 0, 5, nil)

			-- Expand A (1 child)
			local a
			for _, r in ipairs(rows) do if r.Key == "A" then a = r end end
			clickRow(rows, a)

			-- Now B should have shifted to 5, Z to 6
			local b
			for _, r in ipairs(rows) do if r.Key == "B" then b = r end end
			expect(b.LayoutOrder).toEqual(5)

			-- Expand B (2 children)
			clickRow(rows, b)

			local orderMap = ordersTable(rows)
			-- B must come BEFORE its children
			expect(orderMap.B < orderMap.b1).toEqual(true)
			expect(orderMap.B < orderMap.b2).toEqual(true)
			-- A must come BEFORE B
			expect(orderMap.A < orderMap.B).toEqual(true)
			-- A's child a1 must come BEFORE B
			expect(orderMap.a1 < orderMap.B).toEqual(true)
			-- B's children come BEFORE Z
			expect(orderMap.b1 < orderMap.Z).toEqual(true)
			expect(orderMap.b2 < orderMap.Z).toEqual(true)
			-- Sequential order
			local order = sortedKeys(rows)
			expect(order[1]).toEqual("X")
			expect(order[2]).toEqual("Y")
			expect(order[3]).toEqual("A")
			expect(order[4]).toEqual("a1")
			expect(order[5]).toEqual("B")
			-- positions 6,7 = b1,b2 (order non-deterministic due to pairs)
			expect(order[8]).toEqual("Z")
		end)

		it("deep nesting (depth ≥ 5) — exercises arbitrary depth via shift cascading", function()
			-- Build a single deep nested table: { a = { b = { c = { d = { e = "leaf" } } } } }
			local deep = { e = "leaf" }
			deep = { d = deep }
			deep = { c = deep }
			deep = { b = deep }
			deep = { a = deep }

			local rows = {}
			buildRow(rows, "Root", deep, 0, 1, nil)
			buildRow(rows, "After", "trailing", 0, 2, nil)

			-- Drill: expand Root → a → b → c → d
			local function findRow(key)
				for _, r in ipairs(rows) do if r.Key == key then return r end end
				return nil
			end

			clickRow(rows, findRow("Root"))
			expect(findRow("a") ~= nil).toEqual(true)

			clickRow(rows, findRow("a"))
			expect(findRow("b") ~= nil).toEqual(true)

			clickRow(rows, findRow("b"))
			expect(findRow("c") ~= nil).toEqual(true)

			clickRow(rows, findRow("c"))
			expect(findRow("d") ~= nil).toEqual(true)

			clickRow(rows, findRow("d"))
			expect(findRow("e") ~= nil).toEqual(true)

			-- After (trailing scalar) must still be the LAST row
			local after = findRow("After")
			local maxOrder = 0
			for _, r in ipairs(rows) do
				if r.LayoutOrder > maxOrder and r.Key ~= "After" then
					maxOrder = r.LayoutOrder
				end
			end
			expect(after.LayoutOrder > maxOrder).toEqual(true)
		end)

		it("collapsing an ancestor cascades through all transitive expansions", function()
			-- Expand Root → a → b → c, then collapse Root. All grandchildren must vanish.
			local deep = { c = { leaf = "z" } }
			deep = { b = deep }
			deep = { a = deep }

			local rows = {}
			buildRow(rows, "Root", deep, 0, 1, nil)
			buildRow(rows, "After", "trailing", 0, 2, nil)

			local function findRow(key)
				for _, r in ipairs(rows) do if r.Key == key then return r end end
				return nil
			end

			clickRow(rows, findRow("Root"))
			clickRow(rows, findRow("a"))
			clickRow(rows, findRow("b"))
			clickRow(rows, findRow("c"))

			expect(findRow("leaf") ~= nil).toEqual(true)
			expect(#rows >= 6).toEqual(true)

			-- Collapse Root
			clickRow(rows, findRow("Root"))

			-- Only Root + After should remain
			expect(#rows).toEqual(2)
			expect(findRow("a")).toEqual(nil)
			expect(findRow("b")).toEqual(nil)
			expect(findRow("c")).toEqual(nil)
			expect(findRow("leaf")).toEqual(nil)
			expect(findRow("Root") ~= nil).toEqual(true)
			expect(findRow("After") ~= nil).toEqual(true)
		end)

		it("collapse + re-expand starts fresh (no stale rows)", function()
			local rows = {}
			buildRow(rows, "T", { x = 1, y = 2 }, 0, 1, nil)

			local function findRow(key)
				for _, r in ipairs(rows) do if r.Key == key then return r end end
				return nil
			end

			clickRow(rows, findRow("T"))
			expect(#rows).toEqual(3)

			clickRow(rows, findRow("T"))
			expect(#rows).toEqual(1)

			clickRow(rows, findRow("T"))
			expect(#rows).toEqual(3)
			expect(findRow("x") ~= nil).toEqual(true)
			expect(findRow("y") ~= nil).toEqual(true)
		end)
	end)
end

TR.register(spec)
return spec
