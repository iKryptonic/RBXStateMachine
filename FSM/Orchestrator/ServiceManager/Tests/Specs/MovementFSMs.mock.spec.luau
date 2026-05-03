--!strict

local TR = require(script.Parent.Parent.TestRunner)
local Helpers = require(script.Parent.MockSpecHelpers)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local DashFSM = require(Helpers.getStateMachine("DashFSM"))
	local JumpFSM = require(Helpers.getStateMachine("JumpFSM"))
	local LocomotionFSM = Helpers.getStateMachine("LocomotionFSM")

	describe("DashFSM", function()
		it("should complete TryDash happy path", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character, _, root = Helpers.makeCharacterRig(env, "DashCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				Stamina = 40,
			})
			local animations = {}

			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("DashFSM"), {
				StateMachineId = "Dash_Happy",
				CharacterEntityId = charEntity.EntityId,
				AutoStart = true,
				_onAnimate = function(name)
					table.insert(animations, name)
				end,
			})

			expect(DashFSM.TryDash(machine, "W")).toBeTruthy()
			env.Mock:StepFrames(5)
			expect(charEntity.Stamina).toEqual(25)
			expect(charEntity.ActionOverlay).toEqual("Dash_W")
			expect(animations).toContain("Dashing")
			expect(root:FindFirstChildOfClass("BodyVelocity")).never.toBeNil()

			expect(Helpers.stepUntil(env, machine, "Ready", 90)).toBeTruthy()
			expect(charEntity.ActionOverlay).toEqual("None")

			env:Cleanup()
		end)

		it("should reject TryDash when not in Ready state", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character = Helpers.makeCharacterRig(env, "DashBusyCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { Instance = character })
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("DashFSM"), {
				StateMachineId = "Dash_Busy",
				CharacterEntityId = charEntity.EntityId,
			})
			machine.State = "Cooldown"

			expect(DashFSM.TryDash(machine, "A")).toBeFalsy()
			expect(machine.State).toEqual("Cooldown")

			env:Cleanup()
		end)

		it("should return to Ready when stamina is insufficient", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character = Helpers.makeCharacterRig(env, "DashTiredCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				Stamina = 5,
			})
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("DashFSM"), {
				StateMachineId = "Dash_Tired",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(DashFSM.TryDash(machine, "D")).toBeTruthy()
			env.Mock:StepFrames(3)
			expect(machine.State).toEqual("Ready")
			expect(charEntity.Stamina).toEqual(5)

			env:Cleanup()
		end)
	end)

	describe("JumpFSM", function()
		it("should complete TryDoubleJump happy path", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character, humanoid, root = Helpers.makeCharacterRig(env, "JumpCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				Stamina = 50,
			})
			local animations = {}

			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("JumpFSM"), {
				StateMachineId = "Jump_Happy",
				CharacterEntityId = charEntity.EntityId,
				_onAnimate = function(name)
					table.insert(animations, name)
				end,
			})

			Helpers.setHumanoidState(humanoid, Enum.HumanoidStateType.Freefall)
			expect(Helpers.stepUntil(env, machine, "InAir", 10)).toBeTruthy()
			expect(JumpFSM.TryDoubleJump(machine)).toBeTruthy()
			env.Mock:StepFrames(10)
			expect(charEntity.Stamina).toEqual(30)
			expect(animations).toContain("FrontFlip")
			expect(root:FindFirstChildOfClass("BodyVelocity")).never.toBeNil()

			Helpers.setHumanoidState(humanoid, Enum.HumanoidStateType.Running)
			expect(Helpers.stepUntil(env, machine, "Cooldown", 60)).toBeTruthy()
			expect(Helpers.stepUntil(env, machine, "Grounded", 90)).toBeTruthy()
			expect(animations).toContain("SummonGroundCast")

			env:Cleanup()
		end)

		it("should reject TryDoubleJump when not InAir", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character = Helpers.makeCharacterRig(env, "JumpGrounded")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { Instance = character })
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("JumpFSM"), {
				StateMachineId = "Jump_Grounded",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(JumpFSM.TryDoubleJump(machine)).toBeFalsy()
			expect(machine.State).toEqual("Grounded")

			env:Cleanup()
		end)

		it("should reject TryDoubleJump when stamina is insufficient", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character, humanoid = Helpers.makeCharacterRig(env, "JumpTired")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
				Stamina = 10,
			})
			local machine = env.Mock:CreateFSM(Helpers.getStateMachine("JumpFSM"), {
				StateMachineId = "Jump_Tired",
				CharacterEntityId = charEntity.EntityId,
			})

			Helpers.setHumanoidState(humanoid, Enum.HumanoidStateType.Freefall)
			expect(Helpers.stepUntil(env, machine, "InAir", 10)).toBeTruthy()
			expect(JumpFSM.TryDoubleJump(machine)).toBeFalsy()
			expect(machine.State).toEqual("InAir")
			expect(charEntity.Stamina).toEqual(10)

			env:Cleanup()
		end)
	end)

	describe("LocomotionFSM", function()
		it("should transition Idle to Walking to Running to Airborne", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character, humanoid, root = Helpers.makeCharacterRig(env, "LocomotionCharacter")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", {
				Instance = character,
			})
			local machine = env.Mock:CreateFSM(LocomotionFSM, {
				StateMachineId = "Locomotion_Path",
				CharacterEntityId = charEntity.EntityId,
			})

			expect(machine.State).toEqual("Idle")
			expect(charEntity.LocomotionState).toEqual("Idle")

			root.AssemblyLinearVelocity = Vector3.new(5, 0, 0)
			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("Walking")
			expect(charEntity.LocomotionState).toEqual("Walking")

			root.AssemblyLinearVelocity = Vector3.new(30, 0, 0)
			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("Running")
			expect(charEntity.LocomotionState).toEqual("Running")

			Helpers.setHumanoidState(humanoid, Enum.HumanoidStateType.Freefall)
			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("Airborne")
			expect(charEntity.LocomotionState).toEqual("Airborne")

			env:Cleanup()
		end)

		it("should remain Idle when speed stays below the walk threshold", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character, _, root = Helpers.makeCharacterRig(env, "LocomotionIdle")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { Instance = character })
			local machine = env.Mock:CreateFSM(LocomotionFSM, {
				StateMachineId = "Locomotion_Idle",
				CharacterEntityId = charEntity.EntityId,
			})

			root.AssemblyLinearVelocity = Vector3.new(1, 0, 0)
			env.Mock:StepFrames(3)
			expect(machine.State).toEqual("Idle")
			expect(charEntity.LocomotionState).toEqual("Idle")

			env:Cleanup()
		end)

		it("should fall back from Airborne to Idle when landing without movement", function()
			local env = Helpers.newEnvironment()
			Helpers.registerDefaultModules(env)

			local character, humanoid, root = Helpers.makeCharacterRig(env, "LocomotionLanding")
			local charEntity = Helpers.createCharacterEntity(env, "Char_1", { Instance = character })
			local machine = env.Mock:CreateFSM(LocomotionFSM, {
				StateMachineId = "Locomotion_Landing",
				CharacterEntityId = charEntity.EntityId,
			})

			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			Helpers.setHumanoidState(humanoid, Enum.HumanoidStateType.Freefall)
			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("Airborne")

			Helpers.setHumanoidState(humanoid, Enum.HumanoidStateType.Running)
			env.Mock:StepFrames(2)
			expect(machine.State).toEqual("Idle")
			expect(charEntity.LocomotionState).toEqual("Idle")

			env:Cleanup()
		end)
	end)
end

TR.register(spec)
return spec
