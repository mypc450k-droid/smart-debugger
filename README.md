# Smart Debugger

A programmatic MATLAB `uifigure` application for non-destructive MIL/SIL debugging of Simulink models.

## What it does

- Detects the currently selected Simulink block.
- Inspects block metadata and compiled input/output port attributes.
- Captures selected input and output signals programmatically for one debug run.
- Restores temporary logging instrumentation automatically after the run.
- Provides separate MIL and SIL workflows.
- Maps a MIL block to a SIL block using relative path and unique-name strategies.
- Compares MIL and SIL inputs and outputs with absolute/relative tolerances.
- Aligns different MIL/SIL time vectors using linear, nearest, or zero-order-hold strategies.
- Reports the first observed divergence and plots the compared trace/error.
- Detects MATLAB, Simulink, Stateflow, Simulink Coder and TargetLink availability.
- Keeps Stateflow and TargetLink integration behind adapters so unsupported environments degrade cleanly.

## Important design choice

Smart Debugger does not require the engineer to manually place Scope, To Workspace, or TargetLink Sink blocks. It uses temporary programmatic signal logging on the selected signal lines and restores the original logging properties when the operation finishes. MathWorks documents programmatic signal logging and access to `SimulationOutput.logsout` as supported Simulink workflows.

## Launch

From the repository root in MATLAB:

```matlab
addpath(genpath(pwd))
app = SmartDebugger;
```

## Normal workflow

1. Click **Open MIL** and select the MIL model.
2. In Simulink, select exactly one block.
3. Click **Import**. The app also watches the Simulink selection automatically.
4. Confirm the selected block and compiled port metadata.
5. Click **Run Debug** in MIL mode.
6. For SIL, click **Open SIL**, select the SIL model, switch the mode to **SIL**, and run again.
7. If automatic mapping is ambiguous, enter the SIL block path in **SIL mapped block (optional override)**.
8. Click **Compare**.
9. Inspect the comparison table, first divergence, and trace plot.

## SIL / TargetLink

The SIL model is treated as a separate implementation model. The application does not assume MIL and SIL have identical hierarchy. TargetLink-specific behavior is isolated behind `TargetLinkAdapter`; a TargetLink installation is not required for the generic application path.

If your SIL environment is a TargetLink S-Function model, select the corresponding SIL block or provide its path as the explicit override. The application does not replace or modify the TargetLink-generated S-Function.

## Tests

Run the non-model regression tests with:

```matlab
addpath(genpath(pwd))
results = runtests('tests');
results
```

The tests cover tolerance handling, first divergence, input/output comparison and time alignment.

## MATLAB / Simulink requirement

The repository cannot execute licensed MATLAB/Simulink inside GitHub. Therefore simulation execution must be validated in the user's MATLAB installation. The source is intentionally written to documented Simulink/Stateflow APIs with capability detection and explicit diagnostics rather than fabricating runtime behavior.

## Known boundaries

- Runtime logging support varies by simulation mode and signal type. When a selected signal cannot be captured, the app reports partial capture instead of inventing a value.
- Arbitrary local variables inside MATLAB Function blocks are not exposed unless the active MATLAB debugging/runtime API supports them. The primary supported interface is block inputs/outputs.
- Protected models and inaccessible generated-code internals are inspected at their available interface boundary.
- Bus/struct-valued runtime data requires recursive signal handling and is reported as unsupported by the current numeric comparison engine rather than silently flattening it.

## Architecture

`SmartDebuggerApp` -> `ModelManager` -> `SimulationManager` -> `ComparisonEngine` -> `TimeAlignmentEngine`.

Stateflow, TargetLink, model mapping, scaling, diagnostics and compatibility concerns are isolated into separate services/adapters so future MATLAB releases can be supported without rewriting the UI.
