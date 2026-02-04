--!strict
-- @Name DummyEntity (Test Fixture)
-- @Description Attaches behavior to shared.Entity.DummyEntity.

local RunService = game:GetService("RunService")

shared.__TestFlags = shared.__TestFlags or {}
shared.__TestFlags.DummyEntityLoaded = true

local DummyEntity = (shared.Entity and shared.Entity.DummyEntity)
if not DummyEntity then
	return {}
end

function DummyEntity:ApplyChanges(changes)
	-- Client/server safe: only visual change on client
	if not RunService:IsClient() then return end
	if self.Instance and self.Instance:IsA("BasePart") and changes.Value ~= nil then
		local clamped = math.clamp(changes.Value, 0, 1)
		self.Instance.Transparency = clamped
	end
	if self.Instance and self.Instance:IsA("BasePart") and changes.Label ~= nil then
		self.Instance.Name = tostring(changes.Label)
	end
end

function DummyEntity:OnCleanup() end

function DummyEntity:SetValue(value: number, label: string?)
	self.Value = value
	if label then
		self.Label = label
	end
	return self:UpdateEntity()
end

return DummyEntity
