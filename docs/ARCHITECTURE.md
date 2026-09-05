# Smart Debugger Architecture

## Runtime flow

`Simulink selection -> ModelManager -> SimulationManager -> SignalCapture -> ComparisonEngine -> RootCauseAnalyzer -> UI`

The UI is intentionally thin. Services are under `+smartdebugger` and can later be hosted by a MATLAB App Designer wrapper.

## MIL

MIL debugging loads the selected model, updates/compiles it, temporarily enables signal logging on the selected block's connected input/output lines, runs the model, reads the resulting logged data, and restores the original line/model parameters through `TransactionManager`.

## SIL

SIL is a separate mode. The current generic adapter accepts a SIL model and uses the same selected-interface capture mechanism. TargetLink-specific behavior is isolated in `TargetLinkAdapter` because generated TargetLink interfaces differ between projects and installations.

## Comparison

`ComparisonEngine` aligns MIL/SIL time histories using `TimeAlignmentEngine`, applies combined absolute/relative tolerance, and reports PASS, FAIL, UNMAPPED, NO_DATA, or SIZE_MISMATCH. `RootCauseAnalyzer` identifies the first observed failing compared signal. It deliberately does not label that signal as proven root cause.

## Compatibility

`CompatibilityManager` detects MATLAB/Simulink/Stateflow and optional Simulink Coder availability. Release-sensitive or optional integrations should remain inside adapters and capability checks.

## Non-destructive operation

Temporary parameter changes are recorded by `TransactionManager` and restored in reverse order using `onCleanup` in the simulation service. The application does not create permanent Scope, To Workspace, or TargetLink Sink blocks.

## Known limitations of this first slice

- Actual SIL mapping is project-specific and currently exposes a generic adapter boundary plus a simple name-based mapper.
- TargetLink runtime APIs are not assumed or fabricated.
- Stateflow inspection is object-level; arbitrary runtime local-variable capture is not claimed.
- MATLAB Function internal local-variable tracing is not claimed unless exposed by supported simulation APIs.
- Full bus-element and multi-rate normalization is an extension point.
- The repository cannot execute MATLAB/Simulink in the coding environment, so users must run the included code in their licensed MATLAB installation.
