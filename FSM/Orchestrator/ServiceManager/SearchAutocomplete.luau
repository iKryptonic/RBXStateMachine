--!strict
-- @Name ServiceManager/SearchAutocomplete.luau
-- @Author iKrypto
-- @Description Reusable autocomplete dropdown for search TextBox inputs.
-- Supports Up/Down arrow navigation, Enter/Right arrow selection, and mouse click.
-- Attach to any TextBox with a suggestion provider function.

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)

local SearchAutocomplete = {}
SearchAutocomplete.__index = SearchAutocomplete

export type SuggestionProvider = (text: string) -> { string }
export type OnSelectCallback = (selected: string) -> ()

local MAX_VISIBLE = 6
local ROW_HEIGHT = 24

--[[
	Create a new autocomplete controller attached to a TextBox.

	@param config {
		TextBox: TextBox — the search input to attach to
		ParentFrame: Frame — the frame to parent the dropdown into (usually contentFrame)
		GetSuggestions: (text: string) -> { string } — returns filtered matches
		OnSelect: (selected: string) -> () — called when a suggestion is chosen
		AnchorPosition: UDim2? — optional override for dropdown position
		DropDirection: "up" | "down"? — default "down"
	}
]]
function SearchAutocomplete.new(config: {
	TextBox: TextBox,
	ParentFrame: GuiObject,
	GetSuggestions: SuggestionProvider,
	OnSelect: OnSelectCallback,
	AnchorPosition: UDim2?,
	DropDirection: string?,
}): any
	local self = setmetatable({}, SearchAutocomplete)

	self._textBox = config.TextBox
	self._parentFrame = config.ParentFrame
	self._getSuggestions = config.GetSuggestions
	self._onSelect = config.OnSelect
	self._dropDirection = config.DropDirection or "down"

	self._selectedIndex = 0
	self._currentSuggestions = {} :: { string }
	self._suggestionButtons = {} :: { TextButton }
	self._connections = {} :: { RBXScriptConnection }
	self._visible = false

	-- Create the dropdown frame
	local dropdown = Instance.new("Frame")
	dropdown.Name = "SearchAutocomplete"
	dropdown.Size = UDim2.new(1, -8, 0, 0)
	dropdown.BackgroundColor3 = Theme.Colors.GlassOverlay
	dropdown.BackgroundTransparency = 0.05
	dropdown.BorderSizePixel = 0
	dropdown.Visible = false
	dropdown.ZIndex = 30
	dropdown.AutomaticSize = Enum.AutomaticSize.Y
	dropdown.ClipsDescendants = true
	dropdown.Parent = config.ParentFrame

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.Sm)
	corner.Parent = dropdown

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Colors.BorderSubtle
	stroke.Thickness = 1
	stroke.Transparency = 0.5
	stroke.Parent = dropdown

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 1)
	layout.Parent = dropdown

	self._dropdown = dropdown

	-- Position the dropdown relative to the TextBox
	self:_PositionDropdown(config.AnchorPosition)

	-- Wire events
	self:_Connect()

	return self
end

function SearchAutocomplete:_PositionDropdown(anchorOverride: UDim2?)
	if anchorOverride then
		self._dropdown.Position = anchorOverride
		return
	end

	-- Auto-position below or above the search box
	local tb = self._textBox
	local searchFrame = tb.Parent

	if searchFrame and searchFrame:IsA("GuiObject") then
		if self._dropDirection == "up" then
			-- Position above
			self._dropdown.Position = UDim2.new(
				searchFrame.Position.X.Scale, searchFrame.Position.X.Offset,
				searchFrame.Position.Y.Scale, searchFrame.Position.Y.Offset
			)
		else
			-- Position below
			self._dropdown.Position = UDim2.new(
				searchFrame.Position.X.Scale, searchFrame.Position.X.Offset,
				searchFrame.Position.Y.Scale, searchFrame.Position.Y.Offset + searchFrame.Size.Y.Offset + 2
			)
		end
		self._dropdown.Size = UDim2.new(
			searchFrame.Size.X.Scale, searchFrame.Size.X.Offset,
			0, 0
		)
	end
end

function SearchAutocomplete:_Connect()
	-- Text change → update suggestions
	table.insert(self._connections, self._textBox:GetPropertyChangedSignal("Text"):Connect(function()
		self:_UpdateSuggestions()
	end))

	-- Focus lost → hide (deferred to allow click to register)
	table.insert(self._connections, self._textBox.FocusLost:Connect(function()
		task.delay(0.15, function()
			self:_Hide()
		end)
	end))

	-- Focus gained → show if text present
	table.insert(self._connections, self._textBox.Focused:Connect(function()
		self:_UpdateSuggestions()
	end))

	-- Keyboard navigation
	table.insert(self._connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not self._textBox:IsFocused() then return end
		if not self._visible then return end

		if input.KeyCode == Enum.KeyCode.Down then
			self:_Navigate(1)
		elseif input.KeyCode == Enum.KeyCode.Up then
			self:_Navigate(-1)
		elseif input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.Right then
			if self._selectedIndex > 0 and self._selectedIndex <= #self._currentSuggestions then
				self:_SelectCurrent()
			end
		elseif input.KeyCode == Enum.KeyCode.Escape then
			self:_Hide()
		end
	end))
end

function SearchAutocomplete:_Navigate(direction: number)
	local count = #self._currentSuggestions
	if count == 0 then return end

	local oldIndex = self._selectedIndex
	local newIndex = self._selectedIndex + direction

	if newIndex < 1 then
		newIndex = count
	elseif newIndex > count then
		newIndex = 1
	end

	self._selectedIndex = newIndex
	self:_HighlightRow(oldIndex, false)
	self:_HighlightRow(newIndex, true)
end

function SearchAutocomplete:_HighlightRow(index: number, highlighted: boolean)
	local btn = self._suggestionButtons[index]
	if not btn then return end

	if highlighted then
		btn.BackgroundTransparency = 0.15
		btn.TextColor3 = Theme.Colors.Accent
	else
		btn.BackgroundTransparency = 0.5
		btn.TextColor3 = Theme.Colors.TextSecondary
	end
end

function SearchAutocomplete:_SelectCurrent()
	local suggestion = self._currentSuggestions[self._selectedIndex]
	if not suggestion then return end

	self._textBox.Text = suggestion
	self._textBox.CursorPosition = #suggestion + 1
	self:_Hide()

	if self._onSelect then
		self._onSelect(suggestion)
	end
end

function SearchAutocomplete:_UpdateSuggestions()
	local text = self._textBox.Text
	if text == "" then
		self:_Hide()
		return
	end

	local suggestions = self._getSuggestions(text)

	-- Don't show if no suggestions or only exact match
	if #suggestions == 0 or (#suggestions == 1 and suggestions[1] == text) then
		self:_Hide()
		return
	end

	self._currentSuggestions = suggestions
	self._selectedIndex = 0
	self:_RenderDropdown()
	self:_Show()
end

function SearchAutocomplete:_RenderDropdown()
	-- Clear old buttons
	for _, btn in ipairs(self._suggestionButtons) do
		btn:Destroy()
	end
	table.clear(self._suggestionButtons)

	local count = math.min(#self._currentSuggestions, MAX_VISIBLE)

	if self._dropDirection == "up" then
		-- Re-position to account for height
		local height = count * ROW_HEIGHT
		local tb = self._textBox
		local searchFrame = tb.Parent
		if searchFrame and searchFrame:IsA("GuiObject") then
			self._dropdown.Position = UDim2.new(
				searchFrame.Position.X.Scale, searchFrame.Position.X.Offset,
				searchFrame.Position.Y.Scale, searchFrame.Position.Y.Offset - height - 2
			)
		end
	end

	for i = 1, count do
		local suggestion = self._currentSuggestions[i]

		local btn = Instance.new("TextButton")
		btn.Name = "Suggestion_" .. i
		btn.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		btn.BackgroundColor3 = Theme.Colors.GlassTertiary
		btn.BackgroundTransparency = 0.5
		btn.Text = "  " .. suggestion
		btn.TextColor3 = Theme.Colors.TextSecondary
		btn.TextSize = Theme.TextSize.Caption
		btn.FontFace = Theme.Font.Mono
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.AutoButtonColor = false
		btn.BorderSizePixel = 0
		btn.LayoutOrder = i
		btn.ZIndex = 31
		btn.Parent = self._dropdown

		local capturedIndex = i
		local capturedSuggestion = suggestion

		btn.MouseButton1Click:Connect(function()
			self._textBox.Text = capturedSuggestion
			self._textBox.CursorPosition = #capturedSuggestion + 1
			self:_Hide()
			if self._onSelect then
				self._onSelect(capturedSuggestion)
			end
		end)

		btn.MouseEnter:Connect(function()
			-- Unhighlight old
			self:_HighlightRow(self._selectedIndex, false)
			self._selectedIndex = capturedIndex
			self:_HighlightRow(capturedIndex, true)
		end)

		btn.MouseLeave:Connect(function()
			self:_HighlightRow(capturedIndex, false)
		end)

		self._suggestionButtons[i] = btn
	end
end

function SearchAutocomplete:_Show()
	self._dropdown.Visible = true
	self._visible = true
end

function SearchAutocomplete:_Hide()
	self._dropdown.Visible = false
	self._visible = false
	self._selectedIndex = 0
end

--[[
	Disconnect textbox/dropdown listeners and destroy the autocomplete popup.
]]
function SearchAutocomplete:Destroy()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)

	for _, btn in ipairs(self._suggestionButtons) do
		btn:Destroy()
	end
	table.clear(self._suggestionButtons)

	if self._dropdown then
		self._dropdown:Destroy()
	end

	self._textBox = nil :: any
	self._parentFrame = nil :: any
end

return SearchAutocomplete
