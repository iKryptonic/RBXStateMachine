# ServiceManager — Design Document

> **Author**: iKrypto  
> **Version**: 1.0  
> **Status**: Complete  
> **Replaces**: Legacy `ServiceManager/`

---

## 1. Executive Summary

The **ServiceManager** suite is a ground-up replacement for the legacy ServiceManager diagnostic implementation. It introduces a fundamentally different interaction model based on **Z-axis depth navigation** (drill-down sub-panes) instead of flat page switching, orchestrated by a **Behavior Tree brain**, powered by a **Reactive Store** for change-tracked UI updates, and enhanced with an **Analytics Engine** that proactively detects bottlenecks, state stalls, and anomalies.

### Key Differentiators
- **Z-Axis Navigation**: Clicking any data element "unfolds" deeper sub-panes with animated transitions — up to 6 depth levels — replacing the legacy tab/page model.
- **Behavior Tree Orchestration**: A single `ServiceBrain` behavior tree coordinates all data fetching, rendering, insight analysis, and animation ticking in a declarative, composable control flow.
- **Reactive Store**: All UI state flows through a centralized, change-tracked store with key-specific subscriptions and batch updates — eliminating manual dirty-flag management.
- **Additive Insight Engine**: 6 built-in detection rules proactively surface FSM stalls, task bottlenecks, entity anomalies, memory pressure, priority inversions, and orphaned event buses.
- **Glass Engine Aesthetic**: A deep-space glass-morphism design system with staggered animations, pulse effects, and hover glows.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    init.luau (Entry)                     │
│  Wires all components, scheduler task, server polling   │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ GlassGUI │  │ ZAxis        │  │ ServiceBrain       │  │
│  │ (UI Shell)│  │ Navigator    │  │ (Behavior Tree)  │  │
│  └──────┬───┘  └──────┬───────┘  └────────┬─────────┘  │
│         │             │                    │             │
│  ┌──────┴─────────────┴────────────────────┴─────────┐  │
│  │              ReactiveStore (State Hub)             │  │
│  └──────┬─────────────┬─────────────┬────────────────┘  │
│         │             │             │                    │
│  ┌──────┴───┐  ┌──────┴───┐  ┌─────┴──────────────┐    │
│  │Animation │  │Analytics │  │ Subsystem Modules   │    │
│  │Controller│  │Engine    │  │ Tasks│FSM│Entity│...│    │
│  └──────────┘  └──────────┘  └─────────────────────┘    │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### File Structure

```
ServiceManager/
├── init.luau                  # Entry point — wires everything
├── Types.luau                 # Strict type definitions
├── Theme.luau                 # Glass Engine design tokens
├── ReactiveStore.luau         # Change-tracked reactive state
├── ZAxisNavigator.luau        # Z-axis depth navigation
├── ServiceBrain.luau            # Behavior Tree brain
├── AnimationController.luau   # Staggered animation system
├── AnalyticsEngine.luau       # Insight detection engine
├── GlassGUI.luau              # Programmatic ScreenGui builder
└── Subsystems/
    ├── TasksModule.luau       # Scheduler tasks introspection
    ├── FSMModule.luau         # State machine visualization
    ├── EntityModule.luau      # Entity schema browser
    ├── NetworkModule.luau     # Event bus/commands/remotes
    ├── DataStoreModule.luau   # Persistence monitoring
    └── InsightsModule.luau    # Analytics insight display
```

---

## 3. Component Details

### 3.1 ReactiveStore

A centralized, change-tracked data store that powers all UI updates.

| Method | Description |
|--------|-------------|
| `Get(key)` | Read a value |
| `Set(key, value)` | Write and notify subscribers |
| `BatchUpdate(fn)` | Group multiple writes, defer notifications |
| `Subscribe(key?, handler)` | Register for changes (key-specific or wildcard) |
| `IsDirty(key)` | Check if key changed since last `ClearDirty()` |
| `GetSnapshot()` | Clone all data |

**Design Decision**: Store keys follow a namespaced dot-syntax convention (`"tasks.list"`, `"fsm.selected"`, `"insights.active"`). This enables subsystem-scoped subscriptions without cross-contamination.

### 3.2 ZAxisNavigator

Replaces flat page navigation with hierarchical depth-based drill-downs.

| Method | Description |
|--------|-------------|
| `RegisterRootLayer(id, label, builder)` | Define a depth-0 subsystem panel |
| `ExpandLayer({Id, ParentId, Label, Builder, Context})` | Unfold a deeper sub-pane |
| `CollapseToLayer(layerId)` | Pop back to a specific depth |
| `NavigateToRoot(layerId)` | Switch to a root subsystem (collapses all) |
| `GetBreadcrumbs()` | Get the navigation trail |
| `OnBreadcrumbChanged(callback)` | React to navigation changes |

**Key Constraints**:
- Maximum depth: 6 layers
- Each layer gets progressively brighter glass (+6 RGB per depth level)
- A 2px accent glow line appears on the left edge of sub-layers
- Expand animation uses `Exponential.Out`, collapse uses `Exponential.In`

### 3.3 ServiceBrain (Behavior Tree)

The top-level control flow that runs every scheduler tick:

```
Sequence:
  ├─ Condition: IsInitialized?
  ├─ Action: SyncContextData
  ├─ Selector:
  │   ├─ Sequence(Full Cycle):
  │   │   ├─ Condition: NeedsDataRefresh?
  │   │   ├─ Action: FetchSubsystemData
  │   │   ├─ Succeeder: RunInsightAnalysis
  │   │   └─ Action: RenderActiveSubsystem
  │   ├─ Sequence(Partial):
  │   │   ├─ Condition: HasDirtyUI?
  │   │   └─ Action: RenderActiveSubsystem
  │   └─ Succeeder: UpdateAnimations (fallback)
  └─ Succeeder: UpdateAnimations (always)
```

**Why a Behavior Tree?** The BT model elegantly handles conditional work selection (Selector), sequential dependency chains (Sequence), and graceful degradation (Succeeder wrapping optional work). Unlike a monolithic `Update()` function, each concern is isolated and testable.

### 3.4 AnimationController

Every UI element animates — nothing appears instantly.

| Method | Description |
|--------|-------------|
| `Animate(target, props, tweenInfo?, delay?)` | Queue a single property animation |
| `StaggerIn(items, from, to, tweenInfo?)` | Animate N items with 35ms incremental delays |
| `StartPulse(id, target, prop, value)` | Continuous glow/dim cycle (infinite, reversing) |
| `StopPulse(id)` | Restore to original value |
| `ExpandIn(frame)` | Scale-up + fade-in for sub-panes |
| `CollapseOut(frame, onDone?)` | Scale-down + fade-out with cleanup |
| `HoverGlow(button, color?)` | Auto hover color transition |
| `Tick()` | Process the animation queue (called by brain) |

### 3.5 AnalyticsEngine

Proactive detection (runs every 1.0s):

| Rule | Threshold | Severity |
|------|-----------|----------|
| FSM State Stall | >30s in one state | WARNING |
| Task Bottleneck | >8ms avg execution | CRITICAL |
| Entity Count Spike | >500 entities | WARNING |
| Memory Pressure | >512MB | CRITICAL |
| FSM Priority Inversion | >10 render-priority machines | WARNING |
| Orphaned Event Bus | 0 subscribers | SUGGESTION |

Insights auto-resolve after 10s if not re-produced. Critical insights trigger a toast notification in the GUI.

### 3.6 GlassGUI

Fully programmatic — no serialized GUI dependency.

**Layout**:
```
┌──────────────────────────────────────────────────────┐
│ ◆ SERVICE MANAGER                          ─  ✕  │ ← Title Bar (32px, draggable)
├────┬─────────────────────────────────────────────────┤
│ 📋 │ TASKS › TaskPool › RequestHandler             │ ← Breadcrumb Bar (26px)
│ 🔄 ├─────────────────────────────────────────────────┤
│ 📦 │                                                │
│ 🌐 │              Body Container                    │ ← Layer Host (ScrollingFrame)
│ 💾 │         (Z-Axis Navigator renders here)        │
│ 💡 │                                                │
├────┴─────────────────────────────────────────────────┤
│ ● CONNECTED  CLIENT  0 insights         60 fps      │ ← Status Bar (24px)
└──────────────────────────────────────────────────────┘
```

**Features**: Draggable window, minimize to title bar, close with animated collapse, sidebar icon rail with tooltips, real-time FPS/insight/connection status, toast notifications for critical insights.

---

## 4. Subsystem Module Pattern

All 6 subsystems follow an identical interface:

```luau
local Module = {}
Module.__index = Module

function Module.new(): any                                -- Constructor
function Module:FetchData(nexus: any)                     -- Pull data from Orchestrator
function Module:Render(nexus: any)                        -- Optional render hook
function Module:BuildRootLayer(frame: Frame, context: any) -- Z-axis depth-0 builder
function Module:_Build*Row(...)                           -- Row element builders
function Module:_Build*DetailLayer(frame, context)        -- Drill-down builders
function Module:Destroy()                                 -- Cleanup
```

**Data Flow Per Subsystem**:
1. `FetchData` reads from `Orchestrator` (client mode) or `_serverData` (server mode)
2. Results are written to `ReactiveStore` via `BatchUpdate`
3. `BuildRootLayer` creates the depth-0 panel with interactive rows
4. Clicking a row calls `ZAxisNavigator:ExpandLayer()` → triggers a depth-1 builder
5. Depth-1 elements can further expand to depth-2, etc.

---

## 5. Subsystem Details

### 5.1 Tasks
- **Root**: Performance strip (scheduled/active/avg time) + sorted task list
- **Drill**: Task detail (priority, event, perf stats, recurrence) → property terminal

### 5.2 FSM
- **Root**: Summary stats (active/stalled/transitions) + FSM list with stall indicators
- **Drill**: State graph visualization (grid-laid nodes, current state highlighted with UIStroke), properties panel, perf data → state detail terminal

### 5.3 Entity
- **Root**: Entities grouped by class with validity indicators and version numbers
- **Drill**: Full schema table with type-colored values (number=Cyan, string=Green, boolean=Purple), persist/replicate flags → per-property terminal

### 5.4 Network
- **Root**: Three sections (Event Buses, Commands, Remotes) with type badges
- **Drill**: Subscriber counts, handler info, event metadata

### 5.5 DataStore
- **Root**: Persistent entities list with field counts and version numbers
- **Drill**: Per-field breakdown with type and current value

### 5.6 Insights
- **Root**: Severity summary strip + active insight list + recent history
- **Drill**: Full insight detail (severity, subsystem, metric/threshold, related IDs) with dismiss button

---

## 6. Client/Server Context

The suite operates in two modes, switchable at runtime:

| Mode | Data Source | Update Method |
|------|-------------|---------------|
| **Client** | Direct `Orchestrator.*` access | Immediate (same process) |
| **Server** | `ServiceManager_ServerSnapshot` RPC | 2s polling interval |

Server mode requires ServiceManager server handlers to be registered, either via `Orchestrator:RegisterComponents()` on the server or by calling `ServiceManager.RegisterServerHandlers(Orchestrator)` manually in custom boot code. The snapshot includes tasks, FSMs, entities, network buses, DataStore state, and memory metrics.

---

## 7. Integration

### Client Boot (in Orchestrator init or Client.luau)

```luau
-- After Orchestrator is initialized:
Orchestrator:StartServiceManager()
```

### Server Boot (in main.server.luau)

```luau
Orchestrator:RegisterComponents() -- registers ServiceManager server handlers on the server
```

### Toggle Keybind (optional)

```luau
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F2 then
        ServiceManager.Toggle()
    end
end)
```

---

## 8. Design Principles

1. **Zero Serialized GUI**: Everything is built programmatically. No `Serialized_GUI.luau` dependency.
2. **Strict Luau**: All files use `--!strict` pragma.
3. **Framework-Native**: Uses `BaseEntity.Extend()`, `BaseStateMachine.Extend()`, `BehaviorTree.*`, `Factory.CreateEntity/CreateStateMachine`, `Scheduler:Schedule()` — no external dependencies.
4. **Decoupled Subsystems**: Each subsystem module is self-contained with no cross-references. Adding a new subsystem requires only a new module file and a one-line registration in `init.luau`.
5. **Reactive-First**: No manual UI invalidation. All changes flow through `ReactiveStore → Subscribe → Rebuild`.
6. **Depth Over Breadth**: Information is organized hierarchically. Every detail is reachable via Z-axis drill-down, not cluttered on one page.
7. **Visibility Budget**: The behavior tree naturally throttles work — no data fetch unless the refresh interval has elapsed, no render unless the store is dirty, animations always tick.

---

## 9. Glass Engine Token Reference

| Token | Value |
|-------|-------|
| `Colors.RootBG` | `rgb(8, 8, 14)` |
| `Colors.Accent` | `rgb(56, 152, 255)` |
| `Colors.Success` | `rgb(60, 210, 120)` |
| `Colors.Danger` | `rgb(240, 80, 80)` |
| `Colors.Purple` | `rgb(155, 115, 255)` |
| `Colors.Cyan` | `rgb(0, 210, 225)` |
| `Radius.Lg` | `12px` |
| `Radius.Md` | `8px` |
| `Tween.Fast` | `0.15s Quint.Out` |
| `Tween.Expand` | `0.32s Exponential.Out` |
| `Tween.Pulse` | `0.8s Sine.InOut ∞ reverse` |
| Font.Primary | `GothamMedium` |
| Font.Mono | `RobotoMono` |

---

## 10. Migration from Legacy ServiceManager

ServiceManager is a **complete replacement** for the legacy `ServiceManager/` implementation. It does not extend or wrap the legacy code. The legacy `ServiceManager` directory remains functional for backward compatibility but can be disabled via `Settings.ServiceManager.Enabled = false`.

To switch, set:
```luau
Settings.ServiceManager.Enabled = false
```

Then start ServiceManager in your client/server boot flow as described in Section 7.

---

*End of Design Document*
