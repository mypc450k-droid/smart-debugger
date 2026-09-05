# Local validation checklist

The GitHub environment cannot run a licensed MATLAB/Simulink/Stateflow installation. This checklist is therefore the final runtime gate on the engineer's MATLAB workstation.

## 1. Static/application startup

```matlab
cd('<smart-debugger-root>')
addpath(genpath(pwd))
validateSmartDebugger
app = SmartDebugger;
```

Expected: the GUI opens without an exception and the compatibility area identifies the installed MATLAB/Simulink release.

## 2. Regression tests

```matlab
results = runtests('tests');
assert(all([results.Passed]), 'Smart Debugger regression tests failed.')
```

## 3. MIL smoke test

1. Open a simple model with a source, a computational block, and a sink.
2. Open the model with **Open MIL**.
3. Select the computational block in Simulink.
4. Click **Import**.
5. Confirm the block path and input/output port metadata.
6. Click **Run Debug**.
7. Confirm input and output tables contain time-varying signal data.
8. Verify the original signal logging properties are unchanged after the run.

## 4. SIL smoke test

1. Open/select the corresponding SIL model with **Open SIL**.
2. Switch the application mode to **SIL**.
3. Confirm automatic mapping or enter the exact SIL block path in the override field.
4. Click **Run Debug**.
5. Confirm the SIL input/output tables contain runtime data.

For a TargetLink S-Function workflow, do not force native Simulink SIL mode if the SIL model already represents the TargetLink implementation. The application treats that model as the SIL execution model.

## 5. MIL/SIL comparison

Run MIL and SIL for the same scenario, then click **Compare**.

Verify:

- input rows compare independently from output rows
- time alignment is applied
- absolute and relative tolerances are respected
- PASS is reported when differences are inside tolerance
- FAIL reports the first observed divergence
- the trace plot shows MIL, SIL and error

## 6. Restoration test

Before running Smart Debugger, record the logging properties of a selected signal. Run Smart Debugger and then verify:

- signal `DataLogging` is restored
- `DataLoggingNameMode` is restored
- `DataLoggingName` is restored
- model configuration is unchanged
- no Scope/To Workspace/TargetLink Sink block was added

## 7. Release compatibility

Run `validateSmartDebugger` on every MATLAB release that the engineering team supports. Record any API differences in the compatibility adapters rather than adding release-specific code to the GUI.

## Known runtime boundaries

Some Simulink signal classes and simulation modes do not expose the same logging capabilities. Smart Debugger must report a partial capture or unsupported signal rather than manufacture a value. MathWorks documents signal-logging limitations for several conditional/function-call/Stateflow cases.
