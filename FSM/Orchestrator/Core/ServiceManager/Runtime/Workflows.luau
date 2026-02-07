--!strict
-- @Name Workflows
-- @Author iKrypto
-- @Description Centralized behavior tree definitions for ServiceManager workflows.

local BehaviorTree = require(script.Parent.Parent.Parent.Factory.BehaviorTree)
local BT = BehaviorTree

local Workflows = {}

--[=[
	@description Validates that the GUI structure is complete and ready for use.
	@param ctx { GUI: { MainFrame: any, SidebarContainer: any, BodyContainer: any, TabContainer: any } }
	@return BehaviorTreeStatus
]=]
Workflows.ValidateGUIStructure = BT.Sequence({
	BT.Condition(function(ctx)
		return ctx.GUI ~= nil
	end),
	BT.Condition(function(ctx)
		return ctx.GUI.MainFrame ~= nil
	end),
	BT.Condition(function(ctx)
		return ctx.GUI.SidebarContainer ~= nil
	end),
	BT.Condition(function(ctx)
		return ctx.GUI.BodyContainer ~= nil
	end),
	BT.Condition(function(ctx)
		return ctx.GUI.TabContainer ~= nil
	end),
})

--[=[
	@description Validates that the Orchestrator is available and initialized.
	@param ctx { Orchestrator: any }
	@return BehaviorTreeStatus
]=]
Workflows.ValidateOrchestrator = BT.Sequence({
	BT.Condition(function(ctx)
		return ctx.Orchestrator ~= nil
	end),
	BT.Condition(function(ctx)
		return ctx.Orchestrator.Factory ~= nil
	end),
	BT.Condition(function(ctx)
		return ctx.Orchestrator.CreateEntity ~= nil and type(ctx.Orchestrator.CreateEntity) == "function"
	end),
})

--[=[
	@description Page transition workflow: cleanup → hide → show → update.
	Used as a reference for TabNavigationFSM (not executed directly).
	The FSM implements this sequence via state transitions.
]=]
Workflows.PageTransitionWorkflow = BT.Sequence({
	-- Step 1: Cleanup previous page
	BT.Condition(function(ctx)
		if not ctx.PreviousPage then return true end
		
		-- Disconnect connections
		if ctx.PreviousPage.Connections then
			for _, conn in ipairs(ctx.PreviousPage.Connections) do
				if typeof(conn) == "RBXScriptConnection" then
					conn:Disconnect()
				end
			end
			ctx.PreviousPage.Connections = {}
		end
		
		-- Clear transients (handled by FSM, just validate here)
		return true
	end),
	
	-- Step 2: Hide previous page (handled by FSM tween)
	BT.Condition(function(ctx)
		return ctx.PreviousTweenComplete or not ctx.PreviousPage
	end),
	
	-- Step 3: Show new page (handled by FSM tween)
	BT.Condition(function(ctx)
		return ctx.NewTweenComplete or not ctx.NewPage
	end),
	
	-- Step 4: Update new page
	BT.Condition(function(ctx)
		if not ctx.NewPage or not ctx.NewPage.UpdateFunction then return true end
		
		local success = pcall(function()
			ctx.NewPage:UpdateFunction()
		end)
		
		return success
	end),
})

--[=[
	@description Mode transition workflow: clear data → update entities → sync.
	Used as a reference for ModeToggleFSM (not executed directly).
]=]
Workflows.ModeTransitionWorkflow = BT.Sequence({
	-- Step 1: Clear server data
	BT.Condition(function(ctx)
		if not ctx.ServiceManager or not ctx.ServiceManager.ServerData then return true end
		
		local sm = ctx.ServiceManager
		if sm.ServerData.Scheduler then
			sm.ServerData.Scheduler.Tasks = {}
			sm.ServerData.Scheduler.History = {}
		end
		if sm.ServerData.FSM then
			sm.ServerData.FSM.StateMachines = {}
			sm.ServerData.FSM.Entities = {}
		end
		
		return true
	end),
	
	-- Step 2: Update sidebar entity
	BT.Condition(function(ctx)
		if not ctx.SidebarEntity then return true end
		ctx.SidebarEntity.Mode = ctx.TargetMode
		return true
	end),
	
	-- Step 3: Trigger sync (if applicable)
	BT.Condition(function(ctx)
		if ctx.TargetMode == "server" and ctx.ConnectionFSM then
			-- Trigger fetch
			task.defer(function()
				if ctx.ConnectionFSM.PerformFetch then
					ctx.ConnectionFSM:PerformFetch()
				end
			end)
		end
		return true
	end),
})

--[=[
	@description Input routing workflow: handles hotkey routing.
	Used for complex input handling scenarios.
]=]
Workflows.InputRoutingWorkflow = BT.Selector({
	-- F7: Toggle ServiceManager
	BT.Sequence({
		BT.Condition(function(ctx)
			return ctx.KeyCode == Enum.KeyCode.F7
		end),
		BT.Condition(function(ctx)
			if ctx.TerminalFSM then
				ctx.TerminalFSM.Context.IsTogglePressed = true
				return true
			end
			return false
		end),
	}),
	
	-- Tab click: Navigate pages
	BT.Sequence({
		BT.Condition(function(ctx)
			return ctx.IsTabClick and ctx.TabName ~= nil
		end),
		BT.Condition(function(ctx)
			if ctx.TabNavigationFSM then
				ctx.TabNavigationFSM.Context.TargetTab = ctx.TabName
				return true
			end
			return false
		end),
	}),
	
	-- Mode toggle click
	BT.Sequence({
		BT.Condition(function(ctx)
			return ctx.IsModeToggle
		end),
		BT.Condition(function(ctx)
			if ctx.ModeToggleFSM then
				local currentMode = ctx.ModeToggleFSM.Context.CurrentMode or "client"
				ctx.ModeToggleFSM.Context.TargetMode = (currentMode == "client") and "server" or "client"
				return true
			end
			return false
		end),
	}),
})

return Workflows
