--!nocheck
-- @Name Test_PlayerEntityPersistence
-- @Author Copilot
-- @Description Unit tests for PlayerEntity persistence schema and filtered serialize/deserialize behavior.

local TestBase = require((script.Parent:FindFirstChild("TestBase") or script.Parent.Parent:FindFirstChild("TestBase")) :: any)

local Test_PlayerEntityPersistence = {}

local function findModule(moduleName: string, ancestorNames: { string }): ModuleScript
	for _, descendant in ipairs(game:GetDescendants()) do
		if descendant:IsA("ModuleScript") and descendant.Name == moduleName then
			local current = descendant.Parent
			local matches = true
			for _, ancestorName in ipairs(ancestorNames) do
				if not current or current.Name ~= ancestorName then
					matches = false
					break
				end
				current = current.Parent
			end
			if matches then
				return descendant
			end
		end
	end
	error("Module not found: " .. moduleName)
end

local EntityRegistry = require(findModule("EntityRegistry", { "FSM", "RBXStateMachine" }))

local function countKeys(tbl)
	local count = 0
	for _ in pairs(tbl) do
		count += 1
	end
	return count
end

local function serializePersisted(schema, entity)
	local serialized = {}
	for fieldName, fieldSchema in pairs(schema) do
		if fieldSchema.Persist == true then
			serialized[fieldName] = entity[fieldName]
		end
	end
	return serialized
end

local function deserializePersisted(schema, entity, payload)
	for fieldName, fieldSchema in pairs(schema) do
		if fieldSchema.Persist == true and payload[fieldName] ~= nil then
			entity[fieldName] = payload[fieldName]
		end
	end
	return entity
end

function Test_PlayerEntityPersistence.Run()
	local tester = TestBase.new("PlayerEntityPersistence")
	local schema = EntityRegistry.PlayerEntity.Schema

	tester:RunTest("PlayerEntity schema marks persist flags correctly", function(t)
		t:Assert(schema.UserId.Persist == true, "UserId should be persisted")
		t:Assert(schema.Class.Persist == true, "Class should be persisted")
		t:Assert(schema.Inventory.Persist == true, "Inventory should be persisted")
		t:Assert(schema.Equipped.Persist == true, "Equipped should be persisted")
		t:Assert(schema.WeaponEqp.Persist == true, "WeaponEqp should be persisted")
		t:Assert(schema.ActionBar.Persist == true, "ActionBar should be persisted")
		t:Assert(schema.Settings.Persist == true, "Settings should be persisted")
		t:Assert(schema.DataVersion.Persist == true, "DataVersion should be persisted")
		t:Assert(schema.Cooldowns.Persist == false, "Cooldowns should not be persisted")
		t:Assert(schema.Revision.Persist == false, "Revision should not be persisted")
	end)

	tester:RunTest("Serialize keeps only persist true fields", function(t)
		local entity = {
			UserId = 245,
			Class = "Knight",
			Inventory = { "Sword01", "Potion01" },
			Equipped = { Right = "Sword01", Left = "Shield01" },
			WeaponEqp = "Sword01",
			ActionBar = { "Slash", "Block", "Dash" },
			Settings = { MouseLocked = true, QuickCast = false },
			Cooldowns = { Slash = 1.5 },
			Revision = 77,
			DataVersion = 3,
		}

		local serialized = serializePersisted(schema, entity)

		t:AssertEquals(countKeys(serialized), 8, "Serialize should only emit the eight persisted PlayerEntity fields")
		t:AssertEquals(serialized.UserId, entity.UserId, "Serialize should include UserId")
		t:AssertEquals(serialized.Class, entity.Class, "Serialize should include Class")
		t:AssertEquals(serialized.Inventory, entity.Inventory, "Serialize should include Inventory")
		t:AssertEquals(serialized.Equipped, entity.Equipped, "Serialize should include Equipped")
		t:AssertEquals(serialized.WeaponEqp, entity.WeaponEqp, "Serialize should include WeaponEqp")
		t:AssertEquals(serialized.ActionBar, entity.ActionBar, "Serialize should include ActionBar")
		t:AssertEquals(serialized.Settings, entity.Settings, "Serialize should include Settings")
		t:AssertEquals(serialized.DataVersion, entity.DataVersion, "Serialize should include DataVersion")
		t:AssertEquals(serialized.Cooldowns, nil, "Serialize should exclude Cooldowns")
		t:AssertEquals(serialized.Revision, nil, "Serialize should exclude Revision")
	end)

	tester:RunTest("Deserialize restores only persisted fields onto a fresh entity", function(t)
		local sourceEntity = {
			UserId = 512,
			Class = "Archer",
			Inventory = { "Bow01", "Arrow01" },
			Equipped = { Right = "Bow01" },
			WeaponEqp = "Bow01",
			ActionBar = { "Shoot", "Roll", "Aim" },
			Settings = { Sensitivity = 0.6 },
			Cooldowns = { Shoot = 2.0 },
			Revision = 9,
			DataVersion = 4,
		}
		local serialized = serializePersisted(schema, sourceEntity)

		local originalCooldowns = { Existing = true }
		local freshEntity = {
			UserId = 0,
			Class = "",
			Inventory = {},
			Equipped = {},
			WeaponEqp = "",
			ActionBar = {},
			Settings = {},
			Cooldowns = originalCooldowns,
			Revision = 99,
			DataVersion = 0,
		}

		deserializePersisted(schema, freshEntity, serialized)

		t:AssertEquals(freshEntity.UserId, sourceEntity.UserId, "Deserialize should restore UserId")
		t:AssertEquals(freshEntity.Class, sourceEntity.Class, "Deserialize should restore Class")
		t:AssertEquals(freshEntity.Inventory, sourceEntity.Inventory, "Deserialize should restore Inventory")
		t:AssertEquals(freshEntity.Equipped, sourceEntity.Equipped, "Deserialize should restore Equipped")
		t:AssertEquals(freshEntity.WeaponEqp, sourceEntity.WeaponEqp, "Deserialize should restore WeaponEqp")
		t:AssertEquals(freshEntity.ActionBar, sourceEntity.ActionBar, "Deserialize should restore ActionBar")
		t:AssertEquals(freshEntity.Settings, sourceEntity.Settings, "Deserialize should restore Settings")
		t:AssertEquals(freshEntity.DataVersion, sourceEntity.DataVersion, "Deserialize should restore DataVersion")
		t:AssertEquals(freshEntity.Cooldowns, originalCooldowns, "Deserialize should leave Cooldowns unchanged")
		t:AssertEquals(freshEntity.Revision, 99, "Deserialize should leave Revision unchanged")
	end)

	return tester:PrintSummary()
end

return Test_PlayerEntityPersistence
