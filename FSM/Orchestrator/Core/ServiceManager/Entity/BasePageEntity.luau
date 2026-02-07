--!strict
-- @Name BasePageEntity
-- @Author iKrypto
-- @Description Base entity pattern for ServiceManager pages.
-- Provides an Extend() factory that merges base schema with page-specific schema.
-- Returns plain definition tables that Factory.CompileFolder can compile into
-- proper BaseEntity subclasses via BaseEntity.Extend.

local BasePageEntity = {}

-- Schema fields shared by every page entity.
BasePageEntity.BaseSchema = {
	-- Data State (affects content/filtering)
	Search         = { Type = "string",  Persist = false },
	Page           = { Type = "number",  Persist = false },
	PageSize       = { Type = "number",  Persist = false },
	SelectedItem   = { Type = "string",  Persist = false },

	-- Visual State (affects GUI appearance)
	IsVisible      = { Type = "boolean", Persist = false },
	ScrollPosition = { Type = "number",  Persist = false },
	ToolbarInitialized = { Type = "boolean", Persist = false },
}

--[[
	@description Creates a page-entity class definition by merging the base schema
	with the subclass schema and copying base methods as defaults.
	The returned table is a raw definition that Factory.CompileFolder will compile
	into a real BaseEntity subclass.
	@param extensionDef { Name: string, Schema: { [string]: any }? }
	@return any -- Plain definition table consumed by Factory
]]
function BasePageEntity.Extend(extensionDef: { Name: string, Schema: { [string]: any }? })
	-- 1. Merge schemas
	local mergedSchema = {}
	for k, v in pairs(BasePageEntity.BaseSchema) do
		mergedSchema[k] = v
	end
	if extensionDef.Schema then
		for k, v in pairs(extensionDef.Schema) do
			mergedSchema[k] = v
		end
	end

	-- 2. Build the class definition table
	local PageEntity: any = {
		Definition = {
			Name   = extensionDef.Name,
			Schema = mergedSchema,
		},
	}

	-- 3. Copy base methods as defaults (subclasses can override after Extend)
	for k, v in pairs(BasePageEntity) do
		if type(v) == "function" and k ~= "Extend" then
			PageEntity[k] = v
		end
	end

	return PageEntity
end

--------------------------------------------------------------------------------
-- BASE METHODS (mixed into every page entity via Extend)
--------------------------------------------------------------------------------

--[[
	@description Extracts context from initialization parameters.
]]
function BasePageEntity:GetContext(params: any)
	local ctx = params.Context or {}
	return {
		ViewContainer  = ctx.ViewContainer,
		Container      = ctx.Container,
		TabButton      = ctx.TabButton,
		ServiceManager = ctx.ServiceManager,
		PageController = ctx.PageController, -- Bridged legacy page object
		COLORS         = ctx.COLORS,
		Toolbar        = nil,
		Viewport       = nil,
	}
end

--[[
	@description Initializes the entity with default state.
]]
function BasePageEntity:Initialize()
	self.Search            = ""
	self.Page              = 1
	self.PageSize          = 10
	self.SelectedItem      = nil
	self.IsVisible         = false
	self.ScrollPosition    = 0
	self.ToolbarInitialized = false

	if self.ViewContainer then
		self.Toolbar  = self.ViewContainer:FindFirstChild("Toolbar")
		self.Viewport = self.Container
	end

	self:Log({ Level = "INFO", Message = string.format("%s initialized", self.Name or "BasePageEntity") })
end

--[[
	@description Applies entity state changes to the GUI.
	Subclasses should override and call BasePageEntity.ApplyChanges(self, changes) first.
]]
function BasePageEntity:ApplyChanges(changes: { [string]: any })
	if changes.IsVisible ~= nil and self.ViewContainer then
		self.ViewContainer.Visible = self.IsVisible
	end

	if changes.ScrollPosition ~= nil and self.Container then
		local ok, _ = pcall(function()
			if self.Container:IsA("ScrollingFrame") then
				(self.Container :: ScrollingFrame).CanvasPosition = Vector2.new(0, self.ScrollPosition)
			end
		end)
		if not ok then end -- silently ignore
	end
end

-- Convenience mutators-----------------------------------------------------

--[[
	@description Sets the page entity to visible.
]]
function BasePageEntity:Show()
	self.IsVisible = true
end

--[[
	@description Sets the page entity to hidden.
]]
function BasePageEntity:Hide()
	self.IsVisible = false
end

--[[
	@description Resets the search text to an empty string.
]]
function BasePageEntity:ClearSearch()
	self.Search = ""
end

--[[
	@description Sets the search filter text and resets pagination to page 1.
	@param text string -- The search query string.
]]
function BasePageEntity:SetSearch(text: string)
	self.Search = text
	self.Page   = 1
end

--[[
	@description Advances to the next page, clamped by an optional maximum.
	@param maxPage number? -- The maximum allowed page number.
]]
function BasePageEntity:NextPage(maxPage: number?)
	if maxPage and self.Page >= maxPage then return end
	self.Page = self.Page + 1
end

--[[
	@description Goes to the previous page, clamped to a minimum of 1.
]]
function BasePageEntity:PrevPage()
	if self.Page <= 1 then return end
	self.Page = self.Page - 1
end

--[[
	@description Sets the current page to a specific number (minimum 1).
	@param page number -- The target page number.
]]
function BasePageEntity:SetPage(page: number)
	self.Page = math.max(1, page)
end

--[[
	@description Resets pagination back to page 1.
]]
function BasePageEntity:ResetPagination()
	self.Page = 1
end

--[[
	@description Sets the currently selected item by its ID.
	@param itemId string? -- The item identifier, or nil to clear.
]]
function BasePageEntity:SetSelectedItem(itemId: string?)
	self.SelectedItem = itemId
end

--[[
	@description Clears the current item selection.
]]
function BasePageEntity:ClearSelection()
	self.SelectedItem = nil
end

--[[
	@description Releases all cached GUI references and logs cleanup completion.
]]
function BasePageEntity:Cleanup()
	self.Toolbar       = nil
	self.Viewport      = nil
	self.ViewContainer = nil
	self.Container     = nil
	self.TabButton     = nil
	self:Log({ Level = "INFO", Message = string.format("%s cleanup complete", self.Name or "BasePageEntity") })
end

return BasePageEntity
