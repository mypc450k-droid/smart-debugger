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
            result = struct('Mode',mode,'Model',model,'Block',block,'Time',[], ...
                'Inputs',[],'Outputs',[],'SimulationOutput',[], ...
                'Status','FAILED','Message','');

            tx = smartdebugger.TransactionManager();
            cleanup = onCleanup(@()tx.restore()); %#ok<NASGU>
            try
                root = obj.ensureModelLoaded(model,block);
                get_param(block,'Handle');

                % Do not force an explicit update here. sim() performs the
                % required model compilation itself. This avoids compiling the
                % same TargetLink/Simulink model twice during one debug run.
                inputs = obj.instrumentPorts(block,'Inport',tx);
                outputs = obj.instrumentPorts(block,'Outport',tx);

                simOut = sim(root,'StopTime',stopTime, ...
                    'SignalLogging','on','SignalLoggingName','logsout', ...
                    'ReturnWorkspaceOutputs','on');

                logs = obj.getLogs(simOut);
                result.Inputs = obj.readLogged(logs,inputs);
                result.Outputs = obj.readLogged(logs,outputs);
                result.Time = obj.findCommonTime(result);
                result.SimulationOutput = simOut;

                captured = obj.countCaptured(result);
                requested = numel(result.Inputs) + numel(result.Outputs);
                result.Status = 'PASS';
                if isempty(logs)
                    result.Status = 'PARTIAL';
                    result.Message = 'Simulation completed, but logsout was not returned.';
                    obj.Diagnostics.record('WARNING',[mode ' capture'],result.Message,'SmartDebugger:NoLogsout');
                elseif requested > 0 && captured == 0
                    result.Status = 'PARTIAL';
                    result.Message = ['Simulation completed but none of the selected ports produced ' ...
                        'readable runtime series. See Diagnostics for unsupported or unconnected signals.'];
                    obj.Diagnostics.record('WARNING',[mode ' capture'],result.Message,'SmartDebugger:NoSelectedPortData');
                elseif captured < requested
                    result.Status = 'PARTIAL';
                    result.Message = sprintf('Simulation completed. Captured %d of %d selected ports.',captured,requested);
                    obj.Diagnostics.record('WARNING',[mode ' capture'],result.Message,'SmartDebugger:PartialPortData');
                end
            catch ME
                result.Message = ME.message;
                obj.Diagnostics.recordException(ME,[mode ' simulation']);
                rethrow(ME);
            end
        end

        function root = ensureModelLoaded(~,model,block)
            try
                root = bdroot(block);
                if isempty(root) || ~bdIsLoaded(root)
                    [~,rootFromFile,ext] = fileparts(model);
                    if isempty(rootFromFile), rootFromFile = model; end
                    if bdIsLoaded(rootFromFile)
                        root = rootFromFile;
                    else
                        if isempty(ext)
                            load_system(rootFromFile);
                        else
                            load_system(model);
                        end
                        root = rootFromFile;
                    end
                end
            catch ME
                error('SmartDebugger:ModelLoadFailed','Unable to load/resolve simulation model: %s',ME.message);
            end
        end

        function logs = getLogs(~,simOut)
            logs = [];
            if isempty(simOut), return; end
            try
                if isprop(simOut,'logsout'), logs = simOut.logsout; end
            catch
            end
            if isempty(logs)
                try, logs = simOut.get('logsout'); catch, end
            end
        end

        function ports = instrumentPorts(obj,block,direction,tx)
            template = struct('Port',0,'Name','','LogName','','Value',[], ...
                'DataType','','Dimension','','SampleTime','','Series',[], ...
                'LineHandle',-1,'SignalHandle',-1,'LoggingHandle',-1);
            ports = repmat(template,0,1);
            ph = get_param(block,'PortHandles');
            if strcmpi(direction,'Inport')
                hs = ph.Inport;
                displayDirection = 'Input';
            else
                hs = ph.Outport;
                displayDirection = 'Output';
            end

            loggingHandles = [];
            loggingNames = {};
            for k = 1:numel(hs)
                p = template;
                p.Port = k;
                p.SignalHandle = hs(k);
                p.Name = sprintf('%s %d',displayDirection,k);
                try, p.LineHandle = get_param(hs(k),'Line'); catch, p.LineHandle = -1; end

                if p.LineHandle == -1
                    ports(end+1) = p; %#ok<AGROW>
                    obj.Diagnostics.record('INFO',[displayDirection ' capture'], ...
                        sprintf('Port %d is not connected and cannot be runtime-logged.',k), ...
                        'SmartDebugger:UnconnectedPort');
                    continue;
                end

                try
                    p.Name = smartdebugger.SignalNameResolver.resolve(p.LineHandle,k,displayDirection);
                catch
                end

                try
                    srcPort = get_param(p.LineHandle,'SrcPortHandle');
                catch
                    srcPort = -1;
                end
                if isempty(srcPort) || srcPort == -1
                    ports(end+1) = p; %#ok<AGROW>
                    obj.Diagnostics.record('WARNING',[displayDirection ' capture'], ...
                        sprintf('Port %d has no source output port available for signal logging.',k), ...
                        'SmartDebugger:NoSourcePort');
                    continue;
                end
                p.LoggingHandle = srcPort;

                existing = find(loggingHandles == srcPort,1);
                if isempty(existing)
                    p.LogName = matlab.lang.makeValidName(sprintf( ...
                        'SmartDebugger_%s_%03d',lower(displayDirection),k));
                    loggingHandles(end+1) = srcPort; %#ok<AGROW>
                    loggingNames{end+1} = p.LogName; %#ok<AGROW>

                    oldLogging = obj.safeGetParam(srcPort,'DataLogging','off');
                    oldMode = obj.safeGetParam(srcPort,'DataLoggingNameMode','SignalName');
                    oldName = obj.safeGetParam(srcPort,'DataLoggingName','');
                    tx.record(srcPort,'DataLogging',oldLogging);
                    tx.record(srcPort,'DataLoggingNameMode',oldMode);
                    tx.record(srcPort,'DataLoggingName',oldName);

                    try
                        set_param(srcPort,'DataLoggingNameMode','Custom');
                        set_param(srcPort,'DataLoggingName',p.LogName);
                        set_param(srcPort,'DataLogging','on');
                    catch ME
                        p.LogName = '';
                        obj.Diagnostics.recordException(ME, ...
                            sprintf('%s signal logging port %d',displayDirection,k));
                    end
                else
                    p.LogName = loggingNames{existing};
                end
                ports(end+1) = p; %#ok<AGROW>
            end
        end

        function ports = readLogged(obj,logs,ports)
            if isempty(ports), return; end
            for k = 1:numel(ports)
                if isempty(ports(k).LogName) || isempty(logs), continue; end
                try
                    element = obj.findLogElement(logs,ports(k).LogName);
                    if isempty(element), error('SmartDebugger:LoggedSignalMissing', ...
                            'Logged signal %s was not found in logsout.',ports(k).LogName); end
                    ts = element.Values;
                    ports(k).Series = ts;
                    if isprop(ts,'Data')
                        data = ts.Data;
                        ports(k).Value = obj.lastSample(data);
                        ports(k).DataType = class(data);
                        ports(k).Dimension = mat2str(size(data));
                    end
                    if isprop(ts,'Time') && ~isempty(ts.Time)
                        ports(k).SampleTime = obj.sampleTime(ts.Time);
                    end
                catch ME
                    obj.Diagnostics.recordException(ME,['Read logged signal ' ports(k).LogName]);
                end
            end
        end

        function element = findLogElement(~,logs,name)
            element = [];
            try
                element = logs.getElement(name);
                return;
            catch
            end
            try
                n = logs.numElements;
                for k = 1:n
                    candidate = logs.getElement(k);
                    try
                        if strcmp(char(candidate.Name),name)
                            element = candidate;
                            return;
                        end
                    catch
                    end
                end
            catch
            end
        end

        function n = countCaptured(~,result)
            n = 0;
            allPorts = [result.Inputs result.Outputs];
            for k = 1:numel(allPorts)
                if ~isempty(allPorts(k).Series), n = n + 1; end
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

        function value = safeGetParam(~,handle,param,defaultValue)
            try, value = get_param(handle,param); catch, value = defaultValue; end
        end

        function value = lastSample(~,data)
            if isempty(data), value = []; return; end
            n = size(data,1);
            subs = repmat({':'},1,ndims(data));
            subs{1} = n;
            value = data(subs{:});
        end

        function text = sampleTime(~,t)
            if numel(t) < 2, text = 'single/unknown'; return; end
            d = diff(t);
            d = d(isfinite(d) & d > 0);
            if isempty(d), text = 'variable'; else, text = mat2str(min(d)); end
        end
    end
end
