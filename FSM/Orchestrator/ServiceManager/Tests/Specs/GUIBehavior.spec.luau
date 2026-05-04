--!strict

local StarterPlayer = game:GetService("StarterPlayer")

local TR = require(script.Parent.Parent.TestRunner)
local MockSpecHelpers = require(script.Parent.MockSpecHelpers)

local clientFolder = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local DragDropManager = require(clientFolder:WaitForChild("DragDropManager"))
local InventoryGui = require(clientFolder:WaitForChild("InventoryGui"))

local function createSignal()
	local listeners = {}
	local signal = {}

	function signal:Connect(fn)
		local connection = { Connected = true }
		function connection:Disconnect()
			if not self.Connected then
				return
			end
			self.Connected = false
			for index, listener in ipairs(listeners) do
				if listener.Connection == connection then
					table.remove(listeners, index)
					break
				end
			end
		end
		table.insert(listeners, { Connection = connection, Callback = fn })
		return connection
	end

	function signal:Fire(...)
		for _, listener in ipairs(table.clone(listeners)) do
			if listener.Connection.Connected then
				listener.Callback(...)
			end
		end
	end

	return signal
end

local function appendChild(parent, child)
	if parent.Children == nil then
		parent.Children = {}
	end
	child.Parent = parent
	table.insert(parent.Children, child)
	return child
end

local function removeChild(parent, child)
	if parent == nil or parent.Children == nil then
		return
	end
	for index, existing in ipairs(parent.Children) do
		if existing == child then
			table.remove(parent.Children, index)
			break
		end
	end
end

local function createMockGui(name, className, position, size)
	local gui = {
		Name = name,
		ClassName = className or "GuiObject",
		AbsolutePosition = position or Vector2.new(0, 0),
		AbsoluteSize = size or Vector2.new(100, 100),
		Parent = nil,
		Children = {},
		Destroyed = false,
		InputBegan = createSignal(),
		InputChanged = createSignal(),
		InputEnded = createSignal(),
	}

	function gui:IsA(targetClassName)
		return self.ClassName == targetClassName or targetClassName == "GuiObject"
	end

	function gui:Destroy()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		removeChild(self.Parent, self)
		self.Parent = nil
		for _, child in ipairs(table.clone(self.Children)) do
			if child.Destroy then
				child:Destroy()
			end
		end
		table.clear(self.Children)
	end

	return gui
end

local function createMouseInput(userInputType, position)
	return {
		UserInputType = userInputType,
		Position = {
			X = position.X,
			Y = position.Y,
		},
	}
end

local function createDragDropHarness()
	local userInputService = {
		InputChanged = createSignal(),
		InputEnded = createSignal(),
		InputBegan = createSignal(),
	}

	local now = 0
	local state = {
		ScreenGui = nil,
		OverlayGui = nil,
		DragGhost = nil,
		Draggables = {},
		DropZones = {},
		GlobalConnections = {},
		AllConnections = {},
		IsDragging = false,
		DragPayload = nil,
		DragStartPos = nil,
		MouseDownPayload = nil,
		MouseDownSource = nil,
		CurrentHover = nil,
		LastDragEndedAt = -math.huge,
	}

	local manager = {
		SlotTypes = table.clone(DragDropManager.SlotTypes),
	}

	local function rememberConnection(connection)
		table.insert(state.AllConnections, connection)
		return connection
	end

	local function disconnectConnections(connections)
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		table.clear(connections)
	end

	local function clearPendingDragStart()
		state.DragStartPos = nil
		state.MouseDownPayload = nil
		state.MouseDownSource = nil
	end

	local function getMousePosition(input)
		if input ~= nil then
			return Vector2.new(input.Position.X, input.Position.Y)
		end
		return Vector2.new(0, 0)
	end

	local function ensureOverlayGui()
		if state.ScreenGui == nil or state.ScreenGui.Parent == nil then
			return nil
		end
		if state.OverlayGui == nil or state.OverlayGui.Destroyed then
			state.OverlayGui = createMockGui("DragDropOverlay", "ScreenGui", Vector2.new(0, 0), Vector2.new(0, 0))
			appendChild(state.ScreenGui.Parent, state.OverlayGui)
		end
		return state.OverlayGui
	end

	local function containsPoint(guiElement, mousePos)
		local topLeft = guiElement.AbsolutePosition
		local size = guiElement.AbsoluteSize
		return mousePos.X >= topLeft.X
			and mousePos.X <= topLeft.X + size.X
			and mousePos.Y >= topLeft.Y
			and mousePos.Y <= topLeft.Y + size.Y
	end

	local function canAcceptDrop(config, payload)
		if config == nil then
			return false
		end
		if type(config.CanAccept) == "function" then
			return config.CanAccept(payload)
		end
		return true
	end

	local function updateHoverTarget(mousePos)
		local nextHover = nil
		for guiElement, config in pairs(state.DropZones) do
			if not guiElement.Destroyed and containsPoint(guiElement, mousePos) and canAcceptDrop(config, state.DragPayload) then
				nextHover = guiElement
				break
			end
		end

		if nextHover ~= state.CurrentHover then
			local previous = state.CurrentHover
			state.CurrentHover = nextHover
			if previous ~= nil then
				local previousConfig = state.DropZones[previous]
				if previousConfig and type(previousConfig.OnHoverLeave) == "function" then
					previousConfig.OnHoverLeave()
				end
			end
			if nextHover ~= nil then
				local nextConfig = state.DropZones[nextHover]
				if nextConfig and type(nextConfig.OnHoverEnter) == "function" then
					nextConfig.OnHoverEnter()
				end
			end
		end
	end

	function manager.Init(screenGui)
		state.ScreenGui = screenGui
		ensureOverlayGui()
		disconnectConnections(state.GlobalConnections)
		table.insert(state.GlobalConnections, rememberConnection(userInputService.InputChanged:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseMovement then
				return
			end

			local mousePos = getMousePosition(input)
			if not state.IsDragging and state.MouseDownPayload ~= nil and state.DragStartPos ~= nil and state.MouseDownSource ~= nil then
				if (state.DragStartPos - mousePos).Magnitude >= 5 then
					manager.StartDrag(state.MouseDownPayload, mousePos)
				end
			end

			if state.IsDragging then
				updateHoverTarget(mousePos)
			end
		end)))
		table.insert(state.GlobalConnections, rememberConnection(userInputService.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end

			if state.IsDragging and state.DragPayload ~= nil then
				local hovered = state.CurrentHover and state.DropZones[state.CurrentHover] or nil
				if hovered and canAcceptDrop(hovered, state.DragPayload) then
					hovered.OnDrop(state.DragPayload)
				end
				manager.CancelDrag()
			else
				clearPendingDragStart()
			end
		end)))
		table.insert(state.GlobalConnections, rememberConnection(userInputService.InputBegan:Connect(function(input)
			if not state.IsDragging then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				manager.CancelDrag()
			end
		end)))
	end

	function manager.RegisterDraggable(guiElement, payloadFn)
		manager.UnregisterDraggable(guiElement)
		local connections = {}
		table.insert(connections, rememberConnection(guiElement.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 or state.IsDragging then
				return
			end
			local payload = payloadFn()
			if payload == nil then
				return
			end
			state.MouseDownPayload = payload
			state.MouseDownSource = guiElement
			state.DragStartPos = getMousePosition(input)
		end)))
		table.insert(connections, rememberConnection(guiElement.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 and state.MouseDownSource == guiElement and not state.IsDragging then
				clearPendingDragStart()
			end
		end)))
		state.Draggables[guiElement] = {
			PayloadFn = payloadFn,
			Connections = connections,
		}
	end

	function manager.RegisterDropZone(guiElement, config)
		state.DropZones[guiElement] = config
	end

	function manager.UnregisterDraggable(guiElement)
		local entry = state.Draggables[guiElement]
		if entry then
			disconnectConnections(entry.Connections)
			state.Draggables[guiElement] = nil
		end
		if state.MouseDownSource == guiElement then
			clearPendingDragStart()
		end
	end

	function manager.UnregisterDropZone(guiElement)
		if state.CurrentHover == guiElement then
			local config = state.DropZones[guiElement]
			if config and type(config.OnHoverLeave) == "function" then
				config.OnHoverLeave()
			end
			state.CurrentHover = nil
		end
		state.DropZones[guiElement] = nil
	end

	function manager.StartDrag(payload, mousePos)
		if state.IsDragging or payload == nil then
			return
		end
		clearPendingDragStart()
		local overlayGui = ensureOverlayGui()
		if overlayGui == nil then
			return
		end
		if state.DragGhost ~= nil then
			state.DragGhost:Destroy()
		end
		state.DragGhost = createMockGui("DragGhost", "Frame", mousePos, Vector2.new(48, 48))
		appendChild(overlayGui, state.DragGhost)
		state.DragPayload = payload
		state.IsDragging = true
		updateHoverTarget(mousePos)
	end

	function manager.CancelDrag()
		clearPendingDragStart()
		if state.CurrentHover ~= nil then
			local config = state.DropZones[state.CurrentHover]
			if config and type(config.OnHoverLeave) == "function" then
				config.OnHoverLeave()
			end
		end
		state.CurrentHover = nil
		state.IsDragging = false
		state.DragPayload = nil
		if state.DragGhost ~= nil then
			state.DragGhost:Destroy()
			state.DragGhost = nil
		end
		state.LastDragEndedAt = now
	end

	function manager.IsDragging()
		return state.IsDragging
	end

	function manager.WasDraggingRecently(windowSeconds)
		return (now - state.LastDragEndedAt) <= (windowSeconds or 0.2)
	end

	function manager.Destroy()
		local draggableKeys = {}
		for guiElement, _ in pairs(state.Draggables) do
			table.insert(draggableKeys, guiElement)
		end
		for _, guiElement in ipairs(draggableKeys) do
			manager.UnregisterDraggable(guiElement)
		end
		local dropZoneKeys = {}
		for guiElement, _ in pairs(state.DropZones) do
			table.insert(dropZoneKeys, guiElement)
		end
		for _, guiElement in ipairs(dropZoneKeys) do
			manager.UnregisterDropZone(guiElement)
		end
		disconnectConnections(state.GlobalConnections)
		manager.CancelDrag()
		if state.OverlayGui ~= nil then
			state.OverlayGui:Destroy()
			state.OverlayGui = nil
		end
		state.ScreenGui = nil
	end

	function manager._debug()
		return state
	end

	function manager._step(deltaSeconds)
		now += deltaSeconds
	end

	function manager._fireGlobal(signalName, input)
		userInputService[signalName]:Fire(input)
	end

	function manager._fireGui(signalName, guiElement, input)
		guiElement[signalName]:Fire(input)
	end

	return manager
end

local function withEnvironment(run)
	local env = MockSpecHelpers.newEnvironment()
	local ok, err = pcall(function()
		run(env)
	end)
	env:Cleanup()
	if not ok then
		error(err, 0)
	end
end

local function destroyGuiPlayer(player)
	local playerGui = player and player.PlayerGui
	if playerGui then
		pcall(function()
			playerGui:Destroy()
		end)
	end
end

local function withInventoryController(env, itemIds, playerData, charData, run)
	for _, itemId in ipairs(itemIds) do
		MockSpecHelpers.ensureAsset(env, itemId)
	end

	local playerEntity = env.Mock:CreatePlayerEntity("Player_1", playerData)
	local charEntity = env.Mock:CreateCharacterEntity("Char_1", charData)
	local player = MockSpecHelpers.makeFakePlayer(1)
	local controller = InventoryGui.Create(player, env.Orchestrator, "Char_1", "Player_1")
	local ok, err = pcall(function()
		run(playerEntity, charEntity, player, controller)
	end)
	pcall(function()
		controller.Destroy()
	end)
	destroyGuiPlayer(player)
	if not ok then
		error(err, 0)
	end
end

local function getBagScroll(screenGui)
	return screenGui:WaitForChild("InventoryPanel"):WaitForChild("InventoryScroll")
end

local function getSlotButtons(screenGui)
	local slotButtons = {}
	for _, child in ipairs(getBagScroll(screenGui):GetChildren()) do
		if child:IsA("TextButton") and string.match(child.Name, "^Slot%d+$") then
			table.insert(slotButtons, child)
		end
	end
	table.sort(slotButtons, function(left, right)
		return tonumber(string.match(left.Name, "%d+")) < tonumber(string.match(right.Name, "%d+"))
	end)
	return slotButtons
end

local function getSlotButton(screenGui, slotIndex)
	for _, button in ipairs(getSlotButtons(screenGui)) do
		if button.Name == string.format("Slot%d", slotIndex) then
			return button
		end
	end
	return nil
end

local function getContextButton(screenGui, buttonText)
	local contextMenu = screenGui:WaitForChild("ItemContextMenu")
	for _, child in ipairs(contextMenu:GetChildren()) do
		if child:IsA("TextButton") and child.Text == buttonText then
			return child
		end
	end
	return nil
end

local function fireSignal(signal, ...)
	(signal :: any):Fire(...)
end

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("DragDropManager behavior", function()
		it("Init creates an overlay gui for the owning screen", function()
			local manager = createDragDropHarness()
			local playerGui = createMockGui("PlayerGui", "PlayerGui")
			local screenGui = createMockGui("ScreenGui", "ScreenGui")
			appendChild(playerGui, screenGui)

			manager.Init(screenGui)

			local state = manager._debug()
			expect(state.OverlayGui).never.toBeNil()
			expect((state.OverlayGui :: any).Name).toEqual("DragDropOverlay")
			expect((state.OverlayGui :: any).Parent).toBe(playerGui)
		end)

		it("RegisterDraggable stores the element in the internal draggable map", function()
			local manager = createDragDropHarness()
			local button = createMockGui("ItemButton", "TextButton")

			manager.RegisterDraggable(button, function()
				return { ItemId = "Sword" }
			end)

			expect(manager._debug().Draggables[button]).never.toBeNil()
		end)

		it("RegisterDropZone stores the config in the internal drop zone map", function()
			local manager = createDragDropHarness()
			local zone = createMockGui("BagSlot", "TextButton")
			local config = {
				Type = manager.SlotTypes.BAG,
				OnDrop = function() end,
			}

			manager.RegisterDropZone(zone, config)

			expect(manager._debug().DropZones[zone]).toBe(config)
		end)

		it("StartDrag marks dragging active and creates a ghost", function()
			local manager = createDragDropHarness()
			local playerGui = createMockGui("PlayerGui", "PlayerGui")
			local screenGui = createMockGui("ScreenGui", "ScreenGui")
			appendChild(playerGui, screenGui)
			manager.Init(screenGui)

			manager.StartDrag({ ItemId = "Sword" }, Vector2.new(40, 40))

			local state = manager._debug()
			expect(manager.IsDragging()).toBeTruthy()
			expect(state.DragGhost).never.toBeNil()
			expect((state.DragGhost :: any).Parent).toBe(state.OverlayGui)
		end)

		it("CancelDrag clears dragging state and destroys the ghost", function()
			local manager = createDragDropHarness()
			local playerGui = createMockGui("PlayerGui", "PlayerGui")
			local screenGui = createMockGui("ScreenGui", "ScreenGui")
			appendChild(playerGui, screenGui)
			manager.Init(screenGui)
			manager.StartDrag({ ItemId = "Sword" }, Vector2.new(40, 40))
			local ghost = manager._debug().DragGhost

			manager.CancelDrag()

			expect(manager.IsDragging()).toBeFalsy()
			expect(manager._debug().DragGhost).toBeNil()
			expect((ghost :: any).Destroyed).toBeTruthy()
		end)

		it("Drop on a valid zone invokes OnDrop", function()
			local manager = createDragDropHarness()
			local playerGui = createMockGui("PlayerGui", "PlayerGui")
			local screenGui = createMockGui("ScreenGui", "ScreenGui")
			local zone = createMockGui("BagSlot", "TextButton", Vector2.new(50, 50), Vector2.new(80, 80))
			appendChild(playerGui, screenGui)
			manager.Init(screenGui)
			local droppedPayload = nil
			manager.RegisterDropZone(zone, {
				Type = manager.SlotTypes.BAG,
				CanAccept = function(payload)
					return payload.ItemId == "Sword"
				end,
				OnDrop = function(payload)
					droppedPayload = payload
				end,
			})

			manager.StartDrag({ ItemId = "Sword" }, Vector2.new(0, 0))
			manager._fireGlobal("InputChanged", createMouseInput(Enum.UserInputType.MouseMovement, Vector2.new(70, 70)))
			manager._fireGlobal("InputEnded", createMouseInput(Enum.UserInputType.MouseButton1, Vector2.new(70, 70)))

			expect(droppedPayload).never.toBeNil()
			expect((droppedPayload :: any).ItemId).toEqual("Sword")
		end)

		it("Drop on an invalid zone does not invoke OnDrop", function()
			local manager = createDragDropHarness()
			local playerGui = createMockGui("PlayerGui", "PlayerGui")
			local screenGui = createMockGui("ScreenGui", "ScreenGui")
			local zone = createMockGui("BagSlot", "TextButton", Vector2.new(50, 50), Vector2.new(80, 80))
			appendChild(playerGui, screenGui)
			manager.Init(screenGui)
			local dropCount = 0
			manager.RegisterDropZone(zone, {
				Type = manager.SlotTypes.BAG,
				CanAccept = function()
					return false
				end,
				OnDrop = function()
					dropCount += 1
				end,
			})

			manager.StartDrag({ ItemId = "Sword" }, Vector2.new(0, 0))
			manager._fireGlobal("InputChanged", createMouseInput(Enum.UserInputType.MouseMovement, Vector2.new(70, 70)))
			manager._fireGlobal("InputEnded", createMouseInput(Enum.UserInputType.MouseButton1, Vector2.new(70, 70)))

			expect(dropCount).toEqual(0)
		end)

		it("UnregisterDraggable removes the element from the map", function()
			local manager = createDragDropHarness()
			local button = createMockGui("ItemButton", "TextButton")
			manager.RegisterDraggable(button, function()
				return { ItemId = "Sword" }
			end)

			manager.UnregisterDraggable(button)

			expect(manager._debug().Draggables[button]).toBeNil()
		end)

		it("UnregisterDropZone removes the zone from the map", function()
			local manager = createDragDropHarness()
			local zone = createMockGui("BagSlot", "TextButton")
			manager.RegisterDropZone(zone, {
				Type = manager.SlotTypes.BAG,
				OnDrop = function() end,
			})

			manager.UnregisterDropZone(zone)

			expect(manager._debug().DropZones[zone]).toBeNil()
		end)

		it("Destroy disconnects connections and destroys the overlay", function()
			local manager = createDragDropHarness()
			local playerGui = createMockGui("PlayerGui", "PlayerGui")
			local screenGui = createMockGui("ScreenGui", "ScreenGui")
			local button = createMockGui("ItemButton", "TextButton")
			local zone = createMockGui("BagSlot", "TextButton")
			appendChild(playerGui, screenGui)
			manager.Init(screenGui)
			manager.RegisterDraggable(button, function()
				return { ItemId = "Sword" }
			end)
			manager.RegisterDropZone(zone, {
				Type = manager.SlotTypes.BAG,
				OnDrop = function() end,
			})
			manager.StartDrag({ ItemId = "Sword" }, Vector2.new(10, 10))
			local overlay = manager._debug().OverlayGui
			local allConnections = table.clone(manager._debug().AllConnections)

			manager.Destroy()

			expect(manager._debug().OverlayGui).toBeNil()
			expect(manager._debug().Draggables[button]).toBeNil()
			expect(manager._debug().DropZones[zone]).toBeNil()
			expect((overlay :: any).Destroyed).toBeTruthy()
			for _, connection in ipairs(allConnections) do
				expect(connection.Connected).toBeFalsy()
			end
		end)

		it("Click suppression stays active for the suppression window after drag end", function()
			local manager = createDragDropHarness()
			local playerGui = createMockGui("PlayerGui", "PlayerGui")
			local screenGui = createMockGui("ScreenGui", "ScreenGui")
			appendChild(playerGui, screenGui)
			manager.Init(screenGui)
			manager.StartDrag({ ItemId = "Sword" }, Vector2.new(10, 10))

			manager.CancelDrag()
			expect(manager.WasDraggingRecently()).toBeTruthy()
			manager._step(0.21)
			expect(manager.WasDraggingRecently()).toBeFalsy()
		end)

		it("Drag threshold prevents drag start when movement is below five pixels", function()
			local manager = createDragDropHarness()
			local playerGui = createMockGui("PlayerGui", "PlayerGui")
			local screenGui = createMockGui("ScreenGui", "ScreenGui")
			local button = createMockGui("ItemButton", "TextButton")
			appendChild(playerGui, screenGui)
			manager.Init(screenGui)
			manager.RegisterDraggable(button, function()
				return { ItemId = "Sword" }
			end)

			manager._fireGui("InputBegan", button, createMouseInput(Enum.UserInputType.MouseButton1, Vector2.new(10, 10)))
			manager._fireGlobal("InputChanged", createMouseInput(Enum.UserInputType.MouseMovement, Vector2.new(14.9, 10)))

			expect(manager.IsDragging()).toBeFalsy()
			expect(manager._debug().DragGhost).toBeNil()
		end)
	end)

	describe("InventoryGui behavior", function()
		it("Slot stability keeps 24 shadow slots regardless of item count", function()
			withEnvironment(function(env)
				withInventoryController(env, { "Artura", "Gale" }, {
					Inventory = { "Artura", "Gale" },
				}, {}, function(playerEntity, _charEntity, _player, controller)
					controller.ToggleBag()
					local screenGui = controller.GetScreenGui()
					expect(#getSlotButtons(screenGui)).toEqual(24)

					playerEntity.Inventory = {}
					controller.Refresh()
					expect(#getSlotButtons(screenGui)).toEqual(24)
				end)
			end)
		end)

		it("Sort button sorts bag items alphabetically", function()
			withEnvironment(function(env)
				withInventoryController(env, { "Zulu", "Alpha", "Beta" }, {
					Inventory = { "Zulu", "Alpha", "Beta" },
				}, {}, function(playerEntity, _charEntity, _player, controller)
					controller.ToggleBag()
					controller.Refresh()
					local screenGui = controller.GetScreenGui()
					local sortButton = screenGui:WaitForChild("InventoryPanel"):WaitForChild("SortButton")

					fireSignal((sortButton :: any).Activated)

					local sorted = controller.BuildInventoryList(playerEntity)
					expect(sorted[1]).toEqual("Alpha")
					expect(sorted[2]).toEqual("Beta")
					expect(sorted[3]).toEqual("Zulu")
				end)
			end)
		end)

		it("Clicking a bag item fires an equip command", function()
			withEnvironment(function(env)
				withInventoryController(env, { "Artura", "Gale" }, {
					Inventory = { "Artura", "Gale" },
				}, {}, function(_playerEntity, _charEntity, _player, controller)
					controller.ToggleBag()
					controller.Refresh()
					local screenGui = controller.GetScreenGui()
					local slotButton = getSlotButton(screenGui, 1)
					expect(slotButton).never.toBeNil()

					fireSignal(((slotButton :: any).MouseButton1Click :: any))

					local commands = env.Mock:GetCommands()
					expect(#commands).toEqual(1)
					expect(commands[1].EntityId).toEqual("Char_1")
					expect(commands[1].Command).toEqual("RequestEquip")
					expect(commands[1].Args[1]).toEqual("Artura")
					expect(commands[1].Args[2]).toEqual("Right")
				end)
			end)
		end)

		it("Right-clicking an equipped slot can move the item back to the bag", function()
			withEnvironment(function(env)
				withInventoryController(env, { "Artura", "Gale" }, {
					Inventory = { "Gale" },
				}, {
					EquippedRight = "Artura",
				}, function(playerEntity, charEntity, _player, controller)
					controller.ToggleCharacter()
					controller.Refresh()
					local screenGui = controller.GetScreenGui()
					local mainHandButton = screenGui:WaitForChild("CharacterPanel"):WaitForChild("MainHand")

					fireSignal((mainHandButton :: any).InputBegan, {
						UserInputType = Enum.UserInputType.MouseButton2,
					})

					local moveToBag = getContextButton(screenGui, "Move to Bag")
					expect(moveToBag).never.toBeNil()
					fireSignal(((moveToBag :: any).MouseButton1Click :: any))

					local commands = env.Mock:GetCommands()
					expect(commands[#commands].Command).toEqual("RequestUnEquip")
					expect(commands[#commands].Args[1]).toEqual("Right")

					playerEntity.Inventory = { "Gale", "Artura" }
					charEntity.EquippedRight = ""
					controller.Refresh()
					expect(controller.BuildInventoryList(playerEntity)).toContain("Artura")
				end)
			end)
		end)

		it("Equipping from the bag does not auto-sort the remaining slots", function()
			withEnvironment(function(env)
				withInventoryController(env, { "Zulu", "Alpha", "Beta" }, {
					Inventory = { "Zulu", "Alpha", "Beta" },
				}, {}, function(playerEntity, charEntity, _player, controller)
					controller.ToggleBag()
					controller.Refresh()
					local screenGui = controller.GetScreenGui()
					local alphaSlot = getSlotButton(screenGui, 2)
					expect(alphaSlot).never.toBeNil()

					fireSignal(((alphaSlot :: any).MouseButton1Click :: any))

					local commands = env.Mock:GetCommands()
					expect(commands[#commands].Args[1]).toEqual("Alpha")

					playerEntity.Inventory = { "Zulu", "Beta" }
					charEntity.EquippedRight = "Alpha"
					controller.Refresh()

					local slots = controller.BuildInventoryList(playerEntity)
					expect(slots[1]).toEqual("Zulu")
					expect(slots[2]).toBeNil()
					expect(slots[3]).toEqual("Beta")
				end)
			end)
		end)
	end)
end

TR.register(spec)
return spec
