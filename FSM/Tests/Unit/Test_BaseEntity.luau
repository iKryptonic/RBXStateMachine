--!strict
-- @Name Test_BaseEntity
-- @Author iKrypto
-- @Description Unit tests for BaseEntity schema validation, property wrapping, and update cycles.

local BaseEntity = require(game:FindFirstChild("BaseEntity", true) :: any)
local TestBase = require(script.Parent:FindFirstChild("TestBase") :: any)

local Test_BaseEntity = {}

local function createTestEntity(name: string, instance: Instance)
	local TestEntity = BaseEntity.Extend({ Name = name, Schema = {} })
	function TestEntity:GetContext() return {} end
	function TestEntity:OnCleanup() end
	return TestEntity.new({ Name = name, Instance = instance })
end

--[[
	@summary Executes the BaseEntity unit test suite.
	@return boolean -- True when the suite passes
]]
function Test_BaseEntity.Run()
	local tester = TestBase.new("BaseEntity")

	-- TEST 1: Initialization & Schema
	tester:RunTest("Initialization & Schema", function(t)
		local part = Instance.new("Part")
		part.Name = "TestPart"
		local entity = createTestEntity("TestEntity", part)

		entity:DefineSchema({
			Transparency = { Type = "number" },
			Name = { Type = "string" },
			Target = { Type = "Part" } -- Specific class check
		})
        entity.ApplyChanges = function(self, changes)
            for key, value in pairs(changes) do
                self.Instance[key] = value
            end
        end

		t:AssertEquals(entity.Instance, part, "Instance should be accessible via proxy")
		t:AssertEquals(entity.Name, "TestEntity", "Entity Name should take precedence over Instance Name")

		entity:Destroy()
	end)

	-- TEST 2: Property Validation
	tester:RunTest("Property Validation", function(t)
		local part = Instance.new("Part")
		local entity = createTestEntity("TestEntity", part)
		entity:DefineSchema({
			Val = { Type = "number" },
			Ref = { Type = "Part" }
		})
        entity.ApplyChanges = function(self, changes)
            for key, value in pairs(changes) do
                self.Instance[key] = value
            end
        end

		-- Valid Set
		entity.Val = 10
		t:AssertEquals(entity.Val, 10, "Should read back pending value")

		-- Invalid Type
		entity.Val = "String"
		t:AssertEquals(entity.Val, 10, "Should ignore invalid type assignment and keep old value")

		-- Instance Class Matching
		local otherPart = Instance.new("Part")
		local folder = Instance.new("Folder")

		entity.Ref = otherPart
		t:AssertEquals(entity.Ref, otherPart, "Should accept correct ClassName (Part)")

		entity.Ref = folder
		t:AssertEquals(entity.Ref, otherPart, "Should reject incorrect ClassName (Folder)")

		entity:Destroy()
	end)

	-- TEST 3: Update Cycle
	tester:RunTest("Update Cycle", function(t)
		local part = Instance.new("Part")
		part.Transparency = 0
		local entity = createTestEntity("TestEntity", part)
		entity:DefineSchema({ Transparency = { Type = "number" } })

		-- Mock ApplyChanges
		local capturedChanges = nil
		entity.ApplyChanges = function(self, changes)
			capturedChanges = changes
			if changes.Transparency then
				self.Instance.Transparency = changes.Transparency
			end
		end

		entity.Transparency = 0.8
		t:AssertEquals(part.Transparency, 0, "Instance should not update immediately (Pending state)")

		entity:UpdateEntity()

		t:Assert(capturedChanges ~= nil, "ApplyChanges should be called")
		t:AssertEquals(capturedChanges.Transparency, 0.8, "Changes table should have correct value")
		t:Assert(math.abs(part.Transparency-0.8) < 0.01, "Instance should be updated after ApplyChanges. Transparency should be 0.8 Actual: " .. tostring(part.Transparency))

		entity:Destroy()
	end)

	-- TEST 4: Immutability & Safety
	tester:RunTest("Immutability & Safety", function(t)
		local part = Instance.new("Part")
		local entity = createTestEntity("ImmutableEntity", part)
		entity:DefineSchema({ Val = { Type = "number" } })

		-- Try to set property
		entity.Val = 5
		
		-- Try to update without overriding ApplyChanges
		local success = entity:UpdateEntity()
		t:AssertEquals(success, false, "UpdateEntity should fail if ApplyChanges is not overridden (Immutable)")
		
		-- Override ApplyChanges to make it mutable
		entity.ApplyChanges = function(self, changes) end
		
		-- Now it should work
		success = entity:UpdateEntity()
		t:AssertEquals(success, true, "UpdateEntity should succeed after overriding ApplyChanges")
		
		entity:Destroy()
	end)

	-- TEST 5: Error Handling & Persistence
	tester:RunTest("Error Handling & Persistence", function(t)
		local part = Instance.new("Part")
		local entity = createTestEntity("ErrorEntity", part)
		entity:DefineSchema({ Val = { Type = "number" } })

		-- Override ApplyChanges to error
		entity.ApplyChanges = function(self, changes)
			error("Simulated Failure")
		end

		entity.Val = 42
		local success = entity:UpdateEntity()

		t:AssertEquals(success, false, "UpdateEntity should return false when ApplyChanges errors")
		
		-- Check persistence (Data should be committed even if visual update failed)
		t:AssertEquals(entity.Val, 42, "Data should be committed to state despite ApplyChanges failure")

		entity:Destroy()
	end)

	-- TEST 6: Lifecycle
	tester:RunTest("Lifecycle", function(t)
		local part = Instance.new("Part")
		local entity = createTestEntity("LifecycleEntity", part)
		entity:DefineSchema({ Val = { Type = "number" } })
		
		entity:Destroy()
		
		entity.Val = 10
		t:AssertEquals(entity.Val, nil, "Should not be able to read properties after destroy")

	end)
	
	tester:RunTest("Subclassing", function(t)
		local SubEntity = BaseEntity.Extend({ Name = "SubEntity", Schema = { Prop = { Type = "string" } } })
		
		function SubEntity:GetContext() return {} end
		function SubEntity:OnCleanup() end
		function SubEntity:ApplyChanges(changes)
			if changes.Prop then
				self.Instance.Name = changes.Prop
			end
		end
		
		local part = Instance.new("Part")
		local entity = SubEntity.new({ Name = "Sub", Instance = part })
		
		entity.Prop = "NewName"
		entity:UpdateEntity()
		
		t:AssertEquals(part.Name, "NewName", "Subclass ApplyChanges should work")
		t:AssertEquals(tostring(entity), "SubEntity(Sub)", "Subclass tostring should be correct")
		entity:Destroy()
	end)

	tester:RunTest("Locking", function(t)
		local part = Instance.new("Part")
		local entity = createTestEntity("LockEntity", part)
		entity:DefineSchema({ Val = { Type = "number" } })
		entity.ApplyChanges = function() end
		
		local success = entity:AcquireLock("SystemA")
		t:Assert(success, "Should acquire lock")
		
		success = entity:AcquireLock("SystemB")
		t:Assert(not success, "Should fail to acquire lock from different system")
		
		entity.Val = 1
		success = entity:UpdateEntity("SystemB")
		t:Assert(not success, "UpdateEntity should fail with wrong lock")
		
		success = entity:UpdateEntity("SystemA")
		t:Assert(success, "UpdateEntity should succeed with correct lock")
		
		success = entity:ReleaseLock("SystemB")
		t:Assert(not success, "Should fail to release lock from different system")
		
		success = entity:ReleaseLock("SystemA")
		t:Assert(success, "Should release lock")
		
		entity:Destroy()
	end)
	
	tester:RunTest("Context & Management", function(t)
		local part = Instance.new("Part")
		local entity = createTestEntity("CtxEntity", part)
		
		entity({ MyData = 123 })
		t:AssertEquals(entity.MyData, 123, "Context should be set via __call")
		
		entity:SetContext("OtherData", 456)
		t:AssertEquals(entity.OtherData, 456, "Context should be set via SetContext")
		
		local cleaned = false
		local obj = { Destroy = function() cleaned = true end }
		entity:Manage(obj)
		
		entity:Destroy()
		t:Assert(cleaned, "Managed object should be cleaned up")
	end)
	
	tester:RunTest("Auto-Destruction (AncestryChanged)", function(t)
		local part = Instance.new("Part")
		part.Parent = workspace
		local entity = createTestEntity("AutoDestroy", part)
		
		local destroyed = false
		entity.Destroyed:Connect(function() destroyed = true end)
		
		part:Destroy()
		task.wait() -- Wait for signal
		
		t:Assert(destroyed, "Entity should be destroyed when Instance is destroyed")
		t:AssertEquals(entity.IsValid, false, "Entity should be invalid")
	end)

	tester:RunTest("Subclass GetContext", function(t)
		local ContextEntity = BaseEntity.Extend({ Name = "ContextEntity", Schema = {} })
		
		function ContextEntity.GetContext(self)
			return { Injected = true }
		end
		
		local entity = ContextEntity.new({ Name = "Ctx", Instance = Instance.new("Part") })
		t:AssertEquals(entity.Injected, true, "GetContext should inject data into context")
	end)

	tester:RunTest("Serialize/Deserialize (Persist flagged)", function(t)
		local part = Instance.new("Part")
		local entity = createTestEntity("PersistEntity", part)
		entity:DefineSchema({
			Persisted = { Type = "number", Persist = true },
			NotPersisted = { Type = "number", Persist = false },
		})
		entity.ApplyChanges = function() end

		entity.Persisted = 12
		entity.NotPersisted = 99
		entity:UpdateEntity()

		local data = entity:Serialize()
		t:AssertEquals(data.Persisted, 12, "Serialize should include Persist=true fields")
		t:AssertEquals(data.NotPersisted, nil, "Serialize should exclude Persist=false fields")

		-- Deserialize should only load Persist=true
		entity.Persisted = 0
		entity.NotPersisted = 0
		entity:UpdateEntity()

		entity:Deserialize({ Persisted = 55, NotPersisted = 77 })
		entity:UpdateEntity()
		t:AssertEquals(entity.Persisted, 55, "Deserialize should apply Persist=true fields")
		t:AssertEquals(entity.NotPersisted, 0, "Deserialize should ignore Persist=false fields")

		entity:Destroy()
	end)

	tester:RunTest("Subclass GetContext (no error)", function(t)
		local Sub = BaseEntity.Extend({ Name = "NoGetContext", Schema = {} })
		function Sub:GetContext() return {} end
		function Sub:OnCleanup() end
		function Sub:ApplyChanges(_) end
		local ok = pcall(function()
			local e = Sub.new({ Name = "NoCtx", Instance = Instance.new("Part") })
			e:Destroy()
		end)
		t:Assert(ok, "Subclass with GetContext should not throw")
	end)

	tester:RunTest("Abstract ApplyChanges path executes", function(t)
		local part = Instance.new("Part")
		local entity = createTestEntity("AbstractApply", part)
		entity:DefineSchema({ Val = { Type = "number" } })

		-- Mark mutable but point ApplyChanges to the base (abstract) implementation.
		entity.ApplyChanges = BaseEntity.ApplyChanges
		entity.Val = 1
		local ok = entity:UpdateEntity()
		t:AssertEquals(ok, true, "UpdateEntity should succeed even if ApplyChanges is abstract (warn-only)")
		entity:Destroy()
	end)

	return tester:PrintSummary()
end

return Test_BaseEntity