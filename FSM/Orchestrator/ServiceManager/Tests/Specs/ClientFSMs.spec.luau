--!strict
-- @Name ServiceManager/Tests/Specs/ClientFSMs.spec.luau
-- @Description Contract tests for the client-observable FSMs.

local TR = require(script.Parent.Parent.TestRunner)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	local WALK_THRESHOLD = 2
	local RUN_THRESHOLD = 22
	local DASH_COOLDOWN = 0.75
	local JUMP_COOLDOWN = 1

	local function makeLocomotionFSM(): any
		return {
			State = "Idle",
			Context = {
				LocomotionState = "Idle",
				Speed = 0,
				HumanoidState = "Running",
			},
		}
	end

	local function locomotionStep(fsm: any, speed: number, humanoidState: string)
		fsm.Context.Speed = speed
		fsm.Context.HumanoidState = humanoidState
		local airborne = humanoidState == "Jumping" or humanoidState == "Freefall" or humanoidState == "FallingDown"
		local nextState = "Idle"
		if airborne then
			nextState = "Airborne"
		elseif speed > RUN_THRESHOLD then
			nextState = "Running"
		elseif speed > WALK_THRESHOLD then
			nextState = "Walking"
		end
		fsm.State = nextState
		fsm.Context.LocomotionState = nextState
	end

	local function makeInputModeFSM(): any
		return {
			State = "CombatInput",
			Context = {
				MouseLocked = true,
				InputMode = "Combat",
			},
		}
	end

	local function inputSetCombat(fsm: any)
		fsm.State = "CombatInput"
		fsm.Context.MouseLocked = true
		fsm.Context.InputMode = "Combat"
	end

	local function inputSetUI(fsm: any)
		fsm.State = "UIInput"
		fsm.Context.MouseLocked = false
		fsm.Context.InputMode = "UI"
	end

	local function inputToggle(fsm: any)
		if fsm.State == "UIInput" then
			inputSetCombat(fsm)
		else
			inputSetUI(fsm)
		end
	end

	local function makeDashFSM(stamina: number?): any
		return {
			State = "Ready",
			Now = 0,
			Context = {
				_dashDirection = nil,
				ActionOverlay = "None",
				Stamina = stamina or 100,
				AnimateCalls = {},
			},
		}
	end

	local function dashTry(fsm: any, direction: string): boolean
		if fsm.State ~= "Ready" then
			return false
		end
		fsm.Context._dashDirection = direction
		fsm.Context.Stamina = math.max(0, fsm.Context.Stamina - 15)
		fsm.Context.ActionOverlay = "Dash_" .. direction
		fsm.Context._dashEndsAt = fsm.Now + 0.25
		fsm.State = "Dashing"
		return true
	end

	local function dashAdvance(fsm: any, now: number)
		fsm.Now = now
		if fsm.State == "Dashing" and now >= (fsm.Context._dashEndsAt or math.huge) then
			fsm.State = "Cooldown"
			fsm.Context.ActionOverlay = "None"
			fsm.Context._cooldownEndsAt = now + DASH_COOLDOWN
		elseif fsm.State == "Cooldown" and now >= (fsm.Context._cooldownEndsAt or math.huge) then
			fsm.State = "Ready"
			fsm.Context._dashDirection = nil
		end
	end

	local function makeJumpFSM(): any
		return {
			State = "Grounded",
			Now = 0,
			Context = {
				Airborne = false,
				_flipRequested = false,
			},
		}
	end

	local function jumpAirborne(fsm: any, airborne: boolean)
		fsm.Context.Airborne = airborne
		if fsm.State == "Grounded" and airborne then
			fsm.State = "InAir"
			fsm.Context._flipRequested = false
		elseif fsm.State == "Flipping" and not airborne then
			fsm.State = "Cooldown"
			fsm.Context._cooldownEndsAt = fsm.Now + JUMP_COOLDOWN
		elseif fsm.State == "InAir" and not airborne then
			fsm.State = "Grounded"
		end
	end

	local function jumpTryFlip(fsm: any): boolean
		if fsm.State ~= "InAir" then
			return false
		end
		fsm.Context._flipRequested = true
		fsm.State = "Flipping"
		fsm.Context._flipEndsAt = fsm.Now + 3
		return true
	end

	local function jumpAdvance(fsm: any, now: number)
		fsm.Now = now
		if fsm.State == "Flipping" and now >= (fsm.Context._flipEndsAt or math.huge) then
			fsm.State = "Cooldown"
			fsm.Context._cooldownEndsAt = now + JUMP_COOLDOWN
		elseif fsm.State == "Cooldown" and now >= (fsm.Context._cooldownEndsAt or math.huge) then
			fsm.State = "Grounded"
		end
	end

	describe("LocomotionFSM", function()
		it("starts in Idle", function()
			local fsm = makeLocomotionFSM()
			expect(fsm.State).toEqual("Idle")
			expect(fsm.Context.LocomotionState).toEqual("Idle")
		end)

		it("transitions to Walking when speed is above 2", function()
			local fsm = makeLocomotionFSM()
			locomotionStep(fsm, WALK_THRESHOLD + 1, "Running")
			expect(fsm.State).toEqual("Walking")
		end)

		it("transitions to Running when speed is above 22", function()
			local fsm = makeLocomotionFSM()
			locomotionStep(fsm, RUN_THRESHOLD + 1, "Running")
			expect(fsm.State).toEqual("Running")
		end)

		it("transitions to Airborne when jumping or falling", function()
			local fsm = makeLocomotionFSM()
			locomotionStep(fsm, 0, "Jumping")
			expect(fsm.State).toEqual("Airborne")
			locomotionStep(fsm, 0, "Freefall")
			expect(fsm.State).toEqual("Airborne")
		end)

		it("returns to Idle when speed drops below threshold", function()
			local fsm = makeLocomotionFSM()
			locomotionStep(fsm, 10, "Running")
			locomotionStep(fsm, 1, "Running")
			expect(fsm.State).toEqual("Idle")
		end)
	end)

	describe("InputModeFSM", function()
		it("starts in CombatInput", function()
			local fsm = makeInputModeFSM()
			expect(fsm.State).toEqual("CombatInput")
			expect(fsm.Context.MouseLocked).toBeTruthy()
		end)

		it("toggles to UIInput", function()
			local fsm = makeInputModeFSM()
			inputToggle(fsm)
			expect(fsm.State).toEqual("UIInput")
			expect(fsm.Context.InputMode).toEqual("UI")
			expect(fsm.Context.MouseLocked).toBeFalsy()
		end)

		it("toggles back to CombatInput", function()
			local fsm = makeInputModeFSM()
			inputSetUI(fsm)
			inputToggle(fsm)
			expect(fsm.State).toEqual("CombatInput")
			expect(fsm.Context.InputMode).toEqual("Combat")
		end)
	end)

	describe("DashFSM", function()
		it("starts in Ready", function()
			local fsm = makeDashFSM()
			expect(fsm.State).toEqual("Ready")
		end)

		it("transitions to Dashing on TryDash", function()
			local fsm = makeDashFSM()
			local ok = dashTry(fsm, "W")
			expect(ok).toBeTruthy()
			expect(fsm.State).toEqual("Dashing")
			expect(fsm.Context.ActionOverlay).toEqual("Dash_W")
		end)

		it("transitions to Cooldown after dash timeout", function()
			local fsm = makeDashFSM()
			dashTry(fsm, "A")
			dashAdvance(fsm, 0.25)
			expect(fsm.State).toEqual("Cooldown")
			expect(fsm.Context.ActionOverlay).toEqual("None")
		end)

		it("returns to Ready after cooldown", function()
			local fsm = makeDashFSM()
			dashTry(fsm, "D")
			dashAdvance(fsm, 0.25)
			dashAdvance(fsm, 1.0)
			expect(fsm.State).toEqual("Ready")
		end)

		it("rejects dash while in Cooldown", function()
			local fsm = makeDashFSM()
			dashTry(fsm, "S")
			dashAdvance(fsm, 0.25)
			local ok = dashTry(fsm, "W")
			expect(ok).toBeFalsy()
			expect(fsm.State).toEqual("Cooldown")
		end)
	end)

	describe("JumpFSM", function()
		it("starts in Grounded", function()
			local fsm = makeJumpFSM()
			expect(fsm.State).toEqual("Grounded")
		end)

		it("transitions to InAir when airborne", function()
			local fsm = makeJumpFSM()
			jumpAirborne(fsm, true)
			expect(fsm.State).toEqual("InAir")
		end)

		it("transitions to Flipping on flip request", function()
			local fsm = makeJumpFSM()
			jumpAirborne(fsm, true)
			local ok = jumpTryFlip(fsm)
			expect(ok).toBeTruthy()
			expect(fsm.State).toEqual("Flipping")
		end)

		it("transitions to Cooldown on landing", function()
			local fsm = makeJumpFSM()
			jumpAirborne(fsm, true)
			jumpTryFlip(fsm)
			jumpAirborne(fsm, false)
			expect(fsm.State).toEqual("Cooldown")
		end)

		it("returns to Grounded after cooldown", function()
			local fsm = makeJumpFSM()
			jumpAirborne(fsm, true)
			jumpTryFlip(fsm)
			jumpAirborne(fsm, false)
			jumpAdvance(fsm, 2)
			expect(fsm.State).toEqual("Grounded")
		end)
	end)
end

TR.register(spec)
return spec
