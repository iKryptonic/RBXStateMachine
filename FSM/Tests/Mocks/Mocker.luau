--!nocheck
-- @Name Mocker
-- @Author iKrypto
-- @Description Lightweight mocking/spying utility for tests.

local Mocker = {}
Mocker.__index = Mocker

export type Spy = {
	CallCount: number,
	Calls: { { any } },
	Fn: (...any) -> (...any),
}

export type Mocker = typeof(setmetatable({} :: {
	_stubs: { { Target: any, Key: string, Original: any } },
}, Mocker))

function Mocker.new(): Mocker
	local self = setmetatable({}, Mocker)
	self._stubs = {}
	return self
end

function Mocker:Spy(fn: (...any) -> (...any)): Spy
	local spyObj: Spy = (nil :: any)
	spyObj = {
		CallCount = 0,
		Calls = {},
		Fn = function(...: any)
			spyObj.CallCount += 1
			table.insert(spyObj.Calls, { ... })
			return fn(...)
		end,
	}
	return spyObj
end

function Mocker:Stub(target: any, key: string, replacement: any)
	if target == nil then
		return
	end
	local original = target[key]
	table.insert(self._stubs, { Target = target, Key = key, Original = original })
	target[key] = replacement
end

function Mocker:RestoreAll()
	for _, entry in ipairs(self._stubs) do
		entry.Target[entry.Key] = entry.Original
	end
	table.clear(self._stubs)
end

return Mocker
