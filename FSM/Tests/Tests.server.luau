--!strict
-- @Name Tests.lua
-- @Author iKrypto
-- @Description Entrypoint for executing all server-side test suites in this folder.

local TestRunner = require(script:WaitForChild("TestRunner") :: any)

TestRunner.RunAll({
	Mode = "server",
	Root = script.Parent,
	RunnerScript = script,
})