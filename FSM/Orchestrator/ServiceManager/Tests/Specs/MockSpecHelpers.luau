--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MockFramework = require(script.Parent.Parent.MockFramework)

local MockSpecHelpers = {}

local sharedTable = shared :: any
local stateMachinesFolder = script.Parent.Parent.Parent.Parent.Parent.StateMachines

local function assertModule(name: string): ModuleScript
	local moduleScript = stateMachinesFolder:FindFirstChild(name)
	assert(moduleScript and moduleScript:IsA("ModuleScript"), string.format("State machine %s not found", name))
	return moduleScript
end

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

local function makeIntentSchema(recordedIntents)
	return {
		AppendIntent = function(charEntity: any, intent: any, _lockId: any?)
			local intents = charEntity:GetContext("_RecordedIntents")
			if typeof(intents) ~= "table" then
				intents = {}
			end
			table.insert(intents, intent)
			charEntity:SetContext("_RecordedIntents", intents)
			table.insert(recordedIntents, { EntityId = charEntity.EntityId, Intent = intent })
		end,
	}
end

local function makeEquipHelpers(itemCatalog: { [string]: any }, options: any?)
	local handWelds = {}
	local config = options or {}

	return {
		CloneItem = function(itemId: string)
			local entry = itemCatalog[itemId]
			if not entry then
				return nil, nil
			end
			local template = entry.Template
			if not template then
				return nil, nil
			end
			local clone = template:Clone()
			clone.Name = itemId
			return clone, if entry.Data then table.clone(entry.Data) else nil
		end,
		GetItemData = function(item: Instance)
			local entry = itemCatalog[item.Name]
			return if entry and entry.Data then table.clone(entry.Data) else nil
		end,
		GetHandPart = function(character: Model, hand: string)
			return character:FindFirstChild(hand .. "Hand") or character:FindFirstChild("HumanoidRootPart")
		end,
		FindHandleWeld = function(handPart: Instance)
			return handWelds[handPart]
		end,
		CreateWeld = function(handPart: Instance, handle: BasePart, grip: CFrame)
			local weld = {
				Part0 = handPart,
				Part1 = handle,
				C1 = grip,
				Destroyed = false,
			}
			function weld:Destroy()
				self.Destroyed = true
				handWelds[handPart] = nil
			end
			handWelds[handPart] = weld
			return weld
		end,
		MountItem = function(item: Instance, handPart: Instance)
			item.Parent = handPart.Parent
		end,
		ClearStowedDuplicate = function(character: Model, itemId: string)
			for _, child in ipairs(character:GetChildren()) do
				if child.Name == itemId and child:GetAttribute("Stowed") == true then
					child:Destroy()
				end
			end
		end,
		DropItem = function(item: Instance, weld: any)
			if weld and weld.Destroy then
				weld:Destroy()
			end
			if config.DropDestroysItem then
				item:Destroy()
			else
				item.Parent = workspace
				item:SetAttribute("Dropped", true)
			end
		end,
		StowItem = function(item: Instance, character: Model, weld: any, _itemData: any)
			if weld and weld.Destroy then
				weld:Destroy()
			end
			item.Parent = character
			item:SetAttribute("Stowed", true)
		end,
		ResolveDataModule = function(_item: Instance)
			return nil
		end,
	}
end

function MockSpecHelpers.getStateMachine(name: string): ModuleScript
	return assertModule(name)
end

function MockSpecHelpers.newEnvironment(): any
	local mock = MockFramework.new()
	local orchestrator = mock:GetOrchestrator()
	local created = {}
	local previousShared = {
		fsm = sharedTable.fsm,
		StateMachine = sharedTable.StateMachine,
		FSM = sharedTable.FSM,
	}

	sharedTable.fsm = orchestrator
	sharedTable.StateMachine = orchestrator
	sharedTable.FSM = orchestrator

	local env: any = {
		Mock = mock,
		Orchestrator = orchestrator,
		Created = created,
	}

	function env:DestroyLater(instance: Instance)
		table.insert(created, instance)
		return instance
	end

	function env:RegisterModule(name: string, moduleValue: any)
		return orchestrator.RegisterModule(name, moduleValue)
	end

	function env:Cleanup()
		for index = #created, 1, -1 do
			local instance = created[index]
			if instance and instance.Parent then
				instance:Destroy()
			end
		end
		mock:Reset()
		sharedTable.fsm = previousShared.fsm
		sharedTable.StateMachine = previousShared.StateMachine
		sharedTable.FSM = previousShared.FSM
	end

	return env
end

function MockSpecHelpers.makeCharacterRig(env: any, name: string?): (Model, Humanoid, BasePart, BasePart, BasePart)
	local model = env:DestroyLater(Instance.new("Model"))
	model.Name = name or "MockCharacter"
	model.Parent = workspace

	local humanoid = env:DestroyLater(Instance.new("Humanoid"))
	humanoid.Parent = model

	local root = env:DestroyLater(Instance.new("Part"))
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(0, 5, 0)
	root.Parent = model

	local head = env:DestroyLater(Instance.new("Part"))
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.Position = root.Position + Vector3.new(0, 2, 0)
	head.Parent = model

	local rightHand = env:DestroyLater(Instance.new("Part"))
	rightHand.Name = "RightHand"
	rightHand.Size = Vector3.new(1, 1, 1)
	rightHand.Position = root.Position + Vector3.new(2, 0, 0)
	rightHand.Parent = model

	local leftHand = env:DestroyLater(Instance.new("Part"))
	leftHand.Name = "LeftHand"
	leftHand.Size = Vector3.new(1, 1, 1)
	leftHand.Position = root.Position + Vector3.new(-2, 0, 0)
	leftHand.Parent = model

	local rootJoint = env:DestroyLater(Instance.new("Motor6D"))
	rootJoint.Name = "RootJoint"
	rootJoint.C0 = CFrame.new()
	rootJoint.Parent = root

	model.PrimaryPart = root

	return model, humanoid, root, rightHand, leftHand
end

function MockSpecHelpers.makeFakePlayer(userId: number, character: Model?): any
	local player: any = {
		UserId = userId,
		Character = character,
		Parent = game:GetService("Players"),
	}
	function player:IsA(className: string)
		return className == "Player"
	end
	return player
end

function MockSpecHelpers.createCharacterEntity(env: any, entityId: string, data: any?): any
	local initial = table.clone(data or {})
	initial.Health = if initial.Health ~= nil then initial.Health else 100
	initial.MaxHealth = if initial.MaxHealth ~= nil then initial.MaxHealth else 100
	initial.Stamina = if initial.Stamina ~= nil then initial.Stamina else 100
	initial.MaxStamina = if initial.MaxStamina ~= nil then initial.MaxStamina else 100
	initial.Mana = if initial.Mana ~= nil then initial.Mana else 50
	initial.MaxMana = if initial.MaxMana ~= nil then initial.MaxMana else 50
	initial.IsStunned = if initial.IsStunned ~= nil then initial.IsStunned else false
	initial.IsKnocked = if initial.IsKnocked ~= nil then initial.IsKnocked else false
	initial.IsBlocking = if initial.IsBlocking ~= nil then initial.IsBlocking else false
	initial.CanMove = if initial.CanMove ~= nil then initial.CanMove else true
	initial.MoveSpeedCap = if initial.MoveSpeedCap ~= nil then initial.MoveSpeedCap else 16
	initial.EquippedRight = if initial.EquippedRight ~= nil then initial.EquippedRight else ""
	initial.EquippedLeft = if initial.EquippedLeft ~= nil then initial.EquippedLeft else ""
	initial.EquipLock = if typeof(initial.EquipLock) == "table" then table.clone(initial.EquipLock) else {}
	initial.AbilityCooldowns = if typeof(initial.AbilityCooldowns) == "table" then table.clone(initial.AbilityCooldowns) else {}
	initial.ActiveStatusEffects = if typeof(initial.ActiveStatusEffects) == "table" then table.clone(initial.ActiveStatusEffects) else {}
	local entity = env.Mock:CreateEntity("CharacterEntity", entityId, initial)
	return entity
end

function MockSpecHelpers.createPlayerEntity(env: any, entityId: string, data: any?): any
	local initial = table.clone(data or {})
	initial.Inventory = if typeof(initial.Inventory) == "table" then table.clone(initial.Inventory) else {}
	initial.BagContents = if typeof(initial.BagContents) == "table" then table.clone(initial.BagContents) else {}
	initial.Equipped = if typeof(initial.Equipped) == "table" then table.clone(initial.Equipped) else {}
	initial.WeaponEqp = if initial.WeaponEqp ~= nil then initial.WeaponEqp else ""
	initial.LearnedAbilities = if typeof(initial.LearnedAbilities) == "table" then table.clone(initial.LearnedAbilities) else {}
	initial.QuickItemSlots = if typeof(initial.QuickItemSlots) == "table" then table.clone(initial.QuickItemSlots) else { "", "", "", "" }
	local entity = env.Mock:CreateEntity("PlayerEntity", entityId, initial)
	return entity
end

function MockSpecHelpers.registerDefaultModules(env: any, options: any?): any
	local config = options or {}
	local itemCatalog = config.ItemCatalog or {}
	local recorded = {
		Intents = {},
		AppliedEffects = {},
	}

	env:RegisterModule("IntentSchema", makeIntentSchema(recorded.Intents))
	env:RegisterModule("DamageCalculator", config.DamageCalculator or {
		Compute = function(baseDamage: number, isBlocking: boolean)
			return if isBlocking then baseDamage * 0.5 else baseDamage
		end,
		GetWeaponBaseDamage = function(itemData: any)
			return tonumber(itemData and itemData.WeaponStats and itemData.WeaponStats.Attack) or 10
		end,
	})
	env:RegisterModule("StatusEffectDefs", config.StatusEffectDefs or {
		Get = function(effectId: string)
			local defs = config.StatusDefs or {}
			return defs[effectId]
		end,
	})
	env:RegisterModule("TalentTreeDefs", config.TalentTreeDefs or {
		GetMergedPassiveEffects = function(_playerEntity: any)
			return config.PassiveEffects or {}
		end,
		IsAbilityUnlocked = function(_abilityId: string, _playerEntity: any)
			return config.IsAbilityUnlocked
		end,
		GetRemainingSkillPoints = function(playerEntity: any)
			return tonumber(playerEntity.SkillPoints) or 0
		end,
		CanUnlock = function(_nodeId: string, _playerEntity: any)
			return true, nil
		end,
		GetNode = function(_nodeId: string)
			return nil
		end,
	})
	env:RegisterModule("StatusEffectHelper", config.StatusEffectHelper or {
		Apply = function(_orchestrator: any, targetEntityId: string, effectId: string)
			table.insert(recorded.AppliedEffects, { TargetEntityId = targetEntityId, EffectId = effectId })
		end,
	})
	env:RegisterModule("AbilityDefs", config.AbilityDefs or {
		GetAbility = function(abilityId: string)
			local defs = config.Abilities or {}
			return defs[abilityId]
		end,
		GetConsumable = function(itemId: string)
			local defs = config.Consumables or {}
			return defs[itemId]
		end,
	})
	env:RegisterModule("EquipHelpers", config.EquipHelpers or makeEquipHelpers(itemCatalog, config))
	env:RegisterModule("StatDefs", config.StatDefs or {
		Stats = { Strength = true, Agility = true, Vitality = true, Endurance = true, Intelligence = true, Luck = true },
		MAX_STAT_LEVEL = 100,
		ComputeBonuses = function(_playerEntity: any)
			return config.StatBonuses or {}
		end,
	})

	return recorded
end

function MockSpecHelpers.makeItemTemplate(env: any, itemId: string, includeHandle: boolean?, primaryName: string?): Model
	local model = env:DestroyLater(Instance.new("Model"))
	model.Name = itemId

	local part = env:DestroyLater(Instance.new("Part"))
	part.Name = if includeHandle == false then (primaryName or "Body") else "Handle"
	part.Size = Vector3.new(1, 1, 3)
	part.Parent = model
	model.PrimaryPart = part

	return model
end

function MockSpecHelpers.ensureAsset(env: any, itemId: string, asModel: boolean?): Instance
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
		(asset :: BasePart).Size = Vector3.new(1, 1, 1)
	else
		asset = MockSpecHelpers.makeItemTemplate(env, itemId, true)
	end
	asset.Parent = assets
	return asset
end

function MockSpecHelpers.makeChildJob(outcome: string, onStart: ((any, any) -> ())?, failureReason: string?): any
	local completed = createSignal()
	local failed = createSignal()
	local cancelled = createSignal()
	local job: any = {
		IsActive = true,
		Completed = completed,
		Failed = failed,
		Cancelled = cancelled,
	}

	function job:Start(args)
		self.StartArgs = args
		if onStart then
			onStart(self, args)
		end
		if outcome == "completed" then
			self.IsActive = false
			completed:Fire()
		elseif outcome == "failed" then
			self.IsActive = false
			failed:Fire(failureReason or "failed")
		elseif outcome == "cancelled" then
			self.IsActive = false
			cancelled:Fire()
		end
	end

	function job:Cancel()
		self.IsActive = false
		cancelled:Fire()
	end

	return job
end

function MockSpecHelpers.stepUntil(env: any, machine: any, target: any, maxFrames: number?): boolean
	local frames = maxFrames or 240
	for _ = 1, frames do
		if type(target) == "string" then
			if machine.State == target then
				return true
			end
		elseif type(target) == "table" then
			if table.find(target, machine.State) then
				return true
			end
		elseif type(target) == "function" then
			if target(machine) then
				return true
			end
		end
		env.Mock:StepFrames(1)
	end
	return false
end

function MockSpecHelpers.getTransitionSequence(env: any, machine: any): { string }
	local transitions = env.Mock:GetTransitions(machine.Id)
	local sequence = {}
	for _, entry in ipairs(transitions) do
		table.insert(sequence, tostring(entry.To))
	end
	return sequence
end

function MockSpecHelpers.setHumanoidState(humanoid: Humanoid, state: Enum.HumanoidStateType)
	pcall(function()
		humanoid:ChangeState(state)
	end)
end

return MockSpecHelpers
