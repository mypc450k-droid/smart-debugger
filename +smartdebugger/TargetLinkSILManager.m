classdef TargetLinkSILManager < handle
    %TARGETLINKSILMANAGER TargetLink-native SIL orchestration boundary.
    %
    % This class is deliberately isolated from SimulationManager. It uses
    % TargetLink APIs when they are present and never changes the MIL path.
    % API availability is discovered at runtime so newer TargetLink releases
    % can be supported without hard-coded version checks.

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
            if nargin<4 || isempty(stopTime), stopTime='auto'; else, stopTime=char(string(stopTime)); end
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
            if ~bdIsLoaded(localModelName(model))
                load_system(model);
            end

            originalStop='';
            restoreStop=false;
            try
                if ~strcmpi(stopTime,'auto')
                    originalStop=get_param(localModelName(model),'StopTime');
                    set_param(localModelName(model),'StopTime',stopTime);
                    restoreStop=true;
                end

                % TargetLink's documented SIL preparation sequence.
                if caps.SetSimMode
                    obj.Adapter.setSimulationMode(model,subsystem,'TL_CODE_HOST');
                end
                if caps.BuildHost
                    obj.Adapter.buildHost(model,subsystem);
                end
                if ~caps.Sim
                    error('SmartDebugger:TargetLinkSILUnavailable', ...
                        'TargetLink tl_sim is not available in this MATLAB session.');
                end

                result.Message=obj.Adapter.simulate(model,subsystem);
                result.Status='SIMULATED';
                result.DataSource='TargetLink Data Server';

                if caps.AccessLogData
                    [data,ok,msg]=obj.Adapter.accessLogData(model,subsystem);
                    result.RawLogData=data;
                    result.LogDataAvailable=ok;
                    if ~ok
                        result.Status='SIMULATED_NO_DATA';
                        result.Message=[result.Message ' TargetLink simulation completed, but logged data could not be read automatically: ' msg];
                    else
                        result.Status='PASS';
                        result.RuntimeSignals=obj.normalizeLogData(data);
                    end
                else
                    result.Status='SIMULATED_NO_DATA';
                    result.Message=[result.Message ' TargetLink Data Server API tl_access_logdata is not available.'];
                end
            catch ME
                result.Status='ERROR';
                result.Message=ME.message;
                result.ErrorIdentifier=ME.identifier;
            end
            if restoreStop
                try, set_param(localModelName(model),'StopTime',originalStop); catch, end
            end
        end

        function report=diagnose(obj)
            report=obj.Adapter.inspectEnvironment();
        end
    end

    methods (Access=private)
        function result=emptyResult(~,model,subsystem,stopTime)
            result=struct('Status','NOT_RUN','Message','','ErrorIdentifier','', ...
                'Model',model,'Subsystem',subsystem,'StopTime',stopTime, ...
                'Capabilities',struct(),'DataSource','','RawLogData',[], ...
                'LogDataAvailable',false,'RuntimeSignals',struct([]));
        end

        function rows=normalizeLogData(~,data)
            % Preserve the raw TargetLink payload and expose a conservative
            % normalized view. TargetLink Data Server payload shapes vary by
            % release, so no private structure is assumed here.
            rows=struct('Name',{},'Time',{},'Data',{},'DataType',{},'Dimension',{});
            if isempty(data), return; end
            if isstruct(data)
                names=fieldnames(data);
                for k=1:numel(names)
                    v=data.(names{k});
                    if istimetable(v)
                        rows(end+1)=localRow(names{k},v.Properties.RowTimes,v{:,:}); %#ok<AGROW>
                    elseif isa(v,'timeseries')
                        rows(end+1)=localRow(names{k},v.Time,v.Data); %#ok<AGROW>
                    elseif isstruct(v)
                        nested=smartdebugger.TargetLinkSILManager().normalizeLogData(v);
                        rows=[rows; nested(:)]; %#ok<AGROW>
                    end
                end
            elseif isa(data,'timeseries')
                rows=localRow(inputname(1),data.Time,data.Data);
            end
        end
    end
end

function name=localModelName(model)
[~,name,ext]=fileparts(model);
if isempty(ext), name=model; end
end

function r=localRow(name,time,data)
r=struct('Name',char(string(name)),'Time',time,'Data',data,'DataType',class(data),'Dimension',size(data));
end
