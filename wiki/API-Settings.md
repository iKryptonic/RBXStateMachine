# API: Settings

Derived from the in-repo cheatsheet (`FSM/README.md`).

## ⚙️ Settings

Static configuration used by Orchestrator for remotes, persistence defaults, and Scheduler tasks.

- `Settings.Scheduler`, `Settings.DataStore`, `Settings.FSMSettings`, `Settings.StaticStrings`

You generally don’t need to edit Settings unless you are integrating this package into an existing framework that needs different remote names, datastore names/prefixes, or scheduling intervals.
