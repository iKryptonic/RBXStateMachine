--!strict
--[=[
	@module RunAllTests
	@description Defines the `RunAllTests` module and its exported API.
]=]

local TestRunner = require(script.Parent.TestRunner)

local _specsRequired = false

local function requireSpecsOnce()
	if _specsRequired then return end
	_specsRequired = true
	local specsFolder = script.Parent:FindFirstChild("Specs")
	if specsFolder then
		for _, child in ipairs(specsFolder:GetChildren()) do
			if child:IsA("ModuleScript") and child.Name:find("%.spec$") then
				local ok, err = pcall(require, child)
				if not ok then
					warn(string.format("[RunAllTests] Failed to load %s: %s", child.Name, tostring(err)))
				end
			end
		end
	end
end

local function runAll()
	requireSpecsOnce()
	return TestRunner.loadAndRun()
end

return {
	run = runAll,
}
