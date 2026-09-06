classdef TargetLinkSILManager < handle
    %TARGETLINKSILMANAGER TargetLink-native SIL orchestration.
    %
    % Runs the production-code SIL path through TargetLink and retrieves the
    % resulting TargetLink Data Server simulation without modifying the MIL
    % execution path.

    properties (SetAccess=private)
        Adapter
    end

    methods
        function obj=TargetLinkSILManager(adapter)
            if nargin<1 || isempty(adapter)
                adapter=smartdebugger.TargetLinkAdapter();
            end
            obj.Adapter=adapter;
        end

        function result=run(obj,model,subsystem,stopTime)
            model=char(string(model));
            subsystem=char(string(subsystem));
            if nargin<4 || isempty(stopTime)
                stopTime='auto';
            else
                stopTime=char(string(stopTime));
            end
            result=obj.emptyResult(model,subsystem,stopTime);
            caps=obj.Adapter.discoverCapabilities();
            result.Capabilities=caps;

            if ~caps.TargetLinkDetected
                result.Status='ERROR';
                result.Message='TargetLink was not detected in the current MATLAB session.';
                return
            end
            if isempty(model)
                result.Status='ERROR';
                result.Message='A TargetLink model/frame is required for SIL.';
                return
            end
            if isempty(subsystem)
                result.Status='ERROR';
                result.Message='A TargetLink subsystem/block path is required for SIL.';
                return
            end

            mdl=localModelName(model);
            if ~bdIsLoaded(mdl)
                load_system(mdl);
            end

            originalStop='';
            restoreStop=false;
            try
                if ~strcmpi(stopTime,'auto')
                    originalStop=get_param(mdl,'StopTime');
                    set_param(mdl,'StopTime',stopTime);
                    restoreStop=true;
                end

                if caps.SetSimMode
                    obj.Adapter.setSimulationMode(model,subsystem,'TL_CODE_HOST');
                end

                if caps.GenerateCode
                    obj.Adapter.generateCode(model,subsystem);
                end

                if caps.BuildHost
                    obj.Adapter.buildHost(model,subsystem);
                elseif caps.CompileHost
                    obj.Adapter.compileHost(model,subsystem);
                else
                    error('SmartDebugger:TargetLinkHostBuildUnavailable', ...
                        'TargetLink host build/compile API is not available.');
                end

                if ~caps.Sim
                    error('SmartDebugger:TargetLinkSimulationUnavailable', ...
                        'TargetLink tl_sim is not available in this MATLAB session.');
                end

                result.Message=obj.Adapter.simulate(model,subsystem);
                result.Status='SIMULATED';
                result.DataSource='TargetLink Data Server';

                if caps.AccessLogData || caps.TLDS
                    [data,ok,msg,method]=obj.Adapter.accessLogData(model,subsystem);
                    result.RawLogData=data;
                    result.LogDataAvailable=ok;
                    result.DataAccessMethod=method;
                    if ~ok
                        result.Status='SIMULATED_NO_DATA';
                        result.Message=[result.Message ' TargetLink SIL completed, but runtime data could not be extracted: ' msg];
                    else
                        result.Status='PASS';
                        result.Message=[result.Message ' ' msg];
                        result.RuntimeSignals=obj.normalizeLogData(data);
                        result.SignalCount=numel(result.RuntimeSignals);
                    end
                else
                    result.Status='SIMULATED_NO_DATA';
                    result.Message=[result.Message ' TargetLink Data Server access is unavailable.'];
                end
            catch ME
                result.Status='ERROR';
                result.Message=ME.message;
                result.ErrorIdentifier=ME.identifier;
                result.ErrorReport=getReport(ME,'basic','hyperlinks','off');
            end

            if restoreStop
                try, set_param(mdl,'StopTime',originalStop); catch, end
            end
        end

        function report=diagnose(obj)
            report=obj.Adapter.inspectEnvironment();
        end
    end

    methods (Access=private)
        function result=emptyResult(~,model,subsystem,stopTime)
            result=struct( ...
                'Status','NOT_RUN', ...
                'Message','', ...
                'ErrorIdentifier','', ...
                'ErrorReport','', ...
                'Model',model, ...
                'Subsystem',subsystem, ...
                'StopTime',stopTime, ...
                'Capabilities',struct(), ...
                'DataSource','', ...
                'DataAccessMethod','', ...
                'RawLogData',[], ...
                'LogDataAvailable',false, ...
                'RuntimeSignals',struct([]), ...
                'SignalCount',0);
        end

        function rows=normalizeLogData(~,data)
            rows=localNormalize(data,'');
        end
    end
end

function rows=localNormalize(data,prefix)
rows=struct('Name',{},'Time',{},'Data',{},'DataType',{},'Dimension',{},'SourcePath',{});
if isempty(data), return; end

if isa(data,'timeseries')
    rows(end+1)=localRow(localName(prefix,'timeseries'),data.Time,data.Data,prefix); %#ok<AGROW>
    return
end
if istimetable(data)
    rows(end+1)=localRow(localName(prefix,'timetable'),data.Properties.RowTimes,data{:,:},prefix); %#ok<AGROW>
    return
end
if istable(data)
    vars=data.Properties.VariableNames;
    time=[];
    for k=1:numel(vars)
        if any(strcmpi(vars{k},{'time','timestamp','timestamps'}))
            time=data.(vars{k});
            break
        end
    end
    for k=1:numel(vars)
        v=data.(vars{k});
        if isempty(time) && isnumeric(v) && isvector(v)
            time=(0:numel(v)-1).';
        end
        if ~any(strcmp(vars{k},{'time','timestamp','timestamps'})) && (isnumeric(v) || islogical(v))
            rows(end+1)=localRow(localName(prefix,vars{k}),time,v,localName(prefix,vars{k})); %#ok<AGROW>
        end
    end
    return
end

if isstruct(data)
    names=fieldnames(data);
    for n=1:numel(data)
        for k=1:numel(names)
            name=names{k};
            v=data(n).(name);
            p=localName(prefix,name);
            if isa(v,'timeseries') || istimetable(v) || istable(v)
                nested=localNormalize(v,p);
                rows=[rows; nested(:)]; %#ok<AGROW>
            elseif isstruct(v)
                nested=localNormalize(v,p);
                rows=[rows; nested(:)]; %#ok<AGROW>
            elseif isnumeric(v) || islogical(v)
                if ~isempty(v) && numel(v)>1
                    t=localSiblingTime(data(n),name,numel(v));
                    rows(end+1)=localRow(p,t,v,p); %#ok<AGROW>
                end
            end
        end
    end
    return
end

if isnumeric(data) || islogical(data)
    rows(end+1)=localRow(localName(prefix,'data'),(0:size(data,1)-1).',data,prefix); %#ok<AGROW>
end
end

function t=localSiblingTime(sibling,signalName,n)
t=[];
names=fieldnames(sibling);
for k=1:numel(names)
    name=names{k};
    if strcmp(name,signalName), continue; end
    v=sibling.(name);
    if isnumeric(v) && isvector(v) && numel(v)==n && any(strcmpi(name,{'time','times','timestamp','timestamps'}))
        t=v;
        return
    end
end
if isempty(t)
    t=(0:n-1).';
end
end

function r=localRow(name,time,data,path)
r=struct('Name',char(string(name)), ...
    'Time',time, ...
    'Data',data, ...
    'DataType',class(data), ...
    'Dimension',size(data), ...
    'SourcePath',char(string(path)));
end

function out=localName(prefix,name)
name=char(string(name));
if isempty(prefix)
    out=name;
else
    out=[prefix '.' name];
end
end

function name=localModelName(model)
[~,name,ext]=fileparts(model);
if isempty(ext), name=model; end
end
