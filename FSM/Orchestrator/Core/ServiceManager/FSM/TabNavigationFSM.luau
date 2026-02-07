--!strict
-- @Name TabNavigationFSM
-- @Author iKrypto
-- @Description State Machine for managing tab switching and page transitions.

local TweenService = game:GetService("TweenService")

local TabNavigationFSM = {
	Definition = {
		Name = "TabNavigationFSM",
		ValidStates = { "Idle", "CleaningPreviousPage", "HidingPreviousPage", "ShowingNewPage", "UpdatingNewPage" },
		InitialState = "Idle",
		Priority = 6  -- Medium-high priority for UI responsiveness
	}
}

function TabNavigationFSM:RegisterStates()
	
	-- State: Idle
	self:AddState("Idle", {
		OnEnter = function(fsm)
			fsm.Context.IsNavigating = false
		end,
		OnHeartbeat = function(fsm, dt)
			-- Check if navigation requested
			if fsm.Context.TargetTab and fsm.Context.TargetTab ~= fsm.Context.CurrentTab then
				fsm:ChangeState({ Name = "CleaningPreviousPage" })
			end
		end
	})
	
	-- State: CleaningPreviousPage
	self:AddState("CleaningPreviousPage", {
		OnEnter = function(fsm)
			fsm.Context.IsNavigating = true
			local currentTab = fsm.Context.CurrentTab
			local pages = fsm.Context.Pages
			
			if not currentTab or not pages or not pages[currentTab] then
				-- No previous page to clean
				fsm:ChangeState({ Name = "ShowingNewPage" })
				return
			end
			
			local prevPage = pages[currentTab]
			
			-- Disconnect connections
			if prevPage.Connections then
				for _, conn in ipairs(prevPage.Connections) do
					if typeof(conn) == "RBXScriptConnection" then
						conn:Disconnect()
					end
				end
				prevPage.Connections = {}
			end
			
			-- Clear transient UI elements
			if prevPage.Container and prevPage.Container.Parent then
				local view = prevPage.Container.Parent
				local transientNames = {
					["Toolbar"] = true,
					["Controls"] = true,
					["StateMachineList"] = true,
					["Search"] = true,
					["ActionsPanel"] = true
				}
				
				for _, child in ipairs(view:GetChildren()) do
					if transientNames[child.Name] then
						child:Destroy()
					end
				end
				
				-- Clear hook markers
				for _, descendant in ipairs(view:GetDescendants()) do
					if descendant.Name == "IsHooked" or descendant.Name == "Hooked" or descendant.Name == "Hover" then
						descendant:Destroy()
					end
				end
			end
			
			fsm:ChangeState({ Name = "HidingPreviousPage" })
		end
	})
	
	-- State: HidingPreviousPage
	self:AddState("HidingPreviousPage", {
		OnEnter = function(fsm)
			local currentTab = fsm.Context.CurrentTab
			local pages = fsm.Context.Pages
			
			if not currentTab or not pages or not pages[currentTab] or not pages[currentTab].Container then
				fsm:ChangeState({ Name = "ShowingNewPage" })
				return
			end
			
			local prevView = pages[currentTab].Container.Parent
			if not prevView or not prevView:IsA("GuiObject") then
				fsm:ChangeState({ Name = "ShowingNewPage" })
				return
			end
			
			-- Tween out
			local tweenInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			local tween = TweenService:Create(prevView, tweenInfo, { Position = UDim2.new(0, -10, 0, 0) })
			
			tween.Completed:Connect(function()
				prevView.Visible = false
				prevView.Position = UDim2.new(0, 0, 0, 0)  -- Reset position
				fsm:ChangeState({ Name = "ShowingNewPage" })
			end)
			
			tween:Play()
		end
	})
	
	-- State: ShowingNewPage
	self:AddState("ShowingNewPage", {
		OnEnter = function(fsm)
			local targetTab = fsm.Context.TargetTab
			local pages = fsm.Context.Pages
			local tabEntities = fsm.Context.TabEntities
			
			if not targetTab or not pages or not pages[targetTab] then
				fsm.Logger:Log({ Level = "WARN", Message = string.format("[TabNavigationFSM] Invalid target tab: %s", tostring(targetTab)) })
				fsm:ChangeState({ Name = "Idle" })
				return
			end
			
			local newView = pages[targetTab].Container.Parent
			if not newView or not newView:IsA("GuiObject") then
				fsm:ChangeState({ Name = "Idle" })
				return
			end
			
			-- Update tab entities
			if tabEntities then
				for tabName, tabEntity in pairs(tabEntities) do
					if tabName == targetTab then
						tabEntity:Activate()
					else
						tabEntity:Deactivate()
					end
				end
			end
			
			-- Show and tween in
			newView.Visible = true
			newView.Position = UDim2.new(0, 6, 0, 0)
			
			local tweenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local tween = TweenService:Create(newView, tweenInfo, { Position = UDim2.new(0, 0, 0, 0) })
			
			tween.Completed:Connect(function()
				fsm:ChangeState({ Name = "UpdatingNewPage" })
			end)
			
			tween:Play()
		end
	})
	
	-- State: UpdatingNewPage
	self:AddState("UpdatingNewPage", {
		OnEnter = function(fsm)
			local targetTab = fsm.Context.TargetTab
			local pages = fsm.Context.Pages
			
			if pages and pages[targetTab] and pages[targetTab].UpdateFunction then
				local success, err = pcall(function()
					pages[targetTab]:UpdateFunction()
				end)
				
				if not success then
					fsm.Logger:Log({
						Level = "WARN",
						Message = string.format("[TabNavigationFSM] Failed to update page %s: %s", targetTab, tostring(err))
					})
				end
			end
			
			-- Navigation complete
			fsm.Context.CurrentTab = targetTab
			fsm.Context.TargetTab = nil
			fsm:ChangeState({ Name = "Idle" })
		end
	})
end

return TabNavigationFSM
