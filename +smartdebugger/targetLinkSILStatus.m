function report=targetLinkSILStatus(block)
%TARGETLINKSILSTATUS Inspect TargetLink SIL capabilities without running SIL.
%   REPORT = smartdebugger.targetLinkSILStatus()
%   REPORT = smartdebugger.targetLinkSILStatus(BLOCK)
%
% This command performs capability discovery only. It does not compile,
% change model settings, run a simulation, or modify logging configuration.
if nargin<1, block=''; end
report=smartdebugger.TargetLinkAdapter.inspectEnvironment();
if ~isempty(strtrim(char(string(block))))
    report.Block=char(string(block));
    report.BlockInfo=smartdebugger.TargetLinkAdapter.inspect(block);
else
    report.Block='';
    report.BlockInfo=[];
end
end
