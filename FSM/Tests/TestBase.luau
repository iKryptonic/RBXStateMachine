--!strict
-- @Name TestBase
-- @Author iKrypto
-- @Description Base class for unit testing suites.

local TestBase = {}
TestBase.__index = TestBase

export type TestBase = typeof(setmetatable({} :: {
	Name: string,
	Passed: number,
	Failed: number,
	Skipped: number
}, TestBase))

function TestBase.new(suiteName: string): TestBase
	local self = setmetatable({}, TestBase)
	self.Name = suiteName
	self.Passed = 0
	self.Failed = 0
	self.Skipped = 0
	return self
end

--[[
	@summary Skips the current test (counts as skipped, not failed).
	@param reason string
	@return ()
]]
function TestBase:SkipTest(reason: string)
	error("__TEST_SKIP__:" .. tostring(reason), 0)
end

--[[
	@summary Asserts a condition, incrementing Passed/Failed counters.
	@param condition boolean
	@param message string
	@return boolean
]]
function TestBase:Assert(condition: boolean, message: string): boolean
	if not condition then
		self.Failed += 1
		warn(string.format("[%s] [FAIL] %s", self.Name, message))
		return false
	end
	self.Passed += 1
	return true
end

--[[
	@summary Asserts that two values are equal.
	@param actual any
	@param expected any
	@param message string?
	@return boolean
]]
function TestBase:AssertEquals(actual: any, expected: any, message: string?): boolean
	if actual ~= expected then
		self.Failed += 1
		warn(string.format("[%s] [FAIL] %s\n\tExpected: %s\n\tGot:      %s", self.Name, message or "Assertion Failed", tostring(expected), tostring(actual)))
		return false
	end
	self.Passed += 1
	return true
end

--[[
	@summary Asserts that two values are not equal.
	@param actual any
	@param expected any
	@param message string?
	@return boolean
]]
function TestBase:AssertNotEquals(actual: any, expected: any, message: string?): boolean
	if actual == expected then
		self.Failed += 1
		warn(string.format("[%s] [FAIL] %s\n\tExpected not: %s\n\tGot:          %s", self.Name, message or "Assertion Failed", tostring(expected), tostring(actual)))
		return false
	end
	self.Passed += 1
	return true
end

--[[
	@summary Asserts that a value is not nil.
	@param value any
	@param message string?
	@return boolean
]]
function TestBase:AssertNotNil(value: any, message: string?): boolean
	if value == nil then
		self.Failed += 1
		warn(string.format("[%s] [FAIL] %s (got nil)", self.Name, message or "Expected non-nil value"))
		return false
	end
	self.Passed += 1
	return true
end

--[[
	@summary Asserts that a function throws an error.
	@param func () -> ()
	@param message string?
	@return boolean
]]
function TestBase:AssertThrows(func: () -> (), message: string?): boolean
	local ok = pcall(func)
	if ok then
		self.Failed += 1
		warn(string.format("[%s] [FAIL] %s (expected error, but none was thrown)", self.Name, message or "Expected function to throw"))
		return false
	end
	self.Passed += 1
	return true
end

--[[
	@summary Runs a test case and logs the result.
	@param testName string
	@param testFunc (TestBase) -> ()
	@return ()
]]
function TestBase:RunTest(testName: string, testFunc: (TestBase) -> ())
	print(string.format("[%s] Test: %s", self.Name, testName))
	local failedBefore = self.Failed
	local success, err = pcall(testFunc, self)

	if not success then
		local msg = tostring(err)
		if msg:match("^__TEST_SKIP__:") then
			self.Skipped += 1
			print(string.format("[%s] [SKIP] %s - %s", self.Name, testName, msg:gsub("^__TEST_SKIP__:", "")))
		else
			self.Failed += 1
			warn(string.format("[%s] [ERROR] %s - %s", self.Name, testName, msg))
		end
	elseif self.Failed > failedBefore then
		-- Assertions failed inside the test body (but no error was thrown)
		warn(string.format("[%s] [FAIL] %s (%d assertion(s) failed)", self.Name, testName, self.Failed - failedBefore))
	else
		print(string.format("[%s] [PASS] %s", self.Name, testName))
	end
end

--[[
	@summary Prints a summary of this suite.
	@return boolean -- True if no tests failed
]]
function TestBase:PrintSummary(): boolean
	print("------------------------------------------------")
	print(string.format("[%s] Summary - Passed: %d, Failed: %d, Skipped: %d", self.Name, self.Passed, self.Failed, self.Skipped))
	print("------------------------------------------------")
	return self.Failed == 0
end

return TestBase