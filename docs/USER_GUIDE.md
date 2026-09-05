# User Guide

## Launch

From the repository root in MATLAB:

```matlab
SmartDebugger
```

## MIL workflow

1. Click **Open MIL** and select the `.slx`/`.mdl` model.
2. Select a block in the Simulink editor.
3. Click **Import Selection**.
4. Click **Inspect** to view ports and compiled metadata.
5. Select **MIL** and click **Debug**.
6. Inspect captured input/output tables and the time plot.

## SIL workflow

Enter the SIL model path, select **SIL**, then click **Debug**. Use a project-specific mapping when MIL and SIL internal paths differ. TargetLink availability is detected, but no private TargetLink API is assumed.

## Compare

Run MIL and SIL first. Click **Compare**. Set absolute and relative tolerances as required by the verification project. The comparison aligns timestamps before applying the tolerance.

## Selection fallback

If importing the current Simulink selection does not work in a particular MATLAB release, enter the full block path manually in the Selected block field.

## Truthfulness rule

An unavailable API is reported as unavailable. The application does not manufacture runtime values or claim arbitrary Stateflow/MATLAB Function internal-variable visibility that the installed release does not expose.
