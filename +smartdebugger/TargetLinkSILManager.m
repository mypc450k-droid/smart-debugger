classdef TargetLinkSILManager < handle
    %TARGETLINKSILMANAGER TargetLink-native SIL orchestration.
    % Existing TargetLink generated/host code is reused by default.
    properties (SetAccess=private)
        Adapter
    end
    methods
        function obj=TargetLinkSILManager(adapter)
            if nargin<1 || isempty(adapter), adapter=smartdebugger.TargetLinkAdapter(); end
            obj.Adapter=adapter;
        end
        function result=run(obj,model,subsystem,stopTime,varargin)
            model=char(string(model)); subsystem=char(string(subsystem));
            if nargin<4 || isempty(stopTime), stopTime='auto'; else, stopTime=char(string(stopTime)); end
            regenerate=(nargin>=5 && ~isempty(varargin{1}) && logical(varargin{1}));
            result=obj.emptyResult(model,subsystem,stopTime,regenerate);
            caps=obj.Adapter.discoverCapabilities(); result.Capabilities=caps;
            if ~caps.TargetLinkDetected, result.Status='ERROR'; result.Message='TargetLink was not detected in the current MATLAB session.'; return; end
            if isempty(model), result.Status='ERROR'; result.Message='A TargetLink model/frame is required for SIL.'; return; end
            if isempty(subsystem), result.Status='ERROR'; result.Message='A TargetLink software unit is required for SIL.'; return; end
            mdl=localModelName(model); tlModel=mdl;
            if ~bdIsLoaded(mdl), load_system(mdl); end; open_system(mdl);
            % Prefer TargetLink Data Server software-unit metadata when it
            % contains an ancestor of the selected deep Simulink path. This
            % avoids mistaking an ordinary internal subsystem such as
            % Error_state_update for the actual TargetLink software unit.
            [tlSubsystem,resolveInfo]=localResolveFromTLDS(model,subsystem);
            if isempty(tlSubsystem)
                [tlSubsystem,resolveInfo]=obj.Adapter.resolveSubsystem(model,subsystem);
            end
            result.ResolvedSubsystem=tlSubsystem; result.MappingMethod=resolveInfo.Method; result.MappingConfidence=resolveInfo.Confidence; result.MappingCandidates=resolveInfo.Candidates;
            if isempty(tlSubsystem), result.Status='ERROR'; result.Message=resolveInfo.Message; return; end
            originalStop=''; restoreStop=false;
            try
                if ~strcmpi(stopTime,'auto'), originalStop=get_param(mdl,'StopTime'); set_param(mdl,'StopTime',stopTime); restoreStop=true; end
                if caps.SetSimMode
                    obj.Adapter.setSimulationMode(tlModel,tlSubsystem,'TL_CODE_HOST');
                end
                if regenerate
                    result.CodeGenerationMode='REGENERATE';
                    if caps.GenerateCode, obj.Adapter.generateCode(tlModel,tlSubsystem); end
                    if caps.BuildHost, obj.Adapter.buildHost(tlModel,tlSubsystem); elseif caps.CompileHost, obj.Adapter.compileHost(tlModel,tlSubsystem); else, error('SmartDebugger:TargetLinkHostBuildUnavailable','TargetLink host build/compile API is not available.'); end
                else
                    result.CodeGenerationMode='REUSE_EXISTING';
                end
                if ~caps.Sim, error('SmartDebugger:TargetLinkSimulationUnavailable','TargetLink tl_sim is not available in this MATLAB session.'); end
                result.Message=obj.Adapter.simulate(tlModel,tlSubsystem); result.Status='SIMULATED'; result.DataSource='TargetLink Data Server';
                if caps.AccessLogData || caps.TLDS
                    [data,ok,msg,method]=obj.Adapter.accessLogData(tlModel,tlSubsystem); result.RawLogData=data; result.LogDataAvailable=ok; result.DataAccessMethod=method;
                    if ~ok
                        result.Status='SIMULATED_NO_DATA'; result.Message=[result.Message ' Runtime data extraction failed: ' msg];
                    else
                        result.Status='PASS'; result.Message=[result.Message ' ' msg]; result.RuntimeSignals=obj.normalizeLogData(data); result.SignalCount=numel(result.RuntimeSignals);
                        if result.SignalCount==0, result.Status='SIMULATED_NO_DATA'; result.Message=[result.Message ' No readable runtime signal series were found.']; end
                    end
                else
                    result.Status='SIMULATED_NO_DATA'; result.Message=[result.Message ' TargetLink Data Server access is unavailable.'];
                end
            catch ME
                result.Status='ERROR'; result.Message=ME.message; result.ErrorIdentifier=ME.identifier; result.ErrorReport=getReport(ME,'basic','hyperlinks','off');
            end
            if restoreStop, try, set_param(mdl,'StopTime',originalStop); catch, end, end
        end
        function report=diagnose(obj), report=obj.Adapter.inspectEnvironment(); end
    end
    methods (Access=private)
        function result=emptyResult(~,model,subsystem,stopTime,regenerate)
            if regenerate, mode='REGENERATE'; else, mode='REUSE_EXISTING'; end
            result=struct('Status','NOT_RUN','Message','','ErrorIdentifier','','ErrorReport','','Model',model,'Subsystem',subsystem,'ResolvedSubsystem','', ...
                'MappingConfidence','NONE','MappingMethod','NONE','MappingCandidates',{{}},'StopTime',stopTime,'Capabilities',struct(),'CodeGenerationMode',mode, ...
                'DataSource','','DataAccessMethod','','RawLogData',[],'LogDataAvailable',false,'RuntimeSignals',struct([]),'SignalCount',0);
        end
        function rows=normalizeLogData(~,data), rows=localNormalize(data,''); end
    end
end

function [resolved,info]=localResolveFromTLDS(model,requested)
resolved='';
info=struct('Requested',requested,'Resolved','','Method','NONE','Confidence','NONE','Candidates',{{}},'Message','');
if isempty(which('tlds')) || isempty(strtrim(requested)), return; end
try
    simulations=feval('tlds',0,'get','simulations');
catch
    return
end
if isempty(simulations), return; end
items=localSimulationItemsNewestFirst(simulations);
requested=char(string(requested));
modelName=localModelName(model);
best='';
bestPath='';
for i=1:numel(items)
    item=items{i};
    if ~isstruct(item), continue; end
    if isfield(item,'system') && ~isempty(item.system)
        sys=char(string(item.system));
        [~,sysName]=fileparts(sys);
        if ~strcmpi(sys,modelName) && ~strcmpi(sysName,modelName)
            continue
        end
    end
    if ~isfield(item,'TLSubSystems') || isempty(item.TLSubSystems), continue; end
    tlss=item.TLSubSystems;
    if iscell(tlss), tlss=[tlss{:}]; end
    if ~isstruct(tlss), continue; end
    for k=1:numel(tlss)
        if ~isfield(tlss(k),'name') || isempty(tlss(k).name), continue; end
        p=char(string(tlss(k).name));
        if localPathIsAncestorOrEqual(p,requested) && numel(p)>numel(bestPath)
            bestPath=p; best=localLeafName(p);
        end
    end
    if ~isempty(best), break; end
end
if isempty(best), return; end
resolved=best;
info.Resolved=resolved;
info.Method='TLDS_SUBSYSTEM_METADATA';
info.Confidence='VERY_HIGH';
info.Candidates={bestPath};
info.Message=['Resolved selected TargetLink path to software unit from TargetLink Data Server metadata: ' resolved];
end

function items=localSimulationItemsNewestFirst(simulations)
items={};
if iscell(simulations)
    for k=numel(simulations):-1:1, items{end+1}=simulations{k}; end %#ok<AGROW>
elseif isstruct(simulations)
    for k=numel(simulations):-1:1, items{end+1}=simulations(k); end %#ok<AGROW>
elseif isstring(simulations) || ischar(simulations)
    items={simulations};
end
end

function leaf=localLeafName(path)
parts=regexp(char(string(path)),'/','split');
if isempty(parts), leaf=char(string(path)); else, leaf=parts{end}; end
end

function rows=localNormalize(data,prefix)
rows=struct('Name',{},'Time',{},'Data',{},'DataType',{},'Dimension',{},'SourcePath',{}); if isempty(data), return; end
if isa(data,'timeseries'), rows(end+1)=localRow(localName(prefix,'timeseries'),data.Time,data.Data,prefix); return; end
if istimetable(data), rows(end+1)=localRow(localName(prefix,'timetable'),data.Properties.RowTimes,data{:,:},prefix); return; end
if istable(data)
    vars=data.Properties.VariableNames; time=[];
    for k=1:numel(vars), if any(strcmpi(vars{k},{'time','timestamp','timestamps'})), time=data.(vars{k}); break; end, end
    for k=1:numel(vars), v=data.(vars{k}); if isempty(time)&&isnumeric(v)&&isvector(v), time=(0:numel(v)-1).'; end; if ~any(strcmpi(vars{k},{'time','timestamp','timestamps'}))&&(isnumeric(v)||islogical(v)), rows(end+1)=localRow(localName(prefix,vars{k}),time,v,localName(prefix,vars{k})); end, end
    return
end
if isstruct(data)
    names=fieldnames(data);
    for n=1:numel(data), for k=1:numel(names), name=names{k}; v=data(n).(name); p=localName(prefix,name); if isa(v,'timeseries')||istimetable(v)||istable(v), rows=[rows;localNormalize(v,p)]; elseif isstruct(v), rows=[rows;localNormalize(v,p)]; elseif isnumeric(v)||islogical(v), if ~isempty(v)&&numel(v)>1, rows(end+1)=localRow(p,localSiblingTime(data(n),name,numel(v)),v,p); end, end, end, end
    return
end
if isnumeric(data)||islogical(data), rows(end+1)=localRow(localName(prefix,'data'),(0:size(data,1)-1).',data,prefix); end
end
function t=localSiblingTime(s,signalName,n)
t=[]; names=fieldnames(s); for k=1:numel(names), name=names{k}; if strcmp(name,signalName), continue; end, v=s.(name); if isnumeric(v)&&isvector(v)&&numel(v)==n&&any(strcmpi(name,{'time','times','timestamp','timestamps'})), t=v; return; end, end; if isempty(t), t=(0:n-1).'; end
end
function r=localRow(name,time,data,path), r=struct('Name',char(string(name)),'Time',time,'Data',data,'DataType',class(data),'Dimension',size(data),'SourcePath',char(string(path))); end
function out=localName(prefix,name), if isempty(prefix), out=char(string(name)); else, out=[prefix '.' char(string(name))]; end, end
function name=localModelName(model), model=char(string(model)); [~,name,ext]=fileparts(model); if isempty(ext), name=model; end, end
function tf=localPathIsAncestorOrEqual(candidate,requested)
candidate=char(string(candidate)); requested=char(string(requested)); tf=strcmp(candidate,requested) || startsWith([requested '/'],[candidate '/']);
end
