# Smart Debugger

A programmatic MATLAB `uifigure` application for non-destructive MIL/SIL debugging of Simulink models, with a capability-driven TargetLink native SIL path.

## What it does

- Detects the currently selected Simulink block.
- Inspects block metadata and compiled input/output port attributes without compiling on selection.
- Captures selected MIL/SIL input and output signals programmatically for an explicit debug run.
- Restores temporary Simulink logging instrumentation automatically after the run.
- Provides separate MIL and generic SIL workflows.
- Provides a TargetLink-native SIL runner that drives TargetLink production-code host SIL through the TargetLink API.
- Resolves a deep selected Simulink hierarchy to the TargetLink subsystem identifier instead of passing the Data Server full path to TargetLink code-generation APIs.
- Reads the latest TargetLink Data Server simulation through the installed `tlds` bridge when available.
- Does not add Scope, To Workspace, or TargetLink Sink blocks.
- Compares MIL and SIL inputs and outputs with absolute/relative tolerances.
- Aligns different MIL/SIL time vectors using linear, nearest, or zero-order-hold strategies.
- Reports the first observed divergence and plots the compared trace/error.
- Detects MATLAB, Simulink, Stateflow, Simulink Coder and TargetLink availability.
- Keeps Stateflow and TargetLink integration behind adapters so unsupported environments degrade cleanly.

## Important design choice

MIL functionality is kept separate from the TargetLink integration. TargetLink is accessed only through `TargetLinkAdapter` and `TargetLinkSILManager`. TargetLink release numbers are not hard-coded, so the integration is capability-driven rather than tied to TargetLink 24.1 only.

TargetLink provides integrated code generation, simulation and code-verification capabilities. Smart Debugger uses the installed TargetLink MATLAB API rather than attempting to reproduce TargetLink's code-generation engine. urldSPACE TargetLink product informationhttps://www.dspace.com/en/pub/home/products/sw/pcgs/targetlink.cfm

## Launch

From the repository root in MATLAB:

```matlab
addpath(genpath(pwd))
app = SmartDebugger;
```

## Normal MIL workflow

1. Click **Open MIL** and select the MIL model.
2. In Simulink, select exactly one block.
3. Click **Import**.
4. Confirm the selected block and port metadata.
5. Click **Run Debug** in MIL mode.
6. Select a captured row to plot it and use the arrow keys to move through actual samples.
7. For MIL/SIL comparison, run the SIL workflow and then click **Compare**.

## TargetLink native SIL workflow

The most reliable TargetLink-native entry point is:

```matlab
addpath(genpath(pwd))

result = smartdebugger.runTargetLinkSIL( ...
    'clap_A8_tl', ...
    'clap_A8_tl/FNC_clap_A8/clap_A8/Subsystem/clap_A8', ...
    'auto');
```

The target argument can be the deep path you see in Simulink. Smart Debugger resolves that hierarchy to the local TargetLink subsystem name before calling `tl_set_sim_mode`, `tl_generate_code`, `tl_build_host`/`tl_compile_host`, and `tl_sim`.

For the `clap_A8_tl` example, the Data Server hierarchy may be:

```text
clap_A8_tl/FNC_clap_A8/clap_A8/Subsystem/clap_A8
```

Smart Debugger resolves the hierarchy to the relevant local TargetLink subsystem name, such as `clap_A8`, rather than passing the complete Data Server hierarchy to `TlSubsystems`.

### What the native runner does

1. Detect TargetLink capabilities at runtime.
2. Load the model if required.
3. Resolve the requested hierarchy to a TargetLink subsystem name.
4. Select TargetLink host-code simulation mode when the API is available.
5. Generate production code for the resolved TargetLink subsystem.
6. Build/compile the host SIL implementation.
7. Run `tl_sim` without assuming a return value.
8. Read the latest TargetLink Data Server simulation using `tlds` when available.
9. Recursively normalize logged time-series data into runtime signal rows.
10. Return the raw Data Server payload plus normalized runtime signals and diagnostics.

No sink blocks are inserted by Smart Debugger.

### Important logging boundary

TargetLink can execute successfully while a particular Data Server simulation contains zero logged signals. Smart Debugger reports this as `SIMULATED_NO_DATA` rather than inventing values. Internal production-code variables can also be optimized away by TargetLink and therefore may not be observable unless TargetLink logging/observability settings make them available.

## TargetLink diagnostics

Run:

```matlab
r = smartdebugger.TargetLinkAdapter.inspectEnvironment();
disp(r)
```

This is read-only. It reports which TargetLink API capabilities are present without running code generation or simulation.

To inspect the TargetLink hierarchy without modifying the model, use the installed TargetLink API:

```matlab
mdl = bdroot;
hmdl = get_param(mdl,'Handle');
[hTL,types] = tl_get_blocks(hmdl,'AllInclSubsystems');

for k = 1:numel(hTL)
    fprintf('%4d %-100s %s\n',k,getfullname(hTL(k)),types{k});
end
```

`tl_get_blocks` expects Simulink handles, not a model-name string.

## Tests

Run the non-model regression tests with:

```matlab
addpath(genpath(pwd))
results = runtests('tests');
results
```

Simulation execution must be validated in the user's licensed MATLAB/Simulink/TargetLink installation because GitHub cannot execute those licensed products.

## Known boundaries

- TargetLink logging visibility depends on the active TargetLink logging configuration.
- Optimized-away generated-code variables are not guaranteed to be observable.
- Protected models and inaccessible generated-code internals are inspected only at their available interface boundary.
- Bus/struct-valued MIL data is recursively expanded by the existing MIL capture path.
- TargetLink Data Server payloads are normalized conservatively; arbitrary metadata is not claimed to be a runtime signal unless it has a usable numeric/logical series.

## Architecture

`SmartDebuggerApp` -> `ModelManager` -> `SimulationManager` -> `ComparisonEngine` -> `TimeAlignmentEngine`.

TargetLink is isolated behind `TargetLinkAdapter` and `TargetLinkSILManager`. This keeps the existing MIL execution/capture path independent from TargetLink-specific behavior.
