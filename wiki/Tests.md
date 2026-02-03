# Testing & Validation

We use **TestEZ** for behavior-driven development.

---

## 🧪 Running Tests
Sync the repo with **Rojo** and run:
```lua
TestEZ.TestBootstrap:run({ workspace.FSM.tests })
```

## 📝 Writing Specs
```lua
describe("BaseEntity", function()
    it("should reject non-schema properties", function()
        local e = BaseEntity.new({ Name = "T", Schema = { H = {Type="number"} } })
        expect(function() e.X = 1 end).to.throw()
    end)
end)
```
