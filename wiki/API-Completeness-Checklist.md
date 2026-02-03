# API Completeness Checklist

Use this as a quick parity checklist when updating code or docs. If you add a new exported method in code, add it to the relevant API page.

- Orchestrator (`FSM/Orchestrator/init.luau`): `RegisterComponents`, `CreateEntity`, `CreateStateMachine`, `GetEntity`, `GetStateMachine`, `RetryStateMachine`, `CancelStateMachine`, `DeleteEntity`, `DeleteAllEntities`, `CancelAll`, `GetEntities`, `GetStateMachines`, `SendCommand`, `RegisterCommandHandler`, `RegisterRequestHandler`, `Request`, `PoolEntity`, `GetPooledEntity`, `RegisterEventBus`, `GetEventBus`, `FireEventBus`, `AwaitEventBus`, `StartServiceManagerAPI`
- BaseEntity (`FSM/Orchestrator/Factory/BaseEntity.luau`): `new`, `Extend`, `Log`, `DefineSchema`, `SetContext`, `Manage`, `Serialize`, `Deserialize`, `UpdateEntity`, `ApplyChanges`, `Cleanup`, `GetValidProperties`, `AcquireLock`, `ReleaseLock`, `Destroy` (+ callable context shortcut)
- BaseStateMachine (`FSM/Orchestrator/Factory/BaseStateMachine.luau`): `new`, `Extend`, `AddState`, `AddSubMachine`, `Manage`, `Start`, `ChangeState`, `Finish`, `Fail`, `Cancel`, `Destroy`, `Log`, `RegisterStates`, `OnCleanup` (+ internal `_Update`, `_Teardown`)
- Scheduler (`FSM/Orchestrator/Scheduler.luau`): `new`, `Initialize`, `Clear`, `Schedule`, `AddToHistory`, `Deschedule`, `GetTask`, `GetTaskCount`, `ExecuteTask`, `GetSyncData`, `CheckAdmin`, `ExposeAPI`, `ResetTask`, `GenerateKey`, `Start`, `Step` (+ internal `_internalExecute`, `_heapPush`, `_heapPop`)
- Logger (`FSM/Orchestrator/Logger.luau`): `new`, `Log`, `GetHistory`
- BehaviorTree (`FSM/Orchestrator/BehaviorTree.luau`): `Selector`, `Sequence`, `Inverter`, `Succeeder`, `Condition`, `SetState` (+ `BehaviorTreeStatus` constants)
- Factory (`FSM/Orchestrator/Factory/init.luau`): `Get`, `GetAll`, `LoadSubclasses`
- Signal (`FSM/Orchestrator/Signal.luau`): `new`, `Connect`, `Once`, `Fire`, `Wait`, `Destroy`
- DataStoreHandler (`FSM/Orchestrator/DataStoreHandler.luau`): `ResetAccessCount`, `get` (+ wrapper methods)
- EntityPersistence (`FSM/Orchestrator/EntityPersistence/init.luau`): `new`, `Save`, `Load`, `Update`, `Delete`
