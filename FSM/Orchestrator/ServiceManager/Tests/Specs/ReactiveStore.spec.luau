--!strict
-- @Name ServiceManager/Tests/Specs/ReactiveStore.spec.luau
-- @Author iKrypto

local TR = require(script.Parent.Parent.TestRunner)
local ReactiveStore = require(script.Parent.Parent.Parent.ReactiveStore)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("ReactiveStore", function()
	it("stores and retrieves values", function()
		local s = ReactiveStore.new({})
		s:Set("a", 1)
		s:Set("b", "hello")
		expect(s:Get("a")).toEqual(1)
		expect(s:Get("b")).toEqual("hello")
	end)

	it("returns nil for unknown keys", function()
		local s = ReactiveStore.new({})
		expect(s:Get("missing")).toBeNil()
	end)

	it("respects initial state from constructor", function()
		local s = ReactiveStore.new({ x = 42 })
		expect(s:Get("x")).toEqual(42)
	end)

	it("notifies subscribers on key change", function()
		local s = ReactiveStore.new({})
		local lastValue = nil
		s:Subscribe("foo", function(key, newVal, oldVal) lastValue = newVal end)
		s:Set("foo", "bar")
		-- task.spawn means we may need to wait a tick
		task.wait()
		expect(lastValue).toEqual("bar")
	end)

	it("does not fire subscribers when value is unchanged", function()
		local s = ReactiveStore.new({ k = 1 })
		local fired = 0
		s:Subscribe("k", function() fired += 1 end)
		s:Set("k", 1) -- same value
		task.wait()
		expect(fired).toEqual(0)
	end)

	it("BatchUpdate defers notifications until the batch ends", function()
		local s = ReactiveStore.new({})
		local fired = 0
		s:Subscribe("a", function() fired += 1 end)
		s:Subscribe("b", function() fired += 1 end)
		s:BatchUpdate(function()
			s:Set("a", 1)
			s:Set("b", 2)
		end)
		task.wait()
		expect(fired).toEqual(2)
	end)

	it("tracks dirty keys", function()
		local s = ReactiveStore.new({})
		s:Set("k", 1)
		expect(s:IsDirty("k")).toBeTruthy()
		s:ClearDirty("k")
		expect(s:IsDirty("k")).toBeFalsy()
	end)

	it("supports wildcard subscribers", function()
		local s = ReactiveStore.new({})
		local seen = {}
		s:Subscribe(nil, function(key, newVal) table.insert(seen, key) end)
		s:Set("a", 1)
		s:Set("b", 2)
		task.wait()
		expect(#seen).toEqual(2)
	end)

	it("Unsubscribe stops notifications", function()
		local s = ReactiveStore.new({})
		local fired = 0
		local unsub = s:Subscribe("k", function() fired += 1 end)
		s:Set("k", 1)
		task.wait()
		unsub()
		s:Set("k", 2)
		task.wait()
		expect(fired).toEqual(1)
	end)

	it("GetSnapshot returns a cloned copy", function()
		local s = ReactiveStore.new({ a = 1 })
		local snap = s:GetSnapshot()
		snap.a = 999
		expect(s:Get("a")).toEqual(1)
	end)
end)

end -- close spec function

TR.register(spec)
return spec
