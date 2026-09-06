function result=runTargetLinkSIL(model,subsystem,stopTime)
%RUNTARGETLINKSIL Run TargetLink production-code SIL and extract Data Server data.
%
%   RESULT = smartdebugger.runTargetLinkSIL(MODEL,SUBSYSTEM)
%   RESULT = smartdebugger.runTargetLinkSIL(MODEL,SUBSYSTEM,STOPTIME)
%
% MODEL is the TargetLink frame/model name or path.
% SUBSYSTEM is the exact TargetLink subsystem/block path to execute.
% STOPTIME is optional and may be 'auto'.
%
% The command does not modify the MIL path or add sink blocks. It uses the
% TargetLink SIL APIs and then reads the latest stored simulation from the
% TargetLink Data Server through the available TLDS bridge.

if nargin<1 || isempty(model)
    error('SmartDebugger:TargetLinkModelRequired','TargetLink model/frame is required.');
end
if nargin<2 || isempty(subsystem)
    error('SmartDebugger:TargetLinkSubsystemRequired','TargetLink subsystem/block path is required.');
end
if nargin<3
    stopTime='auto';
end

manager=smartdebugger.TargetLinkSILManager();
result=manager.run(model,subsystem,stopTime);

fprintf('\n=== Smart Debugger TargetLink SIL ===\n');
fprintf('Status       : %s\n',result.Status);
fprintf('Model        : %s\n',result.Model);
fprintf('Subsystem    : %s\n',result.Subsystem);
fprintf('Data source  : %s\n',result.DataSource);
fprintf('Data access  : %s\n',result.DataAccessMethod);
fprintf('Signal count : %d\n',result.SignalCount);
fprintf('Message      : %s\n',result.Message);

if strcmpi(result.Status,'PASS') && ~isempty(result.RuntimeSignals)
    fprintf('\nRuntime signals:\n');
    for k=1:numel(result.RuntimeSignals)
        r=result.RuntimeSignals(k);
        fprintf('  %3d  %-45s  samples=%d  type=%s\n', ...
            k,r.Name,numel(r.Time),r.DataType);
    end
end

if strcmpi(result.Status,'ERROR')
    error('SmartDebugger:TargetLinkSILFailed','TargetLink SIL failed: %s',result.Message);
end
end
