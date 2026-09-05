classdef SimulationManager < handle
    %SIMULATIONMANAGER Run MIL/SIL simulations and capture selected ports.
    properties (SetAccess=private)
        Diagnostics
    end
    methods
        function obj = SimulationManager(diag)
            obj.Diagnostics = diag;
        end
        function result = runMIL(obj,model,block,stopTime)
            result = obj.run(model,block,stopTime,'MIL');
        end
        function result = runSIL(obj,model,block,stopTime)
            result = obj.run(model,block,stopTime,'SIL');
        end
    end
    methods (Access=private)
        function result = run(obj,model,block,stopTime,mode)
            model=char(string(model)); block=char(string(block)); stopTime=char(string(stopTime));
            result=struct('Mode',mode,'Model',model,'Block',block,'Time',[], ...
                'Inputs',[],'Outputs',[],'SimulationOutput',[],'Status','FAILED','Message','');
            tx=smartdebugger.TransactionManager();
            cleanup=onCleanup(@()tx.restore()); %#ok<NASGU>
            try
                load_system(model);
                get_param(block,'Handle');
                set_param(model,'SimulationCommand','update');

                inputs=obj.instrumentPorts(block,'Inport',tx);
                outputs=obj.instrumentPorts(block,'Outport',tx);

                % sim name-value arguments override configuration for this run
                % and are reverted by Simulink after completion.
                simOut=sim(model,'StopTime',stopTime, ...
                    'SignalLogging','on','SignalLoggingName','logsout', ...
                    'ReturnWorkspaceOutputs','on');

                logs=obj.getLogs(simOut);
                result.Inputs=obj.readLogged(logs,inputs);
                result.Outputs=obj.readLogged(logs,outputs);
                result.Time=obj.findCommonTime(result);
                result.SimulationOutput=simOut;
                result.Status='PASS';
                if isempty(logs)
                    result.Status='PARTIAL';
                    result.Message=['Simulation completed but logsout was not returned. ' ...
                        'The selected port may not support runtime logging in this mode.'];
                    obj.Diagnostics.record('WARNING',[mode ' capture'],result.Message,'SmartDebugger:NoLogsout');
                end
            catch ME
                result.Message=ME.message;
                obj.Diagnostics.recordException(ME,[mode ' simulation']);
                rethrow(ME);
            end
        end

        function logs=getLogs(~,simOut)
            logs=[];
            if isempty(simOut), return; end
            try
                if isprop(simOut,'logsout'), logs=simOut.logsout; end
            catch
            end
            if isempty(logs)
                try, logs=simOut.get('logsout'); catch, end
            end
        end

        function ports=instrumentPorts(obj,block,direction,tx)
            template=struct('Port',0,'Name','','LogName','','Value',[], ...
                'DataType','','Dimension','','SampleTime','','Series',[], ...
                'LineHandle',-1,'SignalHandle',-1,'LoggingHandle',-1);
            ports=repmat(template,0,1);
            ph=get_param(block,'PortHandles');
            if strcmpi(direction,'Inport')
                hs=ph.Inport; displayDirection='Input';
            else
                hs=ph.Outport; displayDirection='Output';
            end

            loggingHandles=[];
            loggingNames={};
            for k=1:numel(hs)
                p=template; p.Port=k; p.SignalHandle=hs(k);
                p.Name=sprintf('%s %d',displayDirection,k);
                try, p.LineHandle=get_param(hs(k),'Line'); catch, p.LineHandle=-1; end
                if p.LineHandle==-1
                    ports(end+1)=p; %#ok<AGROW>
                    continue;
                end
                try
                    p.Name=smartdebugger.SignalNameResolver.resolve(p.LineHandle,k,displayDirection);
                catch
                end

                % Log the source output port that produces the selected signal.
                % This is the documented programmatic signal-logging interface.
                try
                    srcPort=get_param(p.LineHandle,'SrcPortHandle');
                catch
                    srcPort=-1;
                end
                if isempty(srcPort) || srcPort==-1
                    ports(end+1)=p; %#ok<AGROW>
                    continue;
                end
                p.LoggingHandle=srcPort;

                % Reuse one logging name when several selected inputs are fed by
                % the same source signal.
                existing=find(loggingHandles==srcPort,1);
                if isempty(existing)
                    p.LogName=matlab.lang.makeValidName(sprintf( ...
                        'SmartDebugger_%s_%03d',lower(displayDirection),k));
                    loggingHandles(end+1)=srcPort; %#ok<AGROW>
                    loggingNames{end+1}=p.LogName; %#ok<AGROW>
                    tx.record(srcPort,'DataLogging',safeGetParam(srcPort,'DataLogging','off'));
                    tx.record(srcPort,'DataLoggingNameMode',safeGetParam(srcPort,'DataLoggingNameMode','SignalName'));
                    tx.record(srcPort,'DataLoggingName',safeGetParam(srcPort,'DataLoggingName',''));
                    set_param(srcPort,'DataLoggingNameMode','Custom');
                    set_param(srcPort,'DataLoggingName',p.LogName);
                    set_param(srcPort,'DataLogging','on');
                else
                    p.LogName=loggingNames{existing};
                end
                ports(end+1)=p; %#ok<AGROW>
            end
        end

        function ports=readLogged(obj,logs,ports)
            if isempty(ports), return; end
            for k=1:numel(ports)
                if isempty(ports(k).LogName) || isempty(logs), continue; end
                try
                    element=logs.getElement(ports(k).LogName);
                    ts=element.Values;
                    ports(k).Series=ts;
                    if isprop(ts,'Data')
                        data=ts.Data;
                        ports(k).Value=localLastSample(data);
                        ports(k).DataType=class(data);
                        ports(k).Dimension=mat2str(size(data));
                    end
                    if isprop(ts,'Time') && ~isempty(ts.Time)
                        ports(k).SampleTime=localSampleTime(ts.Time);
                    end
                catch ME
                    obj.Diagnostics.recordException(ME,['Read logged signal ' ports(k).LogName]);
                end
            end
        end

        function t=findCommonTime(~,result)
            t=[]; allPorts=[result.Inputs result.Outputs];
            for k=1:numel(allPorts)
                try
                    if ~isempty(allPorts(k).Series) && isprop(allPorts(k).Series,'Time')
                        t=allPorts(k).Series.Time(:); return;
                    end
                catch
                end
            end
        end
    end
end

function value=safeGetParam(handle,param,defaultValue)
try, value=get_param(handle,param); catch, value=defaultValue; end
end

function value=localLastSample(data)
if isempty(data), value=[]; return; end
subs=repmat({':'},1,ndims(data));
subs{1}=size(data,1);
value=data(subs{:});
end

function text=localSampleTime(t)
if numel(t)<2, text='single/unknown'; return; end
d=diff(t); d=d(isfinite(d) & d>0);
if isempty(d), text='variable'; else, text=mat2str(min(d)); end
end
