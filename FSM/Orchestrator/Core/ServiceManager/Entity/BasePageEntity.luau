--!strict
-- @Name BasePageEntity
-- @Author iKrypto (AI Assistant)
-- @Description Base entity pattern for ServiceManager pages with entity-driven GUI.
-- Extends BaseEntity to provide common data and visual state schema for all pages.

local BasePageEntity = {
	Definition = {
		Name = "BasePageEntity",
		Schema = {
			-- Data State (affects content/filtering)
			Search = { Type = "string", Persist = false },
			Page = { Type = "number", Persist = false },
			PageSize = { Type = "number", Persist = false },
			SelectedItem = { Type = "string", Persist = false },
			
			-- Visual State (affects GUI appearance)
			IsVisible = { Type = "boolean", Persist = false },
			ScrollPosition = { Type = "number", Persist = false },
			ToolbarInitialized = { Type = "boolean", Persist = false },
		}
	}
}

--[[
	@description Extracts context from initialization parameters.
	@param params { Context: { ViewContainer: Frame, Container: ScrollingFrame, TabButton: TextButton?, ServiceManager: any } }
	@return { [string]: any }
]]
function BasePageEntity:GetContext(params: any)
	return {
		-- GUI References (cached in context, not schema)
		ViewContainer = params.Context and params.Context.ViewContainer,
		Container = params.Context and params.Context.Container,
		TabButton = params.Context and params.Context.TabButton,
		ServiceManager = params.Context and params.Context.ServiceManager,
		
		-- Cached GUI elements (populated in Initialize)
		Toolbar = nil,
		Viewport = nil,
	}
end

--[[
	@description Initializes the entity with default state.
	@return ()
]]
function BasePageEntity:Initialize()
	-- Initialize data state
	self.Search = ""
	self.Page = 1
	self.PageSize = 10
	self.SelectedItem = nil
	
	-- Initialize visual state
	self.IsVisible = false
	self.ScrollPosition = 0
	self.ToolbarInitialized = false
	
	-- Cache common GUI elements
	if self.ViewContainer then
		self.Toolbar = self.ViewContainer:FindFirstChild("Toolbar")
		self.Viewport = self.Container -- Container is typically the ScrollingFrame
	end
	
	self:Log({ Level = "INFO", Message = "BasePageEntity initialized" })
end

--[[
	@description Applies entity state changes to the GUI.
	Subclasses should override and call this base implementation.
	@param changes { [string]: any }
	@return ()
]]
function BasePageEntity:ApplyChanges(changes: { [string]: any })
	-- Handle visibility changes
	if changes.IsVisible ~= nil then
		if self.ViewContainer then
			self.ViewContainer.Visible = self.IsVisible
		end
	end
	
	-- Handle scroll position changes
	if changes.ScrollPosition ~= nil then
		if self.Container and self.Container:IsA("ScrollingFrame") then
			local container = self.Container :: ScrollingFrame
			container.CanvasPosition = Vector2.new(0, self.ScrollPosition)
		end
	end
	
	-- Subclasses should handle specific visual updates
	self:Log({ 
		Level = "DEBUG", 
		Message = string.format("BasePageEntity ApplyChanges: %d properties changed", 
			(function()
				local count = 0
				for _ in pairs(changes) do count += 1 end
				return count
			end)()
		)
	})
end

--[[
	@description Shows the page (sets IsVisible = true).
	@return ()
]]
function BasePageEntity:Show()
	self.IsVisible = true
end

--[[
	@description Hides the page (sets IsVisible = false).
	@return ()
]]
function BasePageEntity:Hide()
	self.IsVisible = false
end

--[[
	@description Resets search filter to empty string.
	@return ()
]]
function BasePageEntity:ClearSearch()
	self.Search = ""
end

--[[
	@description Sets the search filter.
	@param text string
	@return ()
]]
function BasePageEntity:SetSearch(text: string)
	self.Search = text
	self.Page = 1 -- Reset to first page when searching
end

--[[
	@description Advances to the next page.
	@param maxPage number? -- Optional max page constraint
	@return ()
]]
function BasePageEntity:NextPage(maxPage: number?)
	if maxPage and self.Page >= maxPage then
		return
	end
	self.Page = self.Page + 1
end

--[[
	@description Goes back to the previous page.
	@return ()
]]
function BasePageEntity:PrevPage()
	if self.Page <= 1 then
		return
	end
	self.Page = self.Page - 1
end

--[[
	@description Sets the current page number.
	@param page number
	@return ()
]]
function BasePageEntity:SetPage(page: number)
	self.Page = math.max(1, page)
end

--[[
	@description Resets pagination to page 1.
	@return ()
]]
function BasePageEntity:ResetPagination()
	self.Page = 1
end

--[[
	@description Sets the selected item.
	@param itemId string?
	@return ()
]]
function BasePageEntity:SetSelectedItem(itemId: string?)
	self.SelectedItem = itemId
end

--[[
	@description Clears the selected item.
	@return ()
]]
function BasePageEntity:ClearSelection()
	self.SelectedItem = nil
end

--[[
	@description Cleanup handler for entity destruction.
	@return ()
]]
function BasePageEntity:Cleanup()
	-- Clear cached GUI references
	self.Toolbar = nil
	self.Viewport = nil
	self.ViewContainer = nil
	self.Container = nil
	self.TabButton = nil
	
	self:Log({ Level = "INFO", Message = "BasePageEntity cleanup complete" })
end

return BasePageEntity
