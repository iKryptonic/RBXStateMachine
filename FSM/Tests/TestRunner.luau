--!strict
-- @Name TestRunner
-- @Author iKrypto
-- @Description Shared runner for server/client tests with stable ordering + isolated runtime container.

local TestRunner = {}

export type Mode = "server" | "client"

export type RunOptions = {
	Mode: Mode,
	Root: Instance,
	RunnerScript: Instance,
	Verbose: boolean?,
}

local function isTestModule(module: Instance): boolean
	return module:IsA("ModuleScript") and module.Name:match("^Test_") ~= nil
end

local function modeAllows(moduleName: string, mode: Mode): boolean
	local isClientSuite = moduleName:find("_Client") ~= nil
	if mode == "client" then
		return isClientSuite
	end
	return not isClientSuite
end

local function collectTestModules(root: Instance, mode: Mode): { ModuleScript }
	local found: { ModuleScript } = {}
	for _, inst in ipairs(root:GetDescendants()) do
		if isTestModule(inst) and modeAllows(inst.Name, mode) then
			table.insert(found, inst :: ModuleScript)
		end
	end
	table.sort(found, function(a, b)
		return a.Name < b.Name
	end)
	return found
end

local function safeDestroy(inst: Instance?)	
	if inst and inst.Parent then
		inst:Destroy()
	end
end

local function makeRuntimeFolder(root: Instance): Folder
	local existing = root:FindFirstChild("__TestRuntime")
	if existing and existing:IsA("Folder") then
		existing:Destroy()
	elseif existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "__TestRuntime"
	folder.Parent = root
	return folder
end

local function cloneSupportFolder(root: Instance, runtime: Folder, name: string)
	local source = root:FindFirstChild(name)
	if source and source:IsA("Folder") then
		source:Clone().Parent = runtime
	end
end

local function cloneSupportModule(root: Instance, runtime: Folder, name: string)
	local source = root:FindFirstChild(name)
	if source and source:IsA("ModuleScript") then
		source:Clone().Parent = runtime
	end
end

local function printBanner(mode: Mode)
	print("================================================")
	print(string.format("STARTING %s TEST RUNNER", string.upper(mode)))
	print("================================================")
end

function TestRunner.RunAll(options: RunOptions): boolean
	local mode: Mode = options.Mode
	local root = options.Root
	local verbose = options.Verbose == true

	printBanner(mode)

	local tests = collectTestModules(root, mode)
	if #tests == 0 then
		warn("[TestRunner] No test suites found for mode: " .. mode)
		return true
	end

	local runtime = makeRuntimeFolder(root)
	cloneSupportFolder(root, runtime, "Fixtures")
	cloneSupportFolder(root, runtime, "Mocks")
	cloneSupportModule(root, runtime, "TestBase")
	cloneSupportModule(root, runtime, "TestUtils")

	local totalFailed = 0
	local totalSuites = 0
	local startAll = os.clock()

	for _, module in ipairs(tests) do
		totalSuites += 1

		local clone = module:Clone()
		clone.Name = module.Name
		clone.Parent = runtime

		-- Inject support modules directly into the cloned suite.
		local tb = runtime:FindFirstChild("TestBase")
		if tb and tb:IsA("ModuleScript") then
			tb:Clone().Parent = clone
		end
		local tu = runtime:FindFirstChild("TestUtils")
		if tu and tu:IsA("ModuleScript") then
			tu:Clone().Parent = clone
		end

		local suiteStart = os.clock()
		local okRequire, suite = pcall(require, clone)
		if not okRequire then
			totalFailed += 1
			warn(string.format("[TestRunner] [ERROR] require(%s): %s", module.Name, tostring(suite)))
			safeDestroy(clone)
			continue
		end

		local okRun = true
		if type(suite) == "table" and type((suite :: any).Run) == "function" then
			local okCall, result = pcall(function()
				return (suite :: any).Run()
			end)
			if not okCall then
				okRun = false
				warn(string.format("[TestRunner] [ERROR] %s.Run(): %s", module.Name, tostring(result)))
			elseif result == false then
				okRun = false
			end
		else
			warn(string.format("[TestRunner] [WARN] %s does not export Run()", module.Name))
		end

		if not okRun then
			totalFailed += 1
		end

		if verbose then
			print(string.format("[TestRunner] %s finished in %.3fs", module.Name, os.clock() - suiteStart))
		end

		safeDestroy(clone)
	end

	local elapsed = os.clock() - startAll
	print("================================================")
	if totalFailed == 0 then
		print(string.format("ALL %d SUITES PASSED (%.2fs)", totalSuites, elapsed))
	else
		warn(string.format("%d/%d SUITES FAILED (%.2fs)", totalFailed, totalSuites, elapsed))
	end
	print("================================================")

	safeDestroy(runtime)
	return totalFailed == 0
end

return TestRunner
