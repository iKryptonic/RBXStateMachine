--!strict
-- @Name ServiceManager/Tests/Specs/ConnectionBag.spec.luau
-- @Author iKrypto

local TR = require(script.Parent.Parent.TestRunner)
local ConnectionBag = require(script.Parent.Parent.Parent.ConnectionBag)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("ConnectionBag", function()
	it("starts empty", function()
		local bag = ConnectionBag.new()
		expect(bag:IsEmpty()).toBeTruthy()
		expect(bag:Count()).toEqual(0)
	end)

	it("adds disposable items and tracks count", function()
		local bag = ConnectionBag.new()
		bag:Add({ Disconnect = function() end })
		bag:Add({ Destroy = function() end })
		expect(bag:Count()).toEqual(2)
		expect(bag:IsEmpty()).toBeFalsy()
	end)

	it("disposes all items on DisconnectAll", function()
		local disposed = { 0, 0, 0 }
		local bag = ConnectionBag.new()
		bag:Add({ Disconnect = function() disposed[1] += 1 end })
		bag:Add({ Destroy = function() disposed[2] += 1 end })
		bag:Add({ Cancel = function() disposed[3] += 1 end })
		bag:DisconnectAll()
		expect(disposed).toEqual({ 1, 1, 1 })
		expect(bag:Count()).toEqual(0)
	end)

	it("disposes in reverse-add order", function()
		local order = {}
		local bag = ConnectionBag.new()
		bag:Add({ Disconnect = function() table.insert(order, 1) end })
		bag:Add({ Disconnect = function() table.insert(order, 2) end })
		bag:Add({ Disconnect = function() table.insert(order, 3) end })
		bag:DisconnectAll()
		expect(order).toEqual({ 3, 2, 1 })
	end)

	it("ignores nil additions", function()
		local bag = ConnectionBag.new()
		bag:Add(nil)
		expect(bag:Count()).toEqual(0)
	end)

	it("is safe to call DisconnectAll twice", function()
		local count = 0
		local bag = ConnectionBag.new()
		bag:Add({ Disconnect = function() count += 1 end })
		bag:DisconnectAll()
		bag:DisconnectAll()
		expect(count).toEqual(1)
	end)

	it("survives errors in disposers (pcall wrapped)", function()
		local count = 0
		local bag = ConnectionBag.new()
		bag:Add({ Disconnect = function() error("boom") end })
		bag:Add({ Disconnect = function() count += 1 end })
		bag:DisconnectAll()
		-- Both items processed despite first error
		expect(count).toEqual(1)
	end)

	it("AddTween + AddThread accept their respective types", function()
		local bag = ConnectionBag.new()
		bag:AddTween({} :: any) -- mock; real Tween test would need TweenService
		bag:AddThread(coroutine.create(function() end))
		expect(bag:Count()).toEqual(2)
	end)
end)

end -- close spec function

TR.register(spec)
return spec
