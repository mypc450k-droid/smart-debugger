# TargetLink SIL integration

## Baseline

The TargetLink SIL integration is developed against TargetLink 24.1p2. The implementation intentionally does not hard-code a TargetLink version API such as `tl_get_version`.

## Design

`TargetLinkAdapter` is the compatibility boundary. It discovers the TargetLink APIs exposed by the current MATLAB session and records capabilities such as:

- `tl_set_sim_mode`
- `tl_build_host` / `tl_compile_host`
- `tl_sim`
- `tl_access_logdata`
- `tl_generate_code`
- `tl_get` / `tl_set`

`TargetLinkSILManager` is isolated from the existing `SimulationManager` MIL path. The existing MIL logging, bus extraction, runtime UI, and sample cursor are not modified by this integration layer.

## SIL execution sequence

1. Detect TargetLink APIs.
2. Set the selected TargetLink subsystem to host-code SIL when the installed API exposes `tl_set_sim_mode`.
3. Build the host application using `tl_build_host`, or `tl_compile_host` when that is the available capability.
4. Start the TargetLink simulation through `tl_sim`.
5. Access TargetLink Data Server data through `tl_access_logdata` when the exact installed API contract is available.

## Important safety rule

The Data Server API action/signature is intentionally not guessed. dSPACE documents `tl_access_logdata` as the API for retrieving/loading/saving MIL/SIL/PIL simulation data, but the exact action syntax is release/API-reference dependent. Until the installed TargetLink contract is verified, the manager reports `SIMULATED_NO_DATA` rather than fabricating internal signal values or silently falling back to unrelated Simulink signals.

## Capability diagnostic

From MATLAB:

```matlab
report = smartdebugger.targetLinkSILStatus();
```

With a selected block path:

```matlab
report = smartdebugger.targetLinkSILStatus('myModel/MyTargetLinkSubsystem');
```

This diagnostic does not compile, modify, or run the model.

## Future releases

New TargetLink releases are handled by capability discovery rather than a version-number switch. If a future release changes an API contract, the change is isolated in `TargetLinkAdapter` and does not require changes to the MIL execution path.
