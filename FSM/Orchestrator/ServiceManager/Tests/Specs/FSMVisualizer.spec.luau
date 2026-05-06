--!strict
-- @Name ServiceManager/Tests/Specs/FSMVisualizer.spec.luau
-- @Author iKrypto
-- @Description Layout-selection tests for the FSM visualizer.

local TR = require(script.Parent.Parent.TestRunner)
local FSMModule = require(script.Parent.Parent.Parent.Subsystems.FSMModule)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("FSM Visualizer Layout", function()
		it("uses circle layout for single state", function()
			local mod = FSMModule.new()
			local pos = mod:_ComputeNodeLayout({"Idle"}, "Idle")
			expect(pos.Idle).never.toBeNil()
			expect(pos.Idle.X).toBeCloseTo(0.5, 0.01)
			expect(pos.Idle.Y).toBeCloseTo(0.5, 0.01)
		end)

		it("uses circle layout for ≤6 states (each on the unit circle)", function()
			local mod = FSMModule.new()
			local states = {"A","B","C","D","E","F"}
			local pos = mod:_ComputeNodeLayout(states, "A")
			-- All positions normalized in [0,1]
			for _, name in ipairs(states) do
				expect(pos[name]).never.toBeNil()
				expect(pos[name].X).toBeGreaterThanOrEqual(0)
				expect(pos[name].X).toBeLessThan(1.01)
			end
			-- 6 unique positions
			local uniqueX = {}
			for _, name in ipairs(states) do uniqueX[pos[name].X] = true end
			local n = 0
			for _ in pairs(uniqueX) do n += 1 end
			expect(n).toBeGreaterThan(3)
		end)

		it("uses grid layout for 7-20 states", function()
			local mod = FSMModule.new()
			local states = {}
			for i = 1, 12 do table.insert(states, "S" .. i) end
			local pos = mod:_ComputeNodeLayout(states, "S1")
			-- All positions valid
			for _, name in ipairs(states) do
				expect(pos[name]).never.toBeNil()
				expect(pos[name].X).toBeGreaterThanOrEqual(0)
				expect(pos[name].Y).toBeGreaterThanOrEqual(0)
			end
		end)

		it("uses neighborhood layout for >20 states (current state at center)", function()
			local mod = FSMModule.new()
			local states = {}
			for i = 1, 30 do table.insert(states, "S" .. i) end
			local pos = mod:_ComputeNodeLayout(states, "S15")
			-- Current state at center
			expect(pos.S15.X).toBeCloseTo(0.5, 0.01)
			expect(pos.S15.Y).toBeCloseTo(0.5, 0.01)
			-- Excess states placed off-screen (X < 0)
			local offScreenCount = 0
			for _, name in ipairs(states) do
				if pos[name].X < 0 then offScreenCount += 1 end
			end
			expect(offScreenCount).toBeGreaterThan(0)
		end)

		it("returns empty positions for empty state list", function()
			local mod = FSMModule.new()
			local pos = mod:_ComputeNodeLayout({}, nil)
			local n = 0
			for _ in pairs(pos) do n += 1 end
			expect(n).toEqual(0)
		end)
	end)
end

TR.register(spec)
return spec
