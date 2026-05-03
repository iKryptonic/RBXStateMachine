--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MockFramework = require(script.Parent.Parent.MockFramework)
local MockCharacter = require(script.Parent.Parent.Mocks.MockCharacter)
local MockHelpers = require(script.Parent.Parent.Mocks.MockHelpers)

local MockSpecHelpers = {}
local sharedTable = shared :: any

local function getStateMachinesFolder(): Instance
	local folder = ReplicatedStorage:FindFirstChild("StateMachines") or ReplicatedStorage:FindFirstChild("StateMachine")
	assert(folder ~= nil, "State machine folder not found in ReplicatedStorage")
	return folder
end

local function assertModule(name: string): ModuleScript
	local moduleScript = getStateMachinesFolder():FindFirstChild(name)
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
		AppendIntent = function(charEntity: any, intent: any)
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
			if not entry or not entry.Template then
				return nil, nil
			end
			local clone = entry.Template:Clone()
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
		StowItem = function(item: Instance, character: Model, weld: any)
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
			if instance then
				pcall(function()
					instance:Destroy()
				end)
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
	local model, humanoid, root, rightHand, leftHand = MockCharacter.newCharacter(name or "MockCharacter", workspace)
	env:DestroyLater(model)
	return model, humanoid, root, rightHand, leftHand
end

function MockSpecHelpers.makeFakePlayer(userId: number, character: Model?): any
	return select(1, MockCharacter.newPlayer(userId, character))
end

function MockSpecHelpers.createCharacterEntity(env: any, entityId: string, data: any?): any
	return MockHelpers.CreateCharacterEntity(env.Mock, entityId, data)
end

function MockSpecHelpers.createPlayerEntity(env: any, entityId: string, data: any?): any
	return MockHelpers.CreatePlayerEntity(env.Mock, entityId, data)
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

function MockSpecHelpers.makeChildJob(outcome: string, onStart: any, failureReason: string?): any
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
	return MockHelpers.StepUntil(env.Mock, machine, target, maxFrames)
end

function MockSpecHelpers.getTransitionSequence(env: any, machine: any): { string }
	return MockHelpers.GetTransitionSequence(env.Mock, machine)
end

function MockSpecHelpers.setHumanoidState(humanoid: Humanoid, state: Enum.HumanoidStateType)
	pcall(function()
		humanoid:ChangeState(state)
	end)
end

return MockSpecHelpers
