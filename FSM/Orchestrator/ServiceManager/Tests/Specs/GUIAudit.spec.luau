--!strict
-- @Name ServiceManager/Tests/Specs/GUIAudit.spec.luau
-- @Description Regression tests for GUI audit fixes in ServiceManager.

local TR = require(script.Parent.Parent.TestRunner)
local MockNexus = require(script.Parent.Parent.Mocks.MockNexus)
local MockOrchestrator = require(script.Parent.Parent.Mocks.MockOrchestrator)
local ConsoleModule = require(script.Parent.Parent.Parent.Subsystems.ConsoleModule)
local EntityModule = require(script.Parent.Parent.Parent.Subsystems.EntityModule)
local ProfilerModule = require(script.Parent.Parent.Parent.Subsystems.ProfilerModule)
local GlassGUI = require(script.Parent.Parent.Parent.GlassGUI)
local ServiceBrain = require(script.Parent.Parent.Parent.ServiceBrain)

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("GUI audit regressions", function()
		describe("ConsoleModule", function()
			it("renders newest output after the buffer trims", function()
				local mod = ConsoleModule.new()
				local scroll = Instance.new("ScrollingFrame")
				mod._scrollFrame = scroll

				for i = 1, 500 do
					mod:_PushLine("INFO", string.format("line_%03d", i))
				end
				mod:_RenderOutput()
				mod:_PushLine("INFO", "line_501")
				mod:_RenderOutput()

				local labelCount = 0
				local foundOldest = false
				local foundNewest = false
				for _, child in ipairs(scroll:GetChildren()) do
					if child:IsA("TextLabel") then
						labelCount += 1
						if child.Text == "line_001" then
							foundOldest = true
						elseif child.Text == "line_501" then
							foundNewest = true
						end
					end
				end

				expect(labelCount).toEqual(500)
				expect(foundOldest).toBeFalsy()
				expect(foundNewest).toBeTruthy()
			end)
		end)

		describe("EntityModule", function()
			it("ignores malformed version history entries", function()
				local mod = EntityModule.new()
				local ok, data = pcall(function()
					return mod:_ExtractEntityData("E1", {
						_privateProperties = {
							Name = "Entity",
							_versionHistory = {
								{ Version = 1, Time = 123, Changes = true },
							},
						},
					})
				end)
				expect(ok).toBeTruthy()
				expect(data.VersionHistory).toHaveLength(0)
			end)

			it("marks disappeared server entities as dead", function()
				local mod = EntityModule.new()
				mod._entityCache = {
					E1 = {
						Id = "E1",
						IsValid = true,
						CreatedAt = 1,
					},
				}
				local nexus = MockNexus.new({
					contextMode = "server",
					orchestrator = MockOrchestrator.new(),
					serverData = { Entities = { List = {} } },
				})

				mod:FetchData(nexus)

				expect(mod._entityCache.E1).toBeNil()
				expect(mod._deadEntities.E1).never.toBeNil()
				expect(mod._deadEntities.E1.IsValid).toEqual(false)
			end)
		end)

		describe("ProfilerModule", function()
			it("reads client FPS from nexus state", function()
				local mod = ProfilerModule.new()
				local nexus = MockNexus.new({
					fps = 37,
					orchestrator = MockOrchestrator.new(),
				})

				mod:FetchData(nexus)

				expect(mod._frameBudget.FPS).toEqual(37)
			end)

			it("clears stale server data when the snapshot is nil", function()
				local mod = ProfilerModule.new()
				mod._taskPerf = { Foo = {} }
				mod._fsmPerf = { Bar = {} }
				mod._networkTraffic = { { Name = "Remote" } }
				mod._gcStats.MemoryMB = 12
				mod._frameBudget.UsedMs = 9

				mod:_FetchServer(nil)

				expect(next(mod._taskPerf)).toBeNil()
				expect(next(mod._fsmPerf)).toBeNil()
				expect(#mod._networkTraffic).toEqual(0)
				expect(mod._gcStats.MemoryMB).toEqual(0)
				expect(mod._frameBudget.UsedMs).toEqual(0)
			end)
		end)

		describe("GlassGUI", function()
			it("updates zero-value status snapshots", function()
				local guiHost = Instance.new("Folder")
				local gui = GlassGUI.new(guiHost :: any)
				gui:Build()

				gui:UpdateStatusBar({ InsightCount = 3, FPS = 48 })
				gui:UpdateStatusBar({ InsightCount = 0, FPS = 0 })

				local statusBar = gui._statusBar
				local insightLabel = statusBar and statusBar:FindFirstChild("InsightLabel")
				local perfLabel = statusBar and statusBar:FindFirstChild("PerfLabel")
				expect(insightLabel).never.toBeNil()
				expect(perfLabel).never.toBeNil()
				expect((insightLabel :: TextLabel).Text).toEqual("0 insights")
				expect((perfLabel :: TextLabel).Text).toEqual("0 fps")

				gui:Destroy()
				guiHost:Destroy()
			end)
		end)

		describe("ServiceBrain", function()
			it("ticks animations once on idle frames", function()
				local BehaviorTree = require(game.ReplicatedStorage.Orchestrator.Core.Factory.BehaviorTree)
				BehaviorTree.Initialize({
					Logger = {
						new = function()
							return { Log = function() end }
						end,
					},
				})
				ServiceBrain.Initialize({ Factory = { BehaviorTree = BehaviorTree } })

				local tickCount = 0
				local nexus = MockNexus.new({ orchestrator = MockOrchestrator.new() })
				nexus._initialized = true
				nexus.ActiveSubsystem = "TASKS"
				nexus._lastDataRefresh = os.clock()
				nexus._subsystemModules = {}
				nexus._animationController = {
					Tick = function()
						tickCount += 1
					end,
				}

				local tree = ServiceBrain.Build()
				local status = tree({ Nexus = nexus })

				expect(status).toEqual(BehaviorTree.BehaviorTreeStatus.Success)
				expect(tickCount).toEqual(1)
			end)
		end)
	end)
end

TR.register(spec)
return spec
