# ServiceManager FSM/Entity Page Pattern

## Overview

All ServiceManager UI pages have been migrated from the legacy controller pattern to the new FSM/Entity architecture. This provides better state management, improved testability, and cleaner separation of concerns.

## File Locations

- **FSM Files**: `Orchestrator/Core/ServiceManager/FSM/*PageFSM.luau`
- **Entity Files**: `Orchestrator/Core/ServiceManager/Entity/*PageEntity.luau`
- **Legacy Controllers**: `Orchestrator/Core/ServiceManager/Runtime/Pages/*.luau` (deprecated)

## Migrated Pages

| Page | FSM | Entity | Key Features |
|------|-----|--------|--------------|
| Console | `ConsolePageFSM.luau` | `ConsolePageEntity.luau` | Scroll engine, tokenizer, command registry, tab-completion |
| TaskList | `TaskListPageFSM.luau` | `TaskListPageEntity.luau` | Sorting (Name/Priority/Event), metadata panel, actions |
| Performance | `PerformancePageFSM.luau` | `PerformancePageEntity.luau` | Graph (Standard/Heatmap), per-task metrics, tooltips |
| History | `HistoryPageFSM.luau` | `HistoryPageEntity.luau` | Pagination, status filters, drill-down details |
| Settings | `SettingsPageFSM.luau` | `SettingsPageEntity.luau` | Boolean toggles, text/number inputs, nested subsections |
| Visualize | `VisualizePageFSM.luau` | `VisualizePageEntity.luau` | Force-directed graph, physics, pan/zoom, node dragging |
| CreateTask | `CreateTaskPageFSM.luau` | `CreateTaskPageEntity.luau` | Static form scaffolding |
| Logs | `LogsPageFSM.luau` | `LogsPageEntity.luau` | Level filters, search, auto-scroll |
| Entities | `EntitiesPageFSM.luau` | `EntitiesPageEntity.luau` | Card listing, metadata panel, archived toggle |
| FSMs | `FSMsPageFSM.luau` | `FSMsPageEntity.luau` | Active/Failed/Archived sections, action buttons |

## Architecture

### BasePageFSM
All page FSMs extend `BasePageFSM` which provides:
- Standard state machine lifecycle (`Initializing`, `Idle`, `DataFetching`, `Rendering`, `Destroyed`)
- Hooks for UI initialization, data fetching, and rendering
- Integration with ServiceManager context

### BasePageEntity
All page entities extend `BasePageEntity` which provides:
- Schema-based state management
- Connection management via `Manage()` 
- Automatic cleanup on destroy

## Usage

Pages are initialized via `PageInitializerFSM` which:
1. Locates GUI containers for each page
2. Creates Entity instances with appropriate context
3. Creates FSM instances bound to their entities
4. Stores references in `ServiceManager.PageEntities` and `ServiceManager.PageFSMs`

## Legacy Fallback

Legacy controllers in `Runtime/Pages/` are preserved for regression testing but marked as `@deprecated`. They may be invoked as fallback when FSM/Entity pages encounter errors.

## Adding New Pages

1. Create `<PageName>PageFSM.luau` extending `BasePageFSM`
2. Create `<PageName>PageEntity.luau` extending `BasePageEntity`
3. Add page name to `PageInitializerFSM:LocatingContainers` array
4. Optionally create legacy controller in `Runtime/Pages/` for fallback
