--!strict
-- @Name TestUtils
-- @Author iKrypto
-- @Description Small helpers used by the test runner and suites.

local TestUtils = {}

--[[
	@summary Waits until predicate() returns true or a timeout elapses.
	@param predicate () -> boolean
	@param timeoutSeconds number
	@return boolean
]]
function TestUtils.WaitFor(predicate: () -> boolean, timeoutSeconds: number): boolean
	local start = os.clock()
	while not predicate() and (os.clock() - start) < timeoutSeconds do
		task.wait()
	end
	return predicate()
end

--[[
	@summary Returns instances sorted by Name for stable test ordering.
	@param instances { Instance }
	@return { Instance }
]]
function TestUtils.SortedByName(instances: { Instance }): { Instance }
	local out = table.clone(instances)
	table.sort(out, function(a, b)
		return a.Name < b.Name
	end)
	return out
end

return TestUtils
