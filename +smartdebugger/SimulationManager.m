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
            inputs = [];
            outputs = [];
            simOut = [];
            logName = obj.uniqueLogName();

            try
                root = obj.ensureModelLoaded(model,block);
                get_param(block,'Handle');
                oldSignalLogging = obj.safeGetParam(root,'SignalLogging','on');
                oldSignalLoggingName = obj.safeGetParam(root,'SignalLoggingName','logsout');
                tx.record(root,'SignalLogging',oldSignalLogging);
                tx.record(root,'SignalLoggingName',oldSignalLoggingName);
                try
                    set_param(root,'SignalLogging','on','SignalLoggingName',logName);
                catch ME
                    obj.Diagnostics.recordException(ME,'Enable model signal logging');
                end

                inputs = obj.instrumentPorts(block,'Inport',tx);
                outputs = obj.instrumentPorts(block,'Outport',tx);
                obj.recordLoggingState(root,inputs,outputs,logName);

                simArgs = {'SignalLogging','on','SignalLoggingName',logName, ...
                    'ReturnWorkspaceOutputs','on'};
                if ~obj.isAutoStopTime(stopTime)
                    simArgs = [simArgs {'StopTime',stopTime}]; %#ok<AGROW>
                end
                if strcmpi(mode,'MIL')
                    simArgs = [simArgs {'CaptureErrors','on'}]; %#ok<AGROW>
                end

                simOut = sim(root,simArgs{:});
                result.SimulationOutput = simOut;

                logs = obj.getLogs(simOut,logName);
                result.Inputs = obj.readLogged(logs,inputs);
                result.Outputs = obj.readLogged(logs,outputs);
                result.Time = obj.findCommonTime(result);

                captured = obj.countCaptured(result);
                requested = numel(result.Inputs) + numel(result.Outputs);
                errorMessage = obj.simulationErrorMessage(simOut);

                if ~isempty(errorMessage)
                    result.Status = 'PARTIAL';
                    result.Message = obj.formatSimulationError(errorMessage,stopTime,root);
                    obj.Diagnostics.record('ERROR',[mode ' simulation'],result.Message, ...
                        'SmartDebugger:SimulationCapturedError');
                else
                    result.Status = 'PASS';
                end

                if isempty(logs)
                    if isempty(errorMessage)
                        result.Status = 'PARTIAL';
                        result.Message = ['Simulation completed, but no signal-log Dataset was returned. ' ...
                            'See Diagnostics for the effective SignalLogging configuration.'];
                        obj.Diagnostics.record('WARNING',[mode ' capture'],result.Message, ...
                            'SmartDebugger:NoLogsout');
                    else
                        result.Status = 'FAILED';
                    end
                elseif requested > 0 && captured == 0
                    result.Status = 'PARTIAL';
                    if isempty(result.Message)
                        result.Message = ['Simulation completed but none of the selected ports produced ' ...
                            'readable runtime series. See Diagnostics for unsupported or unconnected signals.'];
                    end
                    obj.Diagnostics.record('WARNING',[mode ' capture'],result.Message, ...
                        'SmartDebugger:NoSelectedPortData');
                elseif captured < requested
                    if ~strcmp(result.Status,'FAILED')
                        result.Status = 'PARTIAL';
                    end
                    suffix = sprintf(' Captured %d of %d selected ports.',captured,requested);
                    result.Message = strtrim([result.Message suffix]);
                    obj.Diagnostics.record('WARNING',[mode ' capture'],result.Message, ...
                        'SmartDebugger:PartialPortData');
                end
            catch ME
                result.SimulationOutput = simOut;
                result.Message = ME.message;
                obj.Diagnostics.recordException(ME,[mode ' simulation']);
                rethrow(ME);
            end
        end

        function name = uniqueLogName(~)
            name = matlab.lang.makeValidName(sprintf('SmartDebugger_logsout_%s', ...
                char(string(java.util.UUID.randomUUID()))));
        end

        function recordLoggingState(obj,root,inputs,outputs,logName)
            try
                modelLogging = obj.safeGetParam(root,'SignalLogging','');
                modelLoggingName = obj.safeGetParam(root,'SignalLoggingName','');
                override = obj.safeGetParam(root,'DataLoggingOverride','');
                obj.Diagnostics.record('INFO','Logging configuration', ...
                    sprintf('Model SignalLogging=%s, SignalLoggingName=%s, DataLoggingOverride=%s, RunLogName=%s', ...
                    char(string(modelLogging)),char(string(modelLoggingName)), ...
                    obj.describeValue(override),logName), ...
                    'SmartDebugger:LoggingConfiguration');
            catch ME
                obj.Diagnostics.recordException(ME,'Read logging configuration');
            end
            allPorts = [inputs outputs];
            for k = 1:numel(allPorts)
                if allPorts(k).LoggingHandle == -1
                    continue;
                end
                dl = obj.safeGetParam(allPorts(k).LoggingHandle,'DataLogging','');
                nm = obj.safeGetParam(allPorts(k).LoggingHandle,'DataLoggingName','');
                obj.Diagnostics.record('INFO','Port logging configuration', ...
                    sprintf('%s port %d: DataLogging=%s, DataLoggingName=%s', ...
                    allPorts(k).Name,allPorts(k).Port,char(string(dl)),char(string(nm))), ...
                    'SmartDebugger:PortLoggingConfiguration');
            end
        end

        function text = describeValue(~,value)
            if isempty(value)
                text = '[]';
                return;
            end
            try
                text = char(string(value));
            catch
                text = class(value);
            end
            if numel(text) > 160
                text = [text(1:157) '...'];
            end
        end

        function tf = isAutoStopTime(~,stopTime)
            s = strtrim(char(string(stopTime)));
            tf = isempty(s) || strcmpi(s,'auto') || strcmpi(s,'auto (model)');
        end

        function message = simulationErrorMessage(~,simOut)
            message = '';
            if isempty(simOut)
                return;
            end
            try
                if isprop(simOut,'ErrorMessage')
                    message = char(string(simOut.ErrorMessage));
                end
            catch
            end
        end

        function message = formatSimulationError(~,errorMessage,stopTime,root)
            message = char(string(errorMessage));
            lowerMessage = lower(message);
            if contains(lowerMessage,'tpt test is still running') || ...
                    contains(lowerMessage,'stop time smaller than the length of the tpt test')
                if isempty(strtrim(stopTime)) || strcmpi(strtrim(stopTime),'auto') || ...
                        strcmpi(strtrim(stopTime),'auto (model)')
                    message = [message ' Smart Debugger did not override the model StopTime. ' ...
                        'The TPT test frame itself appears to end before the TPT test case. ' ...
                        'Increase the test-frame/model StopTime to the TPT test-case duration.'];
                else
                    message = [message ' Smart Debugger explicitly overrode StopTime=' stopTime ...
                        '. For a TPT test frame, use StopTime=auto or set it at least to the TPT test-case duration.'];
                end
            end
            try
                configured = get_param(root,'StopTime');
                message = [message sprintf(' Model StopTime currently configured as %s.',char(string(configured)))];
            catch
            end
        end

        function root = ensureModelLoaded(~,model,block)
            try
                root = bdroot(block);
                if isempty(root) || ~bdIsLoaded(root)
                    [~,rootFromFile,ext] = fileparts(model);
                    if isempty(rootFromFile)
                        rootFromFile = model;
                    end
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
                error('SmartDebugger:ModelLoadFailed', ...
                    'Unable to load/resolve simulation model: %s',ME.message);
            end
        end

        function logs = getLogs(obj,simOut,logName)
            logs = [];
            if ~isempty(simOut)
                try
                    if isprop(simOut,logName)
                        logs = simOut.(logName);
                    end
                catch
                end
                if isempty(logs)
                    try
                        logs = simOut.get(logName);
                    catch
                    end
                end
                if isempty(logs)
                    try
                        if isprop(simOut,'logsout')
                            logs = simOut.logsout;
                        end
                    catch
                    end
                end
                if isempty(logs)
                    try
                        logs = simOut.get('logsout');
                    catch
                    end
                end
            end
            if isempty(logs)
                try
                    if evalin('base',sprintf('exist(''%s'',''var'')',logName))
                        logs = evalin('base',logName);
                    end
                catch
                end
            end
            if isempty(logs)
                try
                    if evalin('base','exist(''logsout'',''var'')')
                        candidate = evalin('base','logsout');
                        if isa(candidate,'Simulink.SimulationData.Dataset')
                            logs = candidate;
                        end
                    end
                catch
                end
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
                try
                    p.LineHandle = get_param(hs(k),'Line');
                catch
                    p.LineHandle = -1;
                end
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
                    p.LogName = matlab.lang.makeValidName(sprintf('SmartDebugger_%s_%03d',lower(displayDirection),k));
                    loggingHandles(end+1) = srcPort; %#ok<AGROW>
                    loggingNames{end+1} = p.LogName; %#ok<AGROW>
                    oldLogging = obj.safeGetParam(srcPort,'DataLogging','off');
                    oldMode = obj.safeGetParam(srcPort,'DataLoggingNameMode','SignalName');
                    oldName = obj.safeGetParam(srcPort,'DataLoggingName','');
                    oldLimit = obj.safeGetParam(srcPort,'DataLoggingLimitDataPoints','off');
                    oldMax = obj.safeGetParam(srcPort,'DataLoggingMaxPoints','5000');
                    tx.record(srcPort,'DataLogging',oldLogging);
                    tx.record(srcPort,'DataLoggingNameMode',oldMode);
                    tx.record(srcPort,'DataLoggingName',oldName);
                    tx.record(srcPort,'DataLoggingLimitDataPoints',oldLimit);
                    tx.record(srcPort,'DataLoggingMaxPoints',oldMax);
                    try
                        % Do not decimate or cap the selected signal. The
                        % debugger needs the complete sample history from the
                        % first logged sample through the end of simulation.
                        set_param(srcPort,'DataLoggingNameMode','Custom', ...
                            'DataLoggingName',p.LogName, ...
                            'DataLogging','on', ...
                            'DataLoggingLimitDataPoints','off');
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
            if isempty(ports) || isempty(logs)
                return;
            end
            for k = 1:numel(ports)
                if isempty(ports(k).LogName)
                    continue;
                end
                try
                    element = obj.findLogElement(logs,ports(k).LogName);
                    if isempty(element)
                        error('SmartDebugger:LoggedSignalMissing', ...
                            'Logged signal %s was not found in logsout.',ports(k).LogName);
                    end
                    ts = element.Values;
                    ports(k).Series = ts;
                    if isprop(ts,'Data')
                        data = ts.Data;
                        ports(k).Value = obj.lastSample(data);
                        ports(k).DataType = class(data);
                        ports(k).Dimension = mat2str(size(data));
                    end
                    if isprop(ts,'Time') && ~isempty(ts.Time)
                        ports(k).SampleTime = obj.formatSampleTime(ts.Time);
                        obj.Diagnostics.record('INFO','Runtime capture', ...
                            sprintf('%s: %d samples, t=%.12g..%.12g s, observed dt=%s', ...
                            ports(k).Name,numel(ts.Time),ts.Time(1),ts.Time(end),ports(k).SampleTime), ...
                            'SmartDebugger:RuntimeSeries');
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
                if ~isempty(allPorts(k).Series)
                    n = n + 1;
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

        function value = safeGetParam(~,handle,param,defaultValue)
            try
                value = get_param(handle,param);
            catch
                value = defaultValue;
            end
        end

        function value = lastSample(~,data)
            if isempty(data)
                value = [];
                return;
            end
            n = size(data,1);
            subs = repmat({':'},1,ndims(data));
            subs{1} = n;
            value = data(subs{:});
        end

        function text = formatSampleTime(~,t)
            if numel(t) < 2
                text = 'single/unknown';
                return;
            end
            d = diff(t(:));
            d = d(isfinite(d) & d > 0);
            if isempty(d)
                text = 'variable';
                return;
            end
            dt = median(d);
            % Normalize only the displayed number. The original time vector
            % remains untouched and is what the plot/comparison uses.
            if abs(dt) < 1e-12
                dt = 0;
            end
            if abs(dt - round(dt,6)) < 1e-10
                dt = round(dt,6);
            end
            text = sprintf('%.12g s',dt);
        end
    end
end
