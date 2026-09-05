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
            model = char(string(model));
            block = char(string(block));
            stopTime = char(string(stopTime));
            result = struct('Mode',mode,'Model',model,'Block',block, ...
                'Time',[],'Inputs',[],'Outputs',[],'SimulationOutput',[], ...
                'Status','FAILED','Message','');

            tx = smartdebugger.TransactionManager();
            cleanup = onCleanup(@()tx.restore()); %#ok<NASGU>
            try
                load_system(model);
                if isempty(block)
                    error('SmartDebugger:MissingBlock','No debug block was specified.');
                end
                get_param(block,'Handle');
                set_param(model,'SimulationCommand','update');

                inputs = obj.instrumentPorts(block,'Inport',tx);
                outputs = obj.instrumentPorts(block,'Outport',tx);

                % These are simulation-time configuration overrides. They are
                % reverted automatically by sim; no persistent model change is made.
                simOut = sim(model, ...
                    'StopTime',stopTime, ...
                    'SignalLogging','on', ...
                    'SignalLoggingName','logsout', ...
                    'ReturnWorkspaceOutputs','on');

                logs = obj.getLogs(simOut);
                result.Inputs = obj.readLogged(logs,inputs);
                result.Outputs = obj.readLogged(logs,outputs);
                result.Time = obj.findCommonTime(result);
                result.SimulationOutput = simOut;
                result.Status = 'PASS';
                if isempty(logs)
                    result.Status = 'PARTIAL';
                    result.Message = ['Simulation completed, but logsout was not returned. ' ...
                        'The selected port may not support runtime logging in this simulation mode.'];
                    obj.Diagnostics.record('WARNING',[mode ' capture'],result.Message,'SmartDebugger:NoLogsout');
                end
            catch ME
                result.Status = 'FAILED';
                result.Message = ME.message;
                obj.Diagnostics.recordException(ME,[mode ' simulation']);
                rethrow(ME);
            end
        end

        function logs = getLogs(~,simOut)
            logs = [];
            if isempty(simOut), return; end
            try
                if isprop(simOut,'logsout')
                    logs = simOut.logsout;
                end
            catch
            end
            if isempty(logs)
                try, logs = simOut.get('logsout'); catch, end
            end
        end

        function ports = instrumentPorts(obj,block,direction,tx)
            template = struct('Port',0,'Name','','LogName','','Value',[], ...
                'DataType','','Dimension','','SampleTime','','Series',[], ...
                'LineHandle',-1,'SignalHandle',-1);
            ports = repmat(template,0,1);
            ph = get_param(block,'PortHandles');
            if strcmpi(direction,'Inport')
                hs = ph.Inport; displayDirection = 'Input';
            else
                hs = ph.Outport; displayDirection = 'Output';
            end

            for k = 1:numel(hs)
                p = template;
                p.Port = k;
                p.SignalHandle = hs(k);
                p.Name = sprintf('%s %d',displayDirection,k);
                try
                    p.LineHandle = get_param(hs(k),'Line');
                catch
                    p.LineHandle = -1;
                end

                if p.LineHandle == -1
                    % An unconnected port has no runtime line to capture.
                    ports(end+1) = p; %#ok<AGROW>
                    continue;
                end

                try
                    p.Name = smartdebugger.SignalNameResolver.resolve( ...
                        p.LineHandle,k,displayDirection);
                catch
                end

                % Use a deterministic per-port logging name. This avoids
                % collisions when a model contains duplicate signal names.
                p.LogName = matlab.lang.makeValidName(sprintf( ...
                    'SmartDebugger_%s_%03d',lower(displayDirection),k));

                % Capture every changed line parameter so the model is restored
                % even when simulation throws an exception.
                tx.record(p.LineHandle,'DataLogging', ...
                    safeGetParam(p.LineHandle,'DataLogging','off'));
                tx.record(p.LineHandle,'DataLoggingNameMode', ...
                    safeGetParam(p.LineHandle,'DataLoggingNameMode','SignalName'));
                tx.record(p.LineHandle,'DataLoggingName', ...
                    safeGetParam(p.LineHandle,'DataLoggingName',''));

                set_param(p.LineHandle,'DataLoggingNameMode','Custom');
                set_param(p.LineHandle,'DataLoggingName',p.LogName);
                set_param(p.LineHandle,'DataLogging','on');
                ports(end+1) = p; %#ok<AGROW>
            end
        end

        function ports = readLogged(obj,logs,ports)
            if isempty(ports), return; end
            for k = 1:numel(ports)
                if isempty(ports(k).LogName) || isempty(logs)
                    continue;
                end
                try
                    element = logs.getElement(ports(k).LogName);
                    ts = element.Values;
                    ports(k).Series = ts;
                    if isprop(ts,'Data')
                        data = ts.Data;
                        ports(k).Value = localLastSample(data);
                        ports(k).DataType = class(data);
                        ports(k).Dimension = mat2str(size(data));
                    end
                    if isprop(ts,'Time') && ~isempty(ts.Time)
                        ports(k).SampleTime = localSampleTime(ts.Time);
                    end
                catch ME
                    obj.Diagnostics.recordException(ME, ...
                        ['Read logged signal ' ports(k).LogName]);
                end
            end
        end

        function t = findCommonTime(~,result)
            t = [];
            allPorts = [result.Inputs result.Outputs];
            for k = 1:numel(allPorts)
                try
                    if ~isempty(allPorts(k).Series) && isprop(allPorts(k).Series,'Time')
                        t = allPorts(k).Series.Time(:);
                        return;
                    end
                catch
                end
            end
        end
    end
end

function value = safeGetParam(handle,param,defaultValue)
try
    value = get_param(handle,param);
catch
    value = defaultValue;
end
end

function value = localLastSample(data)
if isempty(data)
    value = [];
    return;
end
if isvector(data)
    value = data(end,:);
else
    idx = repmat({':'},1,ndims(data));
    idx{1} = size(data,1);
    value = data(idx{:});
end
end

function text = localSampleTime(t)
if numel(t) < 2
    text = 'single/unknown';
    return;
end
d = diff(t);
d = d(isfinite(d) & d > 0);
if isempty(d)
    text = 'variable';
else
    text = mat2str(min(d));
end
end
