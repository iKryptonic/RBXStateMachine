--!strict
-- @Name Tests.client
-- @Author iKrypto
-- @Description Client test runner for Test_*_Client suites.

local TestRunner = require(script:WaitForChild("TestRunner") :: any)

TestRunner.RunAll({
	Mode = "client",
	Root = script.Parent,
	RunnerScript = script,
})
