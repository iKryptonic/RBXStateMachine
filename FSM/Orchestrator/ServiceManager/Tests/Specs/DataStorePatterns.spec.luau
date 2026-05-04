--!strict
-- @Name ServiceManager/Tests/Specs/DataStorePatterns.spec.luau
-- @Author iKrypto
-- @Description Contract tests for DataStore persistence round-trip helpers and container resilience patterns.

local TR = require(script.Parent.Parent.TestRunner)
local HttpService = game:GetService("HttpService")

local SESSION_ID = "test-session-id"
local SESSION_LOCK_TTL = 900

local function containerHasItem(container, itemId)
	if typeof(container) ~= "table" then
		return false
	end
	if table.find(container, itemId) then
		return true
	end
	for key, value in pairs(container) do
		if key == itemId then
			return true
		end
		if typeof(value) == "table" then
			local innerId = value.ItemId or value.Id
			if innerId == itemId then
				return true
			end
		end
	end
	return false
end

local function removeFromContainer(container, itemId)
	if typeof(container) ~= "table" then
		return container
	end
	local clone = table.clone(container)
	local idx = table.find(clone, itemId)
	if idx then
		table.remove(clone, idx)
		return clone
	end
	if clone[itemId] ~= nil then
		clone[itemId] = nil
		return clone
	end
	for key, value in pairs(clone) do
		if typeof(value) == "table" then
			local innerId = value.ItemId or value.Id
			if innerId == itemId then
				if typeof(key) == "number" then
					table.remove(clone, key)
				else
					clone[key] = nil
				end
				return clone
			end
		end
	end
	return clone
end

local function encodePayload(data, meta, lock)
	return HttpService:JSONEncode({
		version = 2,
		data = data,
		meta = meta,
		lock = lock,
	})
end

local function decodePayload(raw)
	if typeof(raw) == "table" then
		return raw, nil, nil
	end

	local decoded = HttpService:JSONDecode(raw)
	if typeof(decoded) ~= "table" then
		return decoded, nil, nil
	end

	if decoded.version == 2 then
		return decoded.data, decoded.meta, decoded.lock
	end

	if decoded.version == 1 then
		return decoded.data, decoded.meta, nil
	end

	return decoded, nil, nil
end

local function isLockHeldByOther(lock)
	if not lock or typeof(lock) ~= "table" then
		return false
	end
	if lock.SessionId == SESSION_ID then
		return false
	end
	local elapsed = os.time() - (tonumber(lock.LockedAt) or 0)
	if elapsed >= SESSION_LOCK_TTL then
		return false
	end
	return true
end

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("container format resilience", function()
		it("array container: finds item by value", function()
			expect(containerHasItem({ "A", "B", "C" }, "B")).toEqual(true)
		end)

		it("array container: rejects missing item", function()
			expect(containerHasItem({ "A", "B" }, "C")).toEqual(false)
		end)

		it("dict container: finds item by key", function()
			expect(containerHasItem({ A = true, B = 1 }, "B")).toEqual(true)
		end)

		it("dict container: rejects missing key", function()
			expect(containerHasItem({ A = true }, "B")).toEqual(false)
		end)

		it("table-value container: finds item by ItemId", function()
			expect(containerHasItem({ { ItemId = "A" }, { ItemId = "B" } }, "B")).toEqual(true)
		end)

		it("table-value container: finds item by Id", function()
			expect(containerHasItem({ { Id = "X" } }, "X")).toEqual(true)
		end)

		it("empty container: returns false", function()
			expect(containerHasItem({}, "A")).toEqual(false)
		end)

		it("nil container: returns false", function()
			expect(containerHasItem(nil, "A")).toEqual(false)
		end)

		it("mixed container: finds in both styles", function()
			local container = { [1] = "A", B = true }
			expect(containerHasItem(container, "A")).toEqual(true)
			expect(containerHasItem(container, "B")).toEqual(true)
		end)
	end)

	describe("container removal", function()
		it("removes from array", function()
			local result = removeFromContainer({ "A", "B", "C" }, "B")
			expect(result).toEqual({ "A", "C" })
		end)

		it("removes dict key", function()
			local result = removeFromContainer({ A = true, B = 1 }, "B")
			expect(result.A).toEqual(true)
			expect(result.B).toBeNil()
		end)

		it("removes table-value entry", function()
			local result = removeFromContainer({ { ItemId = "A" }, { ItemId = "B" } }, "A")
			expect(result).toHaveLength(1)
			expect(result[1].ItemId).toEqual("B")
		end)

		it("no-op on missing item", function()
			local result = removeFromContainer({ "A" }, "B")
			expect(result).toEqual({ "A" })
		end)

		it("no-op on nil container", function()
			expect(removeFromContainer(nil, "A")).toBeNil()
		end)
	end)

	describe("payload encoding and decoding", function()
		it("v2 payload round-trips data and lock", function()
			local raw = encodePayload({ HP = 100 }, nil, { SessionId = "abc", LockedAt = 123 })
			local data, meta, lock = decodePayload(raw)
			expect(data.HP).toEqual(100)
			expect(meta).toBeNil()
			expect(lock.SessionId).toEqual("abc")
		end)

		it("v2 payload without lock decodes lock as nil", function()
			local raw = encodePayload({ HP = 100 }, { SavedAt = 1 }, nil)
			local data, meta, lock = decodePayload(raw)
			expect(data.HP).toEqual(100)
			expect(meta.SavedAt).toEqual(1)
			expect(lock).toBeNil()
		end)

		it("raw table decodes as data with nil meta and lock", function()
			local raw = { Coins = 25 }
			local data, meta, lock = decodePayload(raw)
			expect(data).toBe(raw)
			expect(meta).toBeNil()
			expect(lock).toBeNil()
		end)

		it("v1 payload decodes with nil lock", function()
			local raw = HttpService:JSONEncode({
				version = 1,
				data = { X = 1 },
				meta = {},
			})
			local data, meta, lock = decodePayload(raw)
			expect(data.X).toEqual(1)
			expect(meta).toEqual({})
			expect(lock).toBeNil()
		end)

		it("payload size is measurable", function()
			local values = {}
			for i = 1, 256 do
				values[i] = string.rep("x", 32)
			end
			local raw = encodePayload({ Values = values }, { SavedAt = 1 }, nil)
			expect(typeof(raw)).toEqual("string")
			expect(#raw).toBeGreaterThan(0)
		end)
	end)

	describe("session lock logic", function()
		it("nil lock is not held", function()
			expect(isLockHeldByOther(nil)).toEqual(false)
		end)

		it("own session lock is not held", function()
			expect(isLockHeldByOther({ SessionId = SESSION_ID, LockedAt = os.time() })).toEqual(false)
		end)

		it("other session active lock IS held", function()
			expect(isLockHeldByOther({ SessionId = "other", LockedAt = os.time() })).toEqual(true)
		end)

		it("other session expired lock is not held", function()
			expect(isLockHeldByOther({ SessionId = "other", LockedAt = os.time() - 1000 })).toEqual(false)
		end)

		it("missing LockedAt treated as expired", function()
			expect(isLockHeldByOther({ SessionId = "other" })).toEqual(false)
		end)
	end)
end

TR.register(spec)
return spec
