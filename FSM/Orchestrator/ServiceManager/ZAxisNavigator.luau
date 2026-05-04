--!strict


local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local ZAxisNavigator = {}
ZAxisNavigator.__index = ZAxisNavigator

export type LayerEntry = {
	Id: string,
	ParentId: string?,
	Depth: number,
	Label: string,
	Frame: Frame?,
	Builder: ((frame: Frame, context: any) -> ())?,
	Context: any?,
	IsExpanded: boolean,
	Timestamp: number,
}


function ZAxisNavigator.new(rootContainer: Frame): any
	local self = setmetatable({}, ZAxisNavigator)
	self._rootContainer = rootContainer
	self._layers = {} :: { [string]: LayerEntry }
	self._layerStack = {} :: { string } -- ordered stack of expanded layer IDs
	self._breadcrumbs = {} :: { { Id: string, Label: string, Depth: number } }
	self._maxDepth = 6
	self._animating = false
	self._breadcrumbFrame = nil :: Frame?
	self._onBreadcrumbChanged = nil :: ((crumbs: { any }) -> ())?
	return self
end


function ZAxisNavigator:RegisterRootLayer(id: string, label: string, builder: (frame: Frame, context: any) -> ())
	self._layers[id] = {
		Id = id,
		ParentId = nil,
		Depth = 0,
		Label = label,
		Frame = nil,
		Builder = builder,
		Context = nil,
		IsExpanded = false,
		Timestamp = 0,
	}
end


function ZAxisNavigator:ExpandLayer(params: {
	Id: string,
	ParentId: string,
	Label: string,
	Builder: (frame: Frame, context: any) -> (),
	Context: any?,
})
	if self._animating then return end
	if #self._layerStack >= self._maxDepth then return end

	local parentLayer = self._layers[params.ParentId]
	local parentDepth = parentLayer and parentLayer.Depth or 0
	local newDepth = parentDepth + 1

	-- Collapse layers deeper than the parent first
	self:_CollapseToDepth(parentDepth)

	local layer: LayerEntry = {
		Id = params.Id,
		ParentId = params.ParentId,
		Depth = newDepth,
		Label = params.Label,
		Frame = nil,
		Builder = params.Builder,
		Context = params.Context,
		IsExpanded = true,
		Timestamp = os.clock(),
	}
	self._layers[params.Id] = layer

	-- Create the physical sub-pane frame
	local frame = self:_CreateSubPaneFrame(layer)
	layer.Frame = frame

	-- Build content
	if layer.Builder then
		layer.Builder(frame, layer.Context)
	end

	-- Animate in
	table.insert(self._layerStack, params.Id)
	self:_AnimateExpand(frame, newDepth)
	self:_RebuildBreadcrumbs()
end


function ZAxisNavigator:CollapseToLayer(layerId: string)
	local layer = self._layers[layerId]
	if not layer then return end
	self:_CollapseToDepth(layer.Depth)
	self:_RebuildBreadcrumbs()
end


function ZAxisNavigator:NavigateToRoot(layerId: string)
	-- Collapse everything
	self:_CollapseToDepth(-1)

	local layer = self._layers[layerId]
	if not layer then return end

	-- Create frame for root layer
	local frame = self:_CreateSubPaneFrame(layer)
	layer.Frame = frame
	layer.IsExpanded = true

	if layer.Builder then
		layer.Builder(frame, layer.Context)
	end

	table.insert(self._layerStack, layerId)
	self:_AnimateExpand(frame, 0)
	self:_RebuildBreadcrumbs()
end


function ZAxisNavigator:GetCurrentDepth(): number
	if #self._layerStack == 0 then return 0 end
	local topId = self._layerStack[#self._layerStack]
	local topLayer = self._layers[topId]
	return topLayer and topLayer.Depth or 0
end


function ZAxisNavigator:GetBreadcrumbs(): { { Id: string, Label: string, Depth: number } }
	return self._breadcrumbs
end


function ZAxisNavigator:OnBreadcrumbChanged(callback: (crumbs: { any }) -> ())
	self._onBreadcrumbChanged = callback
end


function ZAxisNavigator:RebuildCurrentLayer(context: any?)
	if #self._layerStack == 0 then return end
	local topId = self._layerStack[#self._layerStack]
	local layer = self._layers[topId]
	if not layer or not layer.Frame or not layer.Builder then return end

	-- We must pass layer.Context (the canonical reference) into the builder,
	-- not a fresh merged copy. Otherwise mutations made by the builder or by
	-- click handlers attached during build (e.g. visualizer playback step)
	-- get written to a transient table that's discarded on the next rebuild,
	-- so step changes appear to "not work" after the first one.
	if not layer.Context then layer.Context = {} end
	if context then
		for k, v in pairs(context) do
			layer.Context[k] = v
		end
	end

	layer.Builder(layer.Frame, layer.Context)
end


function ZAxisNavigator:GetCurrentLayer(): LayerEntry?
	if #self._layerStack == 0 then return nil end
	local topId = self._layerStack[#self._layerStack]
	return self._layers[topId]
end


function ZAxisNavigator:Destroy()
	self:_CollapseToDepth(-1)
	table.clear(self._layers)
	table.clear(self._layerStack)
	table.clear(self._breadcrumbs)
end


function ZAxisNavigator:_CreateSubPaneFrame(layer: LayerEntry): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Layer_" .. layer.Id
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.Position = UDim2.new(0, 0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.ClipsDescendants = true
	frame.ZIndex = 10 + layer.Depth
	frame.Parent = self._rootContainer

	-- Click blocker prevents input passing to layers behind
	local blocker = Instance.new("TextButton")
	blocker.Name = "ClickBlocker"
	blocker.Size = UDim2.new(1, 0, 1, 0)
	blocker.BackgroundTransparency = 1
	blocker.Text = ""
	blocker.ZIndex = frame.ZIndex
	blocker.Parent = frame

	-- Inner content as ScrollingFrame for scrollable content
	local inner = Instance.new("ScrollingFrame")
	inner.Name = "Content"
	inner.Size = UDim2.new(1, -4, 1, -4)
	inner.Position = UDim2.new(0, 2, 0, 2)
	inner.ClipsDescendants = true
	inner.ZIndex = frame.ZIndex + 1
	inner.BorderSizePixel = 0
	inner.ScrollBarThickness = 4
	inner.ScrollBarImageColor3 = Theme.Colors.Accent
	inner.AutomaticCanvasSize = Enum.AutomaticSize.Y
	inner.CanvasSize = UDim2.new(0, 0, 0, 0)
	inner.ScrollingDirection = Enum.ScrollingDirection.Y
	inner.TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
	inner.BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
	Theme.ApplyGlass(inner, layer.Depth)
	inner.Parent = frame

	-- Depth indicator glow line on the left
	if layer.Depth > 0 then
		local glow = Instance.new("Frame")
		glow.Name = "DepthGlow"
		glow.Size = UDim2.new(0, 2, 1, -8)
		glow.Position = UDim2.new(0, 0, 0, 4)
		glow.BackgroundColor3 = Theme.Colors.Accent
		glow.BackgroundTransparency = 0.4 + layer.Depth * 0.08
		glow.BorderSizePixel = 0
		glow.ZIndex = frame.ZIndex + 2
		glow.Parent = inner
	end

	return frame
end


function ZAxisNavigator:_AnimateExpand(frame: Frame, depth: number)
	self._animating = true

	-- Start state: shifted right and transparent
	local content = frame:FindFirstChild("Content") :: Frame?
	if content then
		content.Position = UDim2.new(0.08, 0, 0, 2)
		content.BackgroundTransparency = 1
	end

	-- Stagger based on depth
	local delay = depth * 0.04
	task.delay(delay, function()
		if content then
			local tween1 = TweenService:Create(content, Theme.Tween.Expand, {
				Position = UDim2.new(0, 2, 0, 2),
			})
			local tween2 = TweenService:Create(content, Theme.Tween.Expand, {
				BackgroundTransparency = Theme.GetDepthTransparency(depth),
			})
			tween1:Play()
			tween2:Play()
			tween1.Completed:Wait()
		end
		self._animating = false
	end)
end


function ZAxisNavigator:_AnimateCollapse(frame: Frame, callback: (() -> ())?)
	local content = frame:FindFirstChild("Content") :: Frame?
	if content then
		local tween = TweenService:Create(content, Theme.Tween.Collapse, {
			Position = UDim2.new(0.06, 0, 0, 2),
			BackgroundTransparency = 1,
		})
		tween:Play()
		tween.Completed:Connect(function()
			frame:Destroy()
			if callback then callback() end
		end)
	else
		frame:Destroy()
		if callback then callback() end
	end
end


function ZAxisNavigator:_CollapseToDepth(targetDepth: number)
	-- Remove all layers above targetDepth from the stack
	while #self._layerStack > 0 do
		local topId = self._layerStack[#self._layerStack]
		local layer = self._layers[topId]
		if not layer or layer.Depth <= targetDepth then break end

		table.remove(self._layerStack)
		layer.IsExpanded = false
		if layer.Frame then
			self:_AnimateCollapse(layer.Frame)
			layer.Frame = nil
		end
		-- Clean up non-root layers from registry
		if layer.Depth > 0 then
			self._layers[topId] = nil
		end
	end
end


function ZAxisNavigator:_RebuildBreadcrumbs()
	table.clear(self._breadcrumbs)
	for _, layerId in ipairs(self._layerStack) do
		local layer = self._layers[layerId]
		if layer then
			table.insert(self._breadcrumbs, {
				Id = layer.Id,
				Label = layer.Label,
				Depth = layer.Depth,
			})
		end
	end

	if self._onBreadcrumbChanged then
		self._onBreadcrumbChanged(self._breadcrumbs)
	end
end

return ZAxisNavigator
