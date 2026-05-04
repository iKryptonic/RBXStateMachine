--!strict


local TestRunner = {}

type TestCase = {
	name: string,
	fn: () -> (),
}

type Suite = {
	name: string,
	cases: { TestCase },
	parent: Suite?,
	children: { Suite },
}

local _rootSuite: Suite = {
	name = "_root",
	cases = {},
	parent = nil,
	children = {},
}
local _currentSuite: Suite = _rootSuite

-- ══════════════════════════════════════════════════════════════
-- ASSERTION HELPERS
-- ══════════════════════════════════════════════════════════════

local function deepEqual(a: any, b: any): boolean
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then return false end
	end
	for k, _ in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function valueToString(v: any): string
	local t = type(v)
	if t == "string" then return string.format("%q", v) end
	if t == "table" then
		local parts = {}
		local ct = 0
		for k, val in pairs(v) do
			ct + = 1
			if ct > 6 then table.insert(parts,"..."); break end
			table.insert(parts, tostring(k) .."=" .. tostring(val))
		end
		return"{" .. table.concat(parts,", ") .."}"
	end
	return tostring(v)
end


function TestRunner.expect(actual: any): any
	local matcher = {}


	function matcher.toEqual(expected: any)
		if not deepEqual(actual, expected) then
			error(string.format("Expected %s to equal %s", valueToString(actual), valueToString(expected)), 2)
		end
	end


	function matcher.toBe(expected: any)
		if actual ~= expected then
			error(string.format("Expected %s to be %s (identity)", valueToString(actual), valueToString(expected)), 2)
		end
	end


	function matcher.toBeNil()
		if actual ~= nil then error("Expected nil, got " .. valueToString(actual), 2) end
	end


	function matcher.toBeTruthy()
		if not actual then error("Expected truthy, got " .. valueToString(actual), 2) end
	end


	function matcher.toBeFalsy()
		if actual then error("Expected falsy, got " .. valueToString(actual), 2) end
	end


	function matcher.toBeGreaterThan(n: number)
		if type(actual) ~= "number" or actual <= n then
			error(string.format("Expected %s > %s", valueToString(actual), valueToString(n)), 2)
		end
	end


	function matcher.toBeGreaterThanOrEqual(n: number)
		if type(actual) ~= "number" or actual < n then
			error(string.format("Expected %s >= %s", valueToString(actual), valueToString(n)), 2)
		end
	end


	function matcher.toBeLessThan(n: number)
		if type(actual) ~= "number" or actual >= n then
			error(string.format("Expected %s < %s", valueToString(actual), valueToString(n)), 2)
		end
	end


	function matcher.toBeCloseTo(n: number, tolerance: number?)
		local tol = tolerance or 0.001
		if type(actual) ~= "number" or math.abs(actual - n) > tol then
			error(string.format("Expected %s ≈ %s (tol %s)", valueToString(actual), valueToString(n), valueToString(tol)), 2)
		end
	end


	function matcher.toContain(needle: any)
		if type(actual) == "string" then
			if not string.find(actual, tostring(needle), 1, true) then
				error(string.format("Expected %q to contain %q", actual, tostring(needle)), 2)
			end
		elseif type(actual) == "table" then
			for _, v in pairs(actual) do
				if v == needle then return end
			end
			error("Expected table to contain " .. valueToString(needle), 2)
		else
			error("toContain requires string or table actual", 2)
		end
	end


	function matcher.toHaveProperty(key: string, value: any?)
		if type(actual) ~= "table" then
			error("Expected table, got " .. type(actual), 2)
		end
		if actual[key] == nil then
			error("Expected property " .. key .." to exist", 2)
		end
		if value ~= nil and not deepEqual(actual[key], value) then
			error(string.format("Expected property %s = %s, got %s", key, valueToString(value), valueToString(actual[key])), 2)
		end
	end


	function matcher.toHaveLength(n: number)
		if type(actual) ~= "table" and type(actual) ~= "string" then
			error("toHaveLength requires table or string", 2)
		end
		local len = #actual
		if len ~= n then
			error(string.format("Expected length %d, got %d", n, len), 2)
		end
	end


	function matcher.toThrow(messagePattern: string?)
		if type(actual) ~= "function" then
			error("toThrow requires a function actual", 2)
		end
		local ok, err = pcall(actual)
		if ok then
			error("Expected function to throw, but it returned normally", 2)
		end
		if messagePattern and not string.find(tostring(err), messagePattern) then
			error(string.format("Expected error to match %q, got %q", messagePattern, tostring(err)), 2)
		end
	end

	matcher.never = setmetatable({}, {
		__index = function(_, methodName)
			return function(...)
				local ok = pcall(matcher[methodName], ...)
				if ok then
					error("Expected NOT to " .. methodName .." but it did", 2)
				end
			end
		end,
	})

	return matcher
end


function TestRunner.describe(name: string, fn: () -> ())
	local suite: Suite = {
		name = name,
		cases = {},
		parent = _currentSuite,
		children = {},
	}
	table.insert(_currentSuite.children, suite)
	local prev = _currentSuite
	_currentSuite = suite
	local ok, err = pcall(fn)
	_currentSuite = prev
	if not ok then
		warn(string.format("[TestRunner] describe '%s' setup error: %s", name, tostring(err)))
	end
end


function TestRunner.it(name: string, fn: () -> ())
	table.insert(_currentSuite.cases, { name = name, fn = fn })
end

TestRunner.test = TestRunner.it

-- ══════════════════════════════════════════════════════════════
-- RUN
-- ══════════════════════════════════════════════════════════════

type Result = {
	suite: string,
	name: string,
	pass: boolean,
	error: string?,
	durationMs: number,
}

local function runSuite(suite: Suite, depth: number, prefix: string, results: { Result })
	if suite.name ~= "_root" and depth >= 0 then
		print(string.rep("  ", depth) .."📁 " .. suite.name)
	end
	for _, case in ipairs(suite.cases) do
		local startTime = os.clock()
		local ok, err = pcall(case.fn)
		local durationMs = (os.clock() - startTime) * 1000
		local result: Result = {
			suite = suite.name,
			name = case.name,
			pass = ok,
			error = if ok then nil else tostring(err),
			durationMs = durationMs,
		}
		table.insert(results, result)
		if ok then
			print(string.format("%s  ✓ %s (%.1fms)", string.rep("  ", depth), case.name, durationMs))
		else
			print(string.format("%s  ✗ %s (%.1fms)", string.rep("  ", depth), case.name, durationMs))
			print(string.format("%s     %s", string.rep("  ", depth), tostring(err)))
		end
	end
	for _, child in ipairs(suite.children) do
		runSuite(child, depth + 1, prefix .. suite.name .." > ", results)
	end
end


function TestRunner.run(): {
	total: number,
	passed: number,
	failed: number,
	durationMs: number,
	results: { Result },
}
	print("══════════════════════════════════════════════════════════════")
	print("  TEST RUNNER — running suites")
	print("══════════════════════════════════════════════════════════════")
	local startTime = os.clock()
	local results: { Result } = {}
	runSuite(_rootSuite, -1,"", results)
	local total = #results
	local passed = 0
	local failed = 0
	for _, r in ipairs(results) do
		if r.pass then passed + = 1 else failed + = 1 end
	end
	local durationMs = (os.clock() - startTime) * 1000
	print("══════════════════════════════════════════════════════════════")
	print(string.format("  RESULTS: %d/%d passed, %d failed in %.1fms", passed, total, failed, durationMs))
	print("══════════════════════════════════════════════════════════════")
	if failed > 0 then
		print("Failed tests:")
		for _, r in ipairs(results) do
			if not r.pass then
				print(string.format("  ✗ %s > %s", r.suite, r.name))
				print("    " .. (r.error or "(no message)"))
			end
		end
	end
	return {
		total = total,
		passed = passed,
		failed = failed,
		durationMs = durationMs,
		results = results,
	}
end


function TestRunner.reset()
	_rootSuite = {
		name = "_root",
		cases = {},
		parent = nil,
		children = {},
	}
	_currentSuite = _rootSuite
end

--[=[
	Register a function to be called when the test runner is asked to load suites.
	Specs export their describe() calls wrapped in a function so they can be re-invoked
	after reset() — bypassing Lua's require cache.
]=]
local _registeredSpecs: { (any) -> () } = {}


function TestRunner.register(specFn: (any) -> ())
	if type(specFn) ~= "function" then return end
	-- Avoid duplicate registration (require cache may call this multiple times)
	for _, fn in ipairs(_registeredSpecs) do
		if fn == specFn then return end
	end
	table.insert(_registeredSpecs, specFn)
end


function TestRunner.loadAndRun(): {
	total: number,
	passed: number,
	failed: number,
	durationMs: number,
	results: { Result },
}
	TestRunner.reset()
	for _, specFn in ipairs(_registeredSpecs) do
		local ok, err = pcall(specFn, TestRunner)
		if not ok then
			warn(string.format("[TestRunner] spec invoke error: %s", tostring(err)))
		end
	end
	return TestRunner.run()
end

return TestRunner
