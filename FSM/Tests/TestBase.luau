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
	@summary Runs a test case and logs the result.
	@param testName string
	@param testFunc (TestBase) -> ()
	@return ()
]]
function TestBase:RunTest(testName: string, testFunc: (TestBase) -> ())
	print(string.format("[%s] Test: %s", self.Name, testName))
	local success, err = pcall(testFunc, self)

	if success then
		print(string.format("[%s] [PASS] %s", self.Name, testName))
	else
		local msg = tostring(err)
		if msg:match("^__TEST_SKIP__:") then
			self.Skipped += 1
			print(string.format("[%s] [SKIP] %s - %s", self.Name, testName, msg:gsub("^__TEST_SKIP__:", "")))
		else
			self.Failed += 1
			warn(string.format("[%s] [ERROR] %s - %s", self.Name, testName, msg))
		end
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