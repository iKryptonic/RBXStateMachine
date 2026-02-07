--!strict
-- @Name UIInitializationFSM
-- @Author iKrypto
-- @Description State Machine for managing ServiceManager initialization sequence.

local UIInitializationFSM = {
	Definition = {
		Name = "UIInitializationFSM",
		ValidStates = { "Uninitialized", "ValidatingGUI", "CreatingEntities", "HookingInput", "Ready", "Error" },
		InitialState = "Uninitialized",
		TerminalStates = { "Ready", "Error" },
		Priority = 10  -- High priority for initialization
	}
}

function UIInitializationFSM:RegisterStates()
	
	-- State: Uninitialized
	self:AddState("Uninitialized", {
		OnEnter = function(fsm)
			fsm.Context.CreatedEntities = {}
			fsm.Context.ErrorMessage = nil
		end,
		OnHeartbeat = function(fsm, dt)
			-- Transition to validation when context signals readiness
			if fsm.Context.ShouldInitialize then
				fsm:ChangeState({ Name = "ValidatingGUI" })
			end
		end
	})
	
	-- State: ValidatingGUI
	self:AddState("ValidatingGUI", {
		OnEnter = function(fsm)
			local sm = fsm.Context.ServiceManager
			
			if not sm or not sm.GUI or not sm.GUI.MainFrame then
				fsm.Context.ErrorMessage = "[UIInitializationFSM] GUI.MainFrame is nil - GuiProvider failed to create GUI."
				fsm:ChangeState({ Name = "Error" })
				return
			end
			
			-- Validate critical GUI components
			local required = { "SidebarContainer", "BottomBarContainer", "BodyContainer", "TabContainer" }
			for _, compName in ipairs(required) do
				if not sm.GUI[compName] then
					fsm.Context.ErrorMessage = string.format("[UIInitializationFSM] Missing required GUI component: %s", compName)
					fsm:ChangeState({ Name = "Error" })
					return
				end
			end
			
			-- Validation passed
			fsm:ChangeState({ Name = "CreatingEntities" })
		end
	})
	
	-- State: CreatingEntities
	self:AddState("CreatingEntities", {
		OnEnter = function(fsm)
			local sm = fsm.Context.ServiceManager
			local orch = fsm.Context.Orchestrator
			
			if not orch then
				fsm.Context.ErrorMessage = "[UIInitializationFSM] Orchestrator not available"
				fsm:ChangeState({ Name = "Error" })
				return
			end
			
			local success, err = pcall(function()
				-- Create Window Entity
				local windowEntity = orch.CreateEntity({
					EntityClass = "WindowEntity",
					EntityId = "ServiceManager_Window",
					Context = {
						MainFrame = sm.GUI.MainFrame,
						ServiceManager = sm
					}
				})
				windowEntity:Initialize()
				sm.Entities.Window = windowEntity
				table.insert(fsm.Context.CreatedEntities, "ServiceManager_Window")
				
				-- Create Sidebar Entity
				local sidebarEntity = orch.CreateEntity({
					EntityClass = "SidebarEntity",
					EntityId = "ServiceManager_Sidebar",
					Context = {
						SidebarContainer = sm.GUI.SidebarContainer,
						ServiceManager = sm
					}
				})
				sidebarEntity:Initialize()
				sm.Entities.Sidebar = sidebarEntity
				table.insert(fsm.Context.CreatedEntities, "ServiceManager_Sidebar")
				
				-- Create BottomBar Entity
				local bottomBarEntity = orch.CreateEntity({
					EntityClass = "BottomBarEntity",
					EntityId = "ServiceManager_BottomBar",
					Context = {
						BottomBarContainer = sm.GUI.BottomBarContainer,
						ServiceManager = sm
					}
				})
				bottomBarEntity:Initialize()
				sm.Entities.BottomBar = bottomBarEntity
				table.insert(fsm.Context.CreatedEntities, "ServiceManager_BottomBar")
				
				-- Create Tab Entities
				for _, tabFrame in ipairs(sm.GUI.TabContainer:GetChildren()) do
					if tabFrame:IsA("Frame") then
						local tabName = tabFrame.Name
						local tabEntity = orch.CreateEntity({
							EntityClass = "TabEntity",
							EntityId = "ServiceManager_Tab_" .. tabName,
							Context = {
								TabName = tabName,
								TabFrame = tabFrame
							}
						})
						tabEntity:Initialize()
						tabEntity:SetupHoverEffects()
						sm.Entities.Tabs[tabName] = tabEntity
						table.insert(fsm.Context.CreatedEntities, "ServiceManager_Tab_" .. tabName)
					end
				end
			end)
			
			if not success then
				fsm.Context.ErrorMessage = "[UIInitializationFSM] Failed to create entities: " .. tostring(err)
				fsm:ChangeState({ Name = "Error" })
				return
			end
			
			fsm:ChangeState({ Name = "HookingInput" })
		end
	})
	
	-- State: HookingInput
	self:AddState("HookingInput", {
		OnEnter = function(fsm)
			local sm = fsm.Context.ServiceManager
			
			local success, err = pcall(function()
				-- Input handlers are managed by ServiceManagerClientEntity
				-- FSMs (Terminal, TabNavigation, ModeToggle) handle their own inputs
				-- This state exists for future expansion (e.g., custom hotkeys)
			end)
			
			if not success then
				fsm.Context.ErrorMessage = "[UIInitializationFSM] Failed to hook input: " .. tostring(err)
				fsm:ChangeState({ Name = "Error" })
				return
			end
			
			fsm:ChangeState({ Name = "Ready" })
		end
	})
	
	-- State: Ready
	self:AddState("Ready", {
		OnEnter = function(fsm)
			fsm.Logger:Log({
				Level = "INFO",
				Message = string.format("[UIInitializationFSM] Initialization complete. Created %d entities.", #fsm.Context.CreatedEntities),
				OperationId = fsm.Id
			})
			
			-- Signal completion
			if fsm.Context.OnReady then
				fsm.Context.OnReady()
			end
		end
	})
	
	-- State: Error
	self:AddState("Error", {
		OnEnter = function(fsm)
			local errorMsg = fsm.Context.ErrorMessage or "Unknown error"
			
			fsm.Logger:Log({
				Level = "ERROR",
				Message = errorMsg,
				OperationId = fsm.Id
			})
			
			-- Signal error
			if fsm.Context.OnError then
				fsm.Context.OnError(errorMsg)
			end
		end
	})
end

return UIInitializationFSM
