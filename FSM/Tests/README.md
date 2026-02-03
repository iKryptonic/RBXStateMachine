# FSM Test Suite

This folder contains the automated test suites for the FiniteStateMachine library.

## How tests are discovered

- Any `ModuleScript` named `Test_*` is treated as a test suite.
- Server runner executes all suites **except** names containing `_Client`.
- Client runner executes only suites with `_Client` in the name.
- Discovery is **recursive** (subfolders are allowed).

Suggested grouping (optional):
- `Integration/`: suites that touch multiple modules and/or Roblox services.
- `Unit/`: small, fast suites that focus on a single module.
- `E2E/`: end-to-end suites that exercise server/client wiring.

Entry points:
- `Tests.server.luau` (server runner)
- `Tests.client.luau` (client runner)

## Test runner behavior

The shared runner (`TestRunner.luau`) executes suites in stable alphabetical order and creates an isolated runtime folder (`__TestRuntime`) under the Tests folder for the duration of the run.

That runtime folder contains cloned copies of:
- `Fixtures/`
- `Mocks/`
- `TestBase.luau`
- `TestUtils.luau`

Each test suite is cloned into `__TestRuntime` before it is required. This keeps relative requires working and avoids polluting the original test modules.

## Writing a new test suite

Template:

- File name: `Test_<Area>.luau` (or `Test_<Area>_Client.luau` for client-only suites)
- Export: a table containing a `Run()` function.
- Use `TestBase` assertions:
  - `t:Assert(condition, message)`
  - `t:AssertEquals(actual, expected, message?)`
  - `t:SkipTest(reason)` for environment-dependent cases.

Placement:
- Put unit suites under `Unit/`.
- Put integration suites under `Integration/`.
- Put end-to-end suites under `E2E/`.

Most tests use this pattern to access `TestBase` when run via the runner:

```lua
local TestBase = require(script:FindFirstChild("TestBase") :: any)
```

## Fixtures

The `Fixtures/` folder contains Rojo-friendly dummy registries and subclasses used for compilation/discovery/replication tests.
Use the installer:

```lua
local Fixtures = require(script.Parent:WaitForChild("Fixtures"):WaitForChild("Setup") :: any)
local install = Fixtures.Install()
if not install.Ok then
    t:SkipTest("fixtures unavailable")
end
```

## Notes on validation

Some static analyzers do not understand Roblox-style dynamic `require(...)` (e.g. `require(game:FindFirstChild(...))`). The source of truth is Studio runtime execution.
