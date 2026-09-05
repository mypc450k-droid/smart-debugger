function report = validateSmartDebugger()
%VALIDATESMARTDEBUGGER Check the local MATLAB environment before debugging.
%   report = validateSmartDebugger returns a structure and prints a concise
%   readiness report. It does not modify or simulate a user model.

root=fileparts(mfilename('fullpath'));
addpath(genpath(root));

report=struct();
report.MATLAB=version;
report.HasSimulink=smartdebugger.CompatibilityManager.hasSimulink();
report.HasStateflow=smartdebugger.CompatibilityManager.hasStateflow();
report.HasTargetLink=smartdebugger.CompatibilityManager.hasTargetLink();
report.CoreFiles={ ...
    'SmartDebugger.m', ...
    '+smartdebugger/SmartDebuggerApp.m', ...
    '+smartdebugger/ModelManager.m', ...
    '+smartdebugger/SimulationManager.m', ...
    '+smartdebugger/ComparisonEngine.m', ...
    '+smartdebugger/TimeAlignmentEngine.m'};
report.MissingFiles={};
for k=1:numel(report.CoreFiles)
    if exist(fullfile(root,report.CoreFiles{k}),'file')~=2
        report.MissingFiles{end+1}=report.CoreFiles{k}; %#ok<AGROW>
    end
end

fprintf('\nSMART DEBUGGER SELF-CHECK\n');
fprintf('MATLAB: %s\n',report.MATLAB);
fprintf('Simulink: %s\n',localTF(report.HasSimulink));
fprintf('Stateflow: %s\n',localTF(report.HasStateflow));
fprintf('TargetLink: %s\n',localTF(report.HasTargetLink));
if isempty(report.MissingFiles)
    fprintf('Core files: PASS\n');
else
    fprintf('Core files: FAIL\n');
    fprintf('Missing: %s\n',strjoin(report.MissingFiles,', '));
end

if report.HasSimulink
    fprintf('Simulation execution: available for local validation\n');
else
    fprintf('Simulation execution: UNAVAILABLE (Simulink not detected)\n');
end
fprintf('\nNext step: run `results = runtests(''tests'')` for the non-model regression suite.\n\n');
end

function s=localTF(tf)
if tf, s='AVAILABLE'; else, s='NOT DETECTED'; end
end
