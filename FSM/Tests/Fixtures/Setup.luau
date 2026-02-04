--!nocheck
-- @Name TestFixturesSetup
-- @Author iKrypto
-- @Description Installs test fixtures into ReplicatedStorage for discovery/replication tests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Setup = {}

export type InstallResult = {
	Ok: boolean,
	Reason: string?,
	EntityFolder: Folder?,
	StateMachineFolder: Folder?,
	Cleanup: (() -> ())?,
}

local function markFixture(inst: Instance)
	pcall(function()
		inst:SetAttribute("TestFixture", true)
	end)
end

local function ensureFolder(name: string): (Folder, boolean)
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing :: Folder, false
	end
	local folderInst = Instance.new("Folder")
	assert(folderInst ~= nil, "Instance.new returned nil")
	local folder = folderInst :: Folder
	folder.Name = name
	folder.Parent = ReplicatedStorage
	markFixture(folder)
	return folder, true
end

local function cloneIfMissing(parent: Instance, name: string, source: Instance, created: {Instance}): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local clone = source:Clone()
	clone.Name = name
	clone.Parent = parent
	markFixture(clone)
	table.insert(created, clone)
	return clone
end

function Setup.Install(): InstallResult
	local fixturesFolder = script.Parent
	if not fixturesFolder then
		return { Ok = false, Reason = "MissingFixturesFolder" }
	end

	local entityRegistry = fixturesFolder:FindFirstChild("EntityRegistry")
	local stateMachineRegistry = fixturesFolder:FindFirstChild("StateMachineRegistry")
	local dummyEntity = fixturesFolder:FindFirstChild("DummyEntity")
	local dummyFSM = fixturesFolder:FindFirstChild("DummyFSM")

	if not (entityRegistry and stateMachineRegistry and dummyEntity and dummyFSM) then
		return { Ok = false, Reason = "MissingFixtureModules" }
	end

	local created: {Instance} = {}
	local createdFolders: {Folder} = {}

	local entityFolder, createdEntityFolder = ensureFolder("Entity")
	local smFolder, createdSMFolder = ensureFolder("StateMachine")
	if createdEntityFolder then table.insert(createdFolders, entityFolder) end
	if createdSMFolder then table.insert(createdFolders, smFolder) end

	-- Install dummy entity and FSM modules
	cloneIfMissing(entityFolder, "DummyEntity", dummyEntity, created)
	cloneIfMissing(smFolder, "DummyFSM", dummyFSM, created)

	-- Merge fixture definitions into existing registries
	local existingEntityRegistry = entityFolder:FindFirstChild("EntityRegistry")
	local existingStateMachineRegistry = smFolder:FindFirstChild("StateMachineRegistry")
	
	if existingEntityRegistry then
		local fixtureEntityDefs = require(entityRegistry)
		local existingEntityDefs = require(existingEntityRegistry)
		-- Merge fixture definitions into existing registry
		for key, value in pairs(fixtureEntityDefs) do
			existingEntityDefs[key] = value
		end
	end
	
	if existingStateMachineRegistry then
		local fixtureStateMachineDefs = require(stateMachineRegistry)
		local existingStateMachineDefs = require(existingStateMachineRegistry)
		-- Merge fixture definitions into existing registry
		for key, value in pairs(fixtureStateMachineDefs) do
			existingStateMachineDefs[key] = value
		end
	end

	return {
		Ok = true,
		EntityFolder = entityFolder,
		StateMachineFolder = smFolder,
		Cleanup = function()
			for _, inst in ipairs(created) do
				inst:Destroy()
			end
			for _, folder in ipairs(createdFolders) do
				folder:Destroy()
			end
		end,
	}
end

return Setup