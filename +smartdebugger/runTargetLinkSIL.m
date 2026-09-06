function result=runTargetLinkSIL(model,subsystem,stopTime)
%RUNTARGETLINKSIL Run TargetLink production-code SIL and extract Data Server data.
%
%   RESULT = smartdebugger.runTargetLinkSIL(MODEL,SUBSYSTEM)
%   RESULT = smartdebugger.runTargetLinkSIL(MODEL,SUBSYSTEM,STOPTIME)
%
% MODEL is the TargetLink frame/model name or path.
% SUBSYSTEM may be the selected/deep Simulink path, a TargetLink software-unit
% subsystem path, or the local TargetLink subsystem name. Smart Debugger resolves
% a full hierarchy to the TargetLink identifier expected by its API.
% STOPTIME is optional and may be 'auto'.
%
% The command does not add Scope/To Workspace/TargetLink Sink blocks. It uses
% TargetLink host SIL APIs and reads the latest stored simulation through the
% installed TargetLink Data Server bridge.

if nargin<1 || isempty(model)
    error('SmartDebugger:TargetLinkModelRequired','TargetLink model/frame is required.');
end
if nargin<2 || isempty(subsystem)
    error('SmartDebugger:TargetLinkSubsystemRequired','TargetLink subsystem/block path or name is required.');
end
if nargin<3
    stopTime='auto';
end

manager=smartdebugger.TargetLinkSILManager();
result=manager.run(model,subsystem,stopTime);

fprintf('\n=== Smart Debugger TargetLink SIL ===\n');
fprintf('Status             : %s\n',result.Status);
fprintf('Model              : %s\n',result.Model);
fprintf('Requested target   : %s\n',result.Subsystem);
fprintf('Resolved TL target : %s\n',result.ResolvedSubsystem);
fprintf('Resolution         : %s / %s\n',result.MappingMethod,result.MappingConfidence);
fprintf('Data source        : %s\n',result.DataSource);
fprintf('Data access        : %s\n',result.DataAccessMethod);
fprintf('Signal count       : %d\n',result.SignalCount);
fprintf('Message            : %s\n',result.Message);

if ~isempty(result.RuntimeSignals)
    fprintf('\nRuntime signals:\n');
    for k=1:numel(result.RuntimeSignals)
        r=result.RuntimeSignals(k);
        fprintf('  %3d  %-55s  samples=%d  type=%s\n', ...
            k,r.Name,numel(r.Time),r.DataType);
    end
end

if strcmpi(result.Status,'ERROR')
    error('SmartDebugger:TargetLinkSILFailed','TargetLink SIL failed: %s',result.Message);
end
end
