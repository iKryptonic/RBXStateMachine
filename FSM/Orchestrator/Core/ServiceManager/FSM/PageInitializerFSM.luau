--!strict
-- PageInitializerFSM.luau
-- FSM responsible for orchestrating page entity and FSM initialization

local PageInitializerFSM = {
	Definition = {
		className = "PageInitializerFSM",
		validStates = {
			"Initializing",
			"LocatingContainers",
			"CreatingEntities",
			"CreatingFSMs",
			"Completed",
			"Failed",
			"Destroyed"
		},
		terminalStates = { "Completed", "Failed", "Destroyed" },
		InitialState = "Initializing",
		Priority = 1 -- High priority for initialization
	}
}

--[[
	@description Registers all states for the PageInitializer FSM
	@return ()
]]
function PageInitializerFSM:RegisterStates()
	self:AddState("Initializing", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = "Starting page initialization..." })
			
			-- Initialize storage
			fsm.Context.ServiceManager.PageEntities = {}
			fsm.Context.ServiceManager.PageFSMs = {}
			fsm.PageContainers = {}
			
			fsm:ChangeState({ Name = "LocatingContainers" })
		end
	})
	
	self:AddState("LocatingContainers", {
		OnEnter = function(fsm)
			local serviceManager = fsm.Context.ServiceManager
			
			-- Map of page names to their corresponding GUI containers
			local pageNames = {
				"Console", "Logs", "TaskList", "Performance", 
				"History", "FSMs", "Entities", "Settings", 
				"Visualize", "CreateTask"
			}
			
			for _, pageName in ipairs(pageNames) do
				local viewFrame = serviceManager.GUI.BodyContainer:FindFirstChild(pageName .. "View")
				if viewFrame then
					local container = viewFrame:FindFirstChild("Container")
					local tabButton = serviceManager.GUI.TabContainer:FindFirstChild(pageName)
					
					fsm.PageContainers[pageName] = {
						ViewFrame = viewFrame,
						Container = container,
						TabButton = tabButton
					}
				else
					fsm:Log({ Level = "WARN", Message = string.format("View not found: %sView", pageName) })
				end
			end
			
			fsm:Log({ Level = "INFO", Message = string.format("Located %d page containers", 
				(function()
					local count = 0
					for _ in pairs(fsm.PageContainers) do count += 1 end
					return count
				end)()
			)})
			
			fsm:ChangeState({ Name = "CreatingEntities" })
		end
	})
	
	self:AddState("CreatingEntities", {
		OnEnter = function(fsm)
			local serviceManager = fsm.Context.ServiceManager
			local orchestrator = fsm.Context.Orchestrator
			local colors = fsm.Context.COLORS
			
			if not orchestrator then
				fsm:Log({ Level = "ERROR", Message = "No Orchestrator available" })
				fsm:ChangeState({ Name = "Failed" })
				return
			end
			
			local entityCount = 0
			local pages = serviceManager.Pages -- Optional legacy page controllers (deprecated)
			
			for pageName, refs in pairs(fsm.PageContainers) do
				local pageController = pages and pages[pageName] -- Optional legacy fallback
				local entitySuccess, entityResult = pcall(function()
					return orchestrator.CreateEntity({
						EntityClass = pageName .. "PageEntity",
						EntityId = pageName .. "PageEntity",
						Context = {
							ServiceManager = serviceManager,
							ViewContainer = refs.ViewFrame,
							Container = refs.Container,
							TabButton = refs.TabButton,
							PageController = pageController,
							COLORS = colors
						}
					})
				end)
				
				if entitySuccess then
					serviceManager.PageEntities[pageName] = entityResult
					entityCount += 1
				else
					fsm:Log({ Level = "ERROR", Message = string.format("Failed to create %sPageEntity: %s", pageName, tostring(entityResult)) })
				end
			end
			
			fsm:Log({ Level = "INFO", Message = string.format("Created %d page entities", entityCount) })
			fsm:ChangeState({ Name = "CreatingFSMs" })
		end
	})
	
	self:AddState("CreatingFSMs", {
		OnEnter = function(fsm)
			local serviceManager = fsm.Context.ServiceManager
			local orchestrator = fsm.Context.Orchestrator
			local colors = fsm.Context.COLORS
			
			local fsmCount = 0
			
			local pages = serviceManager.Pages -- Optional legacy page controllers (deprecated)
			
			for pageName, _ in pairs(fsm.PageContainers) do
				-- Only create FSM if entity was created successfully
				if serviceManager.PageEntities[pageName] then
					local pageController = pages and pages[pageName]
					local fsmSuccess, fsmResult = pcall(function()
						return orchestrator.CreateStateMachine({
							StateMachineClass = pageName .. "PageFSM",
							StateMachineId = pageName .. "PageFSM",
							Context = {
								PageEntity = serviceManager.PageEntities[pageName],
								PageController = pageController,
								ServiceManager = serviceManager,
								COLORS = colors
							}
						})
					end)
					
					if fsmSuccess then
						serviceManager.PageFSMs[pageName] = fsmResult
						fsmCount += 1
					else
						fsm:Log({ Level = "ERROR", Message = string.format("Failed to create %sPageFSM: %s", pageName, tostring(fsmResult)) })
					end
				end
			end
			
			fsm:Log({ Level = "INFO", Message = string.format("Created %d page FSMs", fsmCount) })
			fsm:ChangeState({ Name = "Completed" })
		end
	})
	
	self:AddState("Completed", {
		OnEnter = function(fsm)
			local entityCount = 0
			local fsmCount = 0
			
			for _ in pairs(fsm.Context.ServiceManager.PageEntities) do entityCount += 1 end
			for _ in pairs(fsm.Context.ServiceManager.PageFSMs) do fsmCount += 1 end
			
			fsm:Log({ Level = "INFO", Message = string.format("Page initialization complete: %d entities, %d FSMs", entityCount, fsmCount) })
		end
	})
	
	self:AddState("Failed", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "ERROR", Message = "Page initialization failed" })
		end
	})
	
	self:AddState("Destroyed", {
		OnEnter = function(fsm)
			fsm:Log({ Level = "INFO", Message = "PageInitializerFSM destroyed" })
		end
	})
end

--[[
	@description Cleanup handler
	@return ()
]]
function PageInitializerFSM:OnCleanup()
	self.PageContainers = nil
end

return PageInitializerFSM
