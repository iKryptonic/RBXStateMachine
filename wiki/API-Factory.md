# API: Factory

Derived from the in-repo cheatsheet (`FSM/README.md`).

## 🧩 Factory

The registry compiler used by `Orchestrator:RegisterComponents()`.

You typically don’t call Factory methods directly unless you’re building tooling, debugging registry compilation, or doing advanced dynamic class loading.

The Orchestrator uses Factory to compile registry definitions into runtime-friendly class tables and then exposes them on `shared.Entity.*` and `shared.StateMachine.*`.

| Method | Signature | Description |
| :--- | :--- | :--- |
| `Get` | `(typeName: string, name: string): any` | Returns a compiled class table or throws. |
| `GetAll` | `(typeName: string): any` | Returns the compiled class table map (do not mutate). |
| `LoadSubclasses` | `(): ()` | Requires any ModuleScripts found alongside registries (implementation modules). |
