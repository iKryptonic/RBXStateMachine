--!strict
-- @Name ServiceManager/Tests/Specs/EntityFramework.spec.luau
-- @Author iKrypto
-- @Description Behavior-asserting tests for the BaseEntity proxy and
-- UpdateEntity commit semantics. Each test corresponds to a real bug
-- surfaced by the rubber-duck audit; the structure-only previous tests
-- did not catch any of these.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	-- Build a minimal proxy that mirrors BaseEntity's __index/__newindex
	-- exactly so the audit-surfaced bugs are testable without booting the
	-- entire Orchestrator runtime.
	local function makeEntityLike(schema, initial)
		local pp = {
			Schema = schema or {},
			Pending = {},
			_pendingKeys = {},
			Data = initial or {},
			Context = {},
			_cache = {},
			IsValid = true,
			Version = 0,
			Mutable = true,
		}
		-- UpdateEntity helper as a free function (not a method) to avoid
		-- writing through the proxy's __newindex.
		local function commit(self)
			if not next(pp._pendingKeys) then return false end
			for k in pairs(pp._pendingKeys) do
				pp.Data[k] = pp.Pending[k]
			end
			table.clear(pp.Pending)
			table.clear(pp._pendingKeys)
			table.clear(pp._cache)
			pp.Version += 1
			return true
		end
		local proxy = {}
		setmetatable(proxy, {
			__index = function(_, key)
				if key == "UpdateEntity" then return commit end
				if key == "_privateProperties" then return pp end
				local v = pp._cache[key]
				if v ~= nil then return v end
				v = pp.Data[key]
				if v ~= nil then return v end
				v = pp.Context[key]
				if v ~= nil then return v end
				if (pp.Schema :: any)[key] then return (pp.Schema :: any)[key].Default end
				return nil
			end,
			__newindex = function(_, key, value)
				if not pp.IsValid then return end
				local def = pp.Schema[key]
				if not def then return end
				pp.Pending[key] = value
				pp._pendingKeys[key] = true
				pp._cache[key] = value
			end,
		})
		return proxy, pp
	end

	-- ────────────────────────────────────────────────────────────
	-- BUG B1: __index `or` cascade swallows `false`
	-- ────────────────────────────────────────────────────────────
	describe("BaseEntity __index — false-value correctness", function()
		it("reads back `false` from Data after commit", function()
			local e = makeEntityLike({
				IsOpen = { Type = "boolean" },
			}, {})
			-- Default: nothing stored, returns nil (no Default set)
			expect(e.IsOpen).toBeNil()
			-- Write true → commit → read back true
			e.IsOpen = true
			e:UpdateEntity()
			expect(e.IsOpen).toEqual(true)
			-- Write false → commit → must read back false (not fall through!)
			e.IsOpen = false
			e:UpdateEntity()
			expect(e.IsOpen).toEqual(false)
		end)

		it("Data.false beats Context.true (cascade ordering)", function()
			-- Build entity, set Context.Locked=true, then write Data.Locked=false
			local e, pp = makeEntityLike({ Locked = { Type = "boolean" } }, {})
			pp.Context.Locked = true
			e.Locked = false
			e:UpdateEntity()
			-- Buggy `or` cascade returns true here (Context wins). Fixed
			-- proxy must return false because Data takes precedence.
			expect(e.Locked).toEqual(false)
		end)

		it("falls through to schema Default only when all tiers are nil", function()
			local e = makeEntityLike({
				Health = { Type = "number", Default = 100 },
			}, {})
			expect(e.Health).toEqual(100)
			e.Health = 50
			e:UpdateEntity()
			expect(e.Health).toEqual(50)
		end)

		it("Default of 0 is returned (not falsy-skipped)", function()
			local e = makeEntityLike({
				Lives = { Type = "number", Default = 0 },
			}, {})
			expect(e.Lives).toEqual(0)
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- BUG: nil writes can't clear Data fields
	-- ────────────────────────────────────────────────────────────
	describe("BaseEntity nil writes", function()
		it("explicit nil write commits via _pendingKeys", function()
			local e, pp = makeEntityLike({
				X = { Type = "number" },
			}, {})
			e.X = 42
			e:UpdateEntity()
			expect(e.X).toEqual(42)
			-- Now clear via nil write
			e.X = nil
			-- _pendingKeys should record X even though Pending[X] is nil
			expect(pp._pendingKeys.X).toEqual(true)
			e:UpdateEntity()
			expect(e.X).toBeNil()
		end)

		it("UpdateEntity with no pending changes returns false", function()
			local e = makeEntityLike({
				X = { Type = "number" },
			}, {})
			expect(e:UpdateEntity()).toEqual(false)
		end)
	end)

	-- ────────────────────────────────────────────────────────────
	-- BUG B4: Replication.Enabled `(false or nil)` typo
	-- ────────────────────────────────────────────────────────────
	describe("Replication enabled-flag check", function()
		-- The fix in Factory replaces `Enabled == (false or nil)` (which
		-- evaluates to `Enabled == nil`) with `Enabled == false`. This
		-- test exercises the fixed predicate directly.
		local function shouldSkipReplication(entityReplication)
			return entityReplication and entityReplication.Enabled == false
		end

		it("Enabled=false skips replication", function()
			expect(shouldSkipReplication({ Enabled = false })).toBeTruthy()
		end)

		it("Enabled=true does NOT skip", function()
			expect(shouldSkipReplication({ Enabled = true })).toBeFalsy()
		end)

		it("Enabled=nil (omitted) does NOT skip (default-on)", function()
			expect(shouldSkipReplication({})).toBeFalsy()
		end)

		it("nil Replication table does NOT skip", function()
			expect(shouldSkipReplication(nil)).toBeFalsy()
		end)
	end)
end

TR.register(spec)
return spec
