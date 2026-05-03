--!nocheck
-- @Name Test_DamageJob
-- @Author iKrypto
-- @Description Unit tests for DamageCalculator integration and DamageJob validation flow.

local ServerStorage = game:GetService("ServerStorage")
local TestBase = require((script.Parent:FindFirstChild("TestBase") or script.Parent.Parent:FindFirstChild("TestBase")) :: any)

local Test_DamageJob = {}

local function findModule(moduleName: string, ancestorNames: { string }): ModuleScript
	for _, descendant in ipairs(game:GetDescendants()) do
		if descendant:IsA("ModuleScript") and descendant.Name == moduleName then
			local current = descendant.Parent
			local matches = true
			for _, ancestorName in ipairs(ancestorNames) do
				if not current or current.Name ~= ancestorName then
					matches = false
					break
				end
				current = current.Parent
			end
			if matches then
				return descendant
			end
		end
	end
	error("Module not found: " .. moduleName)
end

local DamageCalculator = require(findModule("DamageCalculator", { "shared", "MainModule" }))

local function cloneStateMachineModule(moduleName: string): ModuleScript
	local source = findModule(moduleName, { "StateMachines", "FSM", "RBXStateMachine" })
	local clone = source:Clone()
	clone.Name = moduleName .. "_TestClone"
	clone.Parent = ServerStorage
	return clone
end

local function loadDamageJob(orchestrator)
	local oldShared = {
		StateMachine = shared.StateMachine,
		fsm = shared.fsm,
	}

	shared.StateMachine = {
		DamageJob = {
			Name = "DamageJob",
		},
	}
	shared.fsm = orchestrator

	local clone = cloneStateMachineModule("DamageJob")
	local ok, result = pcall(require, clone)

	local function cleanup()
		shared.StateMachine = oldShared.StateMachine
		shared.fsm = oldShared.fsm
		if clone.Parent then
			clone:Destroy()
		end
	end

	return ok, result, cleanup
end

local function captureStates(job)
	local states = {}
	job.AddState = function(self, name, definition, transitions)
		if type(definition) == "function" then
			definition = { OnEnter = definition }
		end
		states[name] = {
			Definition = definition,
			Transitions = transitions,
		}
	end
	job:RegisterStates()
	return states
end

function Test_DamageJob.Run()
	local tester = TestBase.new("DamageJob")

	tester:RunTest("DamageCalculator keeps damage within supported range", function(t)
		for _, baseDamage in ipairs({ -50, 0, 10, 45, 150 }) do
			for _, isBlocking in ipairs({ false, true }) do
				for _ = 1, 30 do
					local damage = DamageCalculator.Compute(baseDamage, isBlocking)
					t:Assert(damage >= 3 and damage <= 110, string.format("Damage %d should stay in [3, 110]", damage))
				end
			end
		end
	end)

	tester:RunTest("Blocking applies quarter damage with the same random roll", function(t)
		local baseDamage = 40
		for _, seed in ipairs({ 101, 202, 303, 404 }) do
			math.randomseed(seed)
			local unblocked = DamageCalculator.Compute(baseDamage, false)
			math.randomseed(seed)
			local blocked = DamageCalculator.Compute(baseDamage, true)
			local expected = math.clamp(math.floor(unblocked * 0.25), 3, 110)
			t:AssertEquals(blocked, expected, string.format("Blocking should quarter the seeded damage roll for seed %d", seed))
			t:Assert(blocked < unblocked, "Blocked damage should be lower than unblocked damage")
		end
	end)

	tester:RunTest("GetWeaponBaseDamage extracts Attack stat", function(t)
		local itemData = {
			WeaponStats = {
				Attack = 57,
			},
		}
		t:AssertEquals(DamageCalculator.GetWeaponBaseDamage(itemData), 57, "GetWeaponBaseDamage should read WeaponStats.Attack")
		t:AssertEquals(DamageCalculator.GetWeaponBaseDamage({}), 10, "GetWeaponBaseDamage should fall back to default attack")
	end)

	tester:RunTest("DamageJob loads and validates required context", function(t)
		local attackerEntity = {
			EntityId = "Attacker_01",
			UserId = 9001,
		}
		local entities = {
			Attacker_01 = attackerEntity,
		}
		local orchestrator = {
			GetEntity = function(entityId)
				return entities[entityId]
			end,
		}
		local ok, job, cleanup = loadDamageJob(orchestrator)
		t:Assert(ok, "DamageJob should require without error when shared.StateMachine.DamageJob is registered")
		if not ok then
			cleanup()
			return
		end
		t:AssertEquals(job.Name, "DamageJob", "DamageJob should keep its declared Name")
		t:Assert(type(job.RegisterStates) == "function", "DamageJob should expose RegisterStates")
		if type(job.RegisterStates) ~= "function" then
			cleanup()
			return
		end

		local states = captureStates(job)
		t:Assert(states.Validate ~= nil, "DamageJob should register Validate")
		t:Assert(states.CheckHitNonce ~= nil, "DamageJob should register CheckHitNonce")
		t:Assert(states.ComputeDamage ~= nil, "DamageJob should register ComputeDamage")

		local validate = states.Validate.Definition.OnEnter
		local originalOrchestrator = shared.fsm

		local function runValidate(context, overrideOrchestrator)
			shared.fsm = overrideOrchestrator
			local fsm = {
				AttackerCharEntityId = context.AttackerCharEntityId,
				VictimUserId = context.VictimUserId,
				AttackName = context.AttackName,
				Context = {},
				State = nil,
				Failure = nil,
			}
			function fsm:Fail(reason)
				self.Failure = reason
			end
			validate(nil, fsm)
			return fsm
		end

		local noOrchestrator = runValidate({ AttackerCharEntityId = "Attacker_01", VictimUserId = 44 }, nil)
		t:AssertEquals(noOrchestrator.Failure, "Orchestrator unavailable", "Validate should require an orchestrator")

		local missingAttackerId = runValidate({ AttackerCharEntityId = nil, VictimUserId = 44 }, orchestrator)
		t:AssertEquals(missingAttackerId.Failure, "AttackerCharEntityId is required", "Validate should require AttackerCharEntityId")

		local attackerNotFound = runValidate({ AttackerCharEntityId = "Missing", VictimUserId = 44 }, orchestrator)
		t:AssertEquals(attackerNotFound.Failure, "Attacker entity not found", "Validate should require an attacker entity")

		local missingUserId = runValidate({ AttackerCharEntityId = "BrokenAttacker", VictimUserId = 44 }, {
			GetEntity = function(entityId)
				if entityId == "BrokenAttacker" then
					return { EntityId = "BrokenAttacker" }
				end
				return nil
			end,
		})
		t:AssertEquals(missingUserId.Failure, "Attacker entity missing UserId", "Validate should require attacker UserId")

		local missingVictim = runValidate({ AttackerCharEntityId = "Attacker_01", VictimUserId = nil }, orchestrator)
		t:AssertEquals(missingVictim.Failure, "VictimUserId is required", "Validate should require VictimUserId")

		local success = runValidate({ AttackerCharEntityId = "Attacker_01", VictimUserId = 44 }, orchestrator)
		t:AssertEquals(success.Failure, nil, "Validate should accept a valid damage request")
		t:AssertEquals(success.Context.AttackName, "BasicAttack", "Validate should default AttackName")
		t:AssertEquals(success.Context._attackerEntity, attackerEntity, "Validate should cache attacker entity")
		t:AssertEquals(success.Context._attackerUserId, 9001, "Validate should cache attacker UserId")
		t:Assert(type(success.Context._nonce) == "string" and success.Context._nonce ~= "", "Validate should generate a nonce")
		t:AssertEquals(success.State, "CheckHitNonce", "Validate should advance to CheckHitNonce")

		shared.fsm = originalOrchestrator
		cleanup()
	end)

	return tester:PrintSummary()
end

return Test_DamageJob
