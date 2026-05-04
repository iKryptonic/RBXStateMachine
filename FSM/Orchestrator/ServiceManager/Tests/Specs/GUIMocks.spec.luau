--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local TR = require(script.Parent.Parent.TestRunner)
local MockFramework = require(script.Parent.Parent.MockFramework)
local MockCharacter = require(script.Parent.Parent.Mocks.MockCharacter)

local clientFolder = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("client")
local InventoryGui = require(clientFolder:WaitForChild("InventoryGui"))
local HUDGui = require(clientFolder:WaitForChild("HUDGui"))
local StatGui = require(clientFolder:WaitForChild("StatGui"))
local _ActionBarGui = require(clientFolder:WaitForChild("ActionBarGui"))

local function collectBagItems(menuGui: ScreenGui): { string }
	local bagScroll = menuGui:WaitForChild("InventoryPanel"):WaitForChild("InventoryScroll")
	local itemIds = {}
	for _, child in ipairs(bagScroll:GetChildren()) do
		if child:IsA("TextButton") then
			table.insert(itemIds, child.Name)
		end
	end
	return itemIds
end

local function getBarText(screenGui: ScreenGui, barName: string): string
	local container = screenGui:WaitForChild("ResourceContainer")
	local bar = container:WaitForChild(barName)
	return (bar:WaitForChild("ValueLabel") :: TextLabel).Text
end

local function newGuiPlayer(userId: number, character: Model?): any
	local player = select(1, MockCharacter.newPlayer(userId, character))
	return player
end

local function destroyGuiPlayer(player: any)
	local playerGui = player and player.PlayerGui
	if playerGui and playerGui.Parent ~= nil then
		playerGui:Destroy()
	elseif playerGui then
		playerGui:Destroy()
	end
end

local function newEnvironment(): any
	local mock = MockFramework.new()
	local created = {}
	local env: any = {
		Mock = mock,
		Orchestrator = mock:GetOrchestrator(),
	}

	function env:DestroyLater(instance: Instance)
		table.insert(created, instance)
		return instance
	end

	function env:Cleanup()
		for index = #created, 1, -1 do
			local instance = created[index]
			if instance then
				pcall(function()
					instance:Destroy()
				end)
			end
		end
		mock:Reset()
	end

	return env
end

local function ensureAsset(env: any, itemId: string, asModel: boolean?): Instance
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		assets = env:DestroyLater(Instance.new("Folder"))
		assets.Name = "Assets"
		assets.Parent = ReplicatedStorage
	end

	local asset = assets:FindFirstChild(itemId)
	if asset then
		return asset
	end

	if asModel == false then
		asset = env:DestroyLater(Instance.new("Part"))
		asset.Name = itemId
		asset.Size = Vector3.new(1, 1, 1)
	else
		asset = env:DestroyLater(Instance.new("Model"))
		asset.Name = itemId
		local handle = env:DestroyLater(Instance.new("Part"))
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 1, 3)
		handle.Parent = asset
		asset.PrimaryPart = handle
	end
	asset.Parent = assets
	return asset
end

local function withEnvironment(run: (any) -> ())
	local env = newEnvironment()
	local ok, err = pcall(function()
		run(env)
	end)
	env:Cleanup()
	if not ok then
		error(err, 0)
	end
end

local function spec()
	local describe = TR.describe
	local it = TR.it
	local expect = TR.expect

	describe("InventoryGui equip UX", function()
		it("should remove item from bag and show in character slot after equip", function()
			withEnvironment(function(env)
				for _, itemId in ipairs({ "Artura", "Gale", "Kama" }) do
					ensureAsset(env, itemId)
				end
				local playerEntity = env.Mock:CreatePlayerEntity("Player_1", {
					Inventory = { "Artura", "Gale", "Kama" },
				})
				local charEntity = env.Mock:CreateCharacterEntity("Char_1", {})
				local player = newGuiPlayer(1, nil)
				local controller = InventoryGui.Create(player, env.Orchestrator, "Char_1", "Player_1")

				playerEntity.Inventory = { "Gale", "Kama" }
				charEntity.EquippedRight = "Artura"
				controller.Refresh()

				expect(controller.BuildInventoryList(playerEntity)).toEqual({ "Gale", "Kama" })
				expect(controller.ResolveEquipSlots(playerEntity, charEntity).MainHand).toEqual("Artura")
				expect(collectBagItems(controller.GetScreenGui())).toEqual({ "Gale", "Kama" })

				controller.Destroy()
				destroyGuiPlayer(player)
			end)
		end)

		it("should return item to bag after unequip", function()
			withEnvironment(function(env)
				for _, itemId in ipairs({ "Artura", "Gale" }) do
					ensureAsset(env, itemId)
				end
				local playerEntity = env.Mock:CreatePlayerEntity("Player_1", {
					Inventory = { "Gale" },
				})
				local charEntity = env.Mock:CreateCharacterEntity("Char_1", {
					EquippedRight = "Artura",
				})
				local player = newGuiPlayer(1, nil)
				local controller = InventoryGui.Create(player, env.Orchestrator, "Char_1", "Player_1")

				playerEntity.Inventory = { "Gale", "Artura" }
				charEntity.EquippedRight = ""
				controller.Refresh()

				expect(controller.BuildInventoryList(playerEntity)).toEqual({ "Gale", "Artura" })
				expect(controller.ResolveEquipSlots(playerEntity, charEntity).MainHand).toEqual("")
				expect(collectBagItems(controller.GetScreenGui())).toEqual({ "Gale", "Artura" })

				controller.Destroy()
				destroyGuiPlayer(player)
			end)
		end)

		it("should swap weapons correctly", function()
			withEnvironment(function(env)
				for _, itemId in ipairs({ "Artura", "Gale", "Kama" }) do
					ensureAsset(env, itemId)
				end
				local playerEntity = env.Mock:CreatePlayerEntity("Player_1", {
					Inventory = { "Gale", "Kama" },
				})
				local charEntity = env.Mock:CreateCharacterEntity("Char_1", {
					EquippedRight = "Artura",
				})
				local player = newGuiPlayer(1, nil)
				local controller = InventoryGui.Create(player, env.Orchestrator, "Char_1", "Player_1")

				playerEntity.Inventory = { "Kama", "Artura" }
				charEntity.EquippedRight = "Gale"
				controller.Refresh()

				expect(controller.BuildInventoryList(playerEntity)).toEqual({ "Kama", "Artura" })
				expect(controller.ResolveEquipSlots(playerEntity, charEntity).MainHand).toEqual("Gale")
				expect(collectBagItems(controller.GetScreenGui())).toEqual({ "Kama", "Artura" })

				controller.Destroy()
				destroyGuiPlayer(player)
			end)
		end)
	end)

	describe("HUDGui resource tracking", function()
		it("should display correct health stamina and mana from entity", function()
			withEnvironment(function(env)
				env.Mock:CreateCharacterEntity("Char_1", {
					Health = 75,
					MaxHealth = 100,
					Stamina = 30,
					MaxStamina = 60,
					Mana = 12,
					MaxMana = 24,
				})
				env.Mock:CreatePlayerEntity("Player_1", {
					XP = 18,
					MaxXP = 40,
					Level = 7,
				})
				local player = newGuiPlayer(1, nil)
				local cleanup = HUDGui.Create(player, env.Orchestrator, "Char_1", "Player_1")
				local screenGui = player.PlayerGui:FindFirstChild("RPGHUD") :: ScreenGui

				expect(getBarText(screenGui, "HealthBar")).toEqual("75/100")
				expect(getBarText(screenGui, "StaminaBar")).toEqual("30/60")
				expect(getBarText(screenGui, "ManaBar")).toEqual("12/24")

				cleanup()
				destroyGuiPlayer(player)
			end)
		end)

		it("should show 0/0 when entity is nil", function()
			withEnvironment(function(env)
				local player = newGuiPlayer(1, nil)
				local cleanup = HUDGui.Create(player, env.Orchestrator, "MissingChar", "MissingPlayer")
				local screenGui = player.PlayerGui:FindFirstChild("RPGHUD") :: ScreenGui

				expect(getBarText(screenGui, "HealthBar")).toEqual("0/0")
				expect(getBarText(screenGui, "StaminaBar")).toEqual("0/0")
				expect(getBarText(screenGui, "ManaBar")).toEqual("0/0")
				expect(getBarText(screenGui, "XPBar")).toEqual("0/0")

				cleanup()
				destroyGuiPlayer(player)
			end)
		end)
	end)

	describe("StatGui allocation", function()
		it("should disable plus buttons when StatPoints = 0", function()
			withEnvironment(function(env)
				env.Mock:CreatePlayerEntity("Player_1", {
					StatPoints = 0,
					Strength = 10,
					Agility = 8,
					Vitality = 6,
					Endurance = 7,
					Intelligence = 5,
					Luck = 4,
				})
				local player = newGuiPlayer(1, nil)
				local gui = StatGui.Create(player, env.Orchestrator, "Char_1", "Player_1")
				local strength = gui.GetStatWidget("Strength")
				local agility = gui.GetStatWidget("Agility")

				expect(strength).never.toBeNil()
				expect(agility).never.toBeNil()
				expect(strength.PlusButton.Active).toBeFalsy()
				expect(strength.LabelButton.Active).toBeFalsy()
				expect(agility.PlusButton.Active).toBeFalsy()

				gui.Destroy()
				destroyGuiPlayer(player)
			end)
		end)

		it("should send RequestAllocateStat on plus click", function()
			withEnvironment(function(env)
				env.Mock:CreatePlayerEntity("Player_1", {
					StatPoints = 3,
					Strength = 10,
					Agility = 10,
					Vitality = 10,
					Endurance = 10,
					Intelligence = 10,
					Luck = 10,
				})
				local player = newGuiPlayer(1, nil)
				local gui = StatGui.Create(player, env.Orchestrator, "Char_1", "Player_1")

				gui.RequestAllocate("Strength")

				local commands = env.Mock:GetCommands()
				expect(#commands).toEqual(1)
				expect(commands[1].EntityId).toEqual("Char_1")
				expect(commands[1].Command).toEqual("RequestAllocateStat")
				expect(commands[1].Args[1]).toEqual("Strength")

				gui.Destroy()
				destroyGuiPlayer(player)
			end)
		end)

		it("should update hexagon vertices on stat change", function()
			withEnvironment(function(env)
				local playerEntity = env.Mock:CreatePlayerEntity("Player_1", {
					StatPoints = 2,
					Strength = 10,
					Agility = 10,
					Vitality = 10,
					Endurance = 10,
					Intelligence = 10,
					Luck = 10,
				})
				local player = newGuiPlayer(1, nil)
				local gui = StatGui.Create(player, env.Orchestrator, "Char_1", "Player_1")
				local before = gui.GetPolygonVertices()

				playerEntity.Strength = 60
				gui.Refresh()
				local after = gui.GetPolygonVertices()

				expect(after.Strength.Y).toBeLessThan(before.Strength.Y)
				expect(after.Strength.X).toEqual(before.Strength.X)
				expect(after.Agility.X).toEqual(before.Agility.X)
				expect(after.Agility.Y).toEqual(before.Agility.Y)

				gui.Destroy()
				destroyGuiPlayer(player)
			end)
		end)
	end)
end

TR.register(spec)
return spec
