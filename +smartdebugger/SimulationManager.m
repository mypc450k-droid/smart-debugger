classdef SimulationManager < handle
    %SIMULATIONMANAGER Run MIL/SIL simulations and capture selected ports.
    % TargetLink MIL requires the model SignalLogging parameter to be ON
    % while its MIL capabilities are activated.  This manager therefore
    % temporarily enables model-level logging, instruments source output
    % ports, runs Simulink, reads the returned Dataset, and restores every
    % temporary change.

    properties (SetAccess = private)
        Diagnostics
    end

    methods
        function obj = SimulationManager(diag)
            obj.Diagnostics = diag;
        end

        function result = runMIL(obj, model, block, stopTime)
            result = obj.runSimulation(model, block, stopTime, 'MIL');
        end

        function result = runSIL(obj, model, block, stopTime)
            result = obj.runSimulation(model, block, stopTime, 'SIL');
        end
    end

    methods (Access = private)
        function result = runSimulation(obj, model, block, stopTime, mode)
            model = char(string(model));
            block = char(string(block));
            stopTime = char(string(stopTime));

            result = struct();
            result.Mode = mode;
            result.Model = model;
            result.Block = block;
            result.Time = [];
            result.Inputs = obj.emptyPorts();
            result.Outputs = obj.emptyPorts();
            result.SimulationOutput = [];
            result.Status = 'FAILED';
            result.Message = '';

            % Initialize ALL locals before the first operation that can fail.
            simOut = [];
            logs = [];
            inputs = obj.emptyPorts();
            outputs = obj.emptyPorts();
            logName = '';
            root = '';

            tx = smartdebugger.TransactionManager();
            cleanup = onCleanup(@() tx.restore()); %#ok<NASGU>

            try
                root = obj.ensureModelLoaded(model, block);
                get_param(block, 'Handle');

                logName = obj.uniqueLogName();

                % TargetLink checks the actual model parameter when MIL
                % capabilities are activated.  A sim() name-value alone is
                % too late for that check in some TargetLink releases.
                oldSignalLogging = obj.requiredGetParam(root, 'SignalLogging');
                oldSignalLoggingName = obj.safeGetParam(root, 'SignalLoggingName', 'logsout');
                tx.record(root, 'SignalLogging', oldSignalLogging);
                tx.record(root, 'SignalLoggingName', oldSignalLoggingName);
                set_param(root, 'SignalLogging', 'on');
                set_param(root, 'SignalLoggingName', logName);

                inputs = obj.instrumentPorts(block, 'Inport', tx);
                outputs = obj.instrumentPorts(block, 'Outport', tx);
                obj.recordLoggingState(root, inputs, outputs, logName);

                simArgs = {'ReturnWorkspaceOutputs', 'on'};
                if ~obj.isAutoStopTime(stopTime)
                    simArgs(end+1:end+2) = {'StopTime', stopTime}; %#ok<AGROW>
                end
                if strcmpi(mode, 'MIL')
                    simArgs(end+1:end+2) = {'CaptureErrors', 'on'}; %#ok<AGROW>
                end

                obj.Diagnostics.record('INFO', [mode ' simulation'], ...
                    sprintf('Starting simulation. Model=%s, Block=%s, StopTime=%s, LogName=%s', ...
                    root, block, stopTime, logName), 'SmartDebugger:SimulationStart');

                % Do not use a local variable named simOut outside this
                % function.  This assignment is deliberately inside the
                % protected scope and simOut was initialized above.
                simOut = sim(root, simArgs{:});
                result.SimulationOutput = simOut;

                logs = obj.getLogs(simOut, logName);
                result.Inputs = obj.readLogged(logs, inputs);
                result.Outputs = obj.readLogged(logs, outputs);
                result.Time = obj.findFirstTime(result);

                errorMessage = obj.simulationErrorMessage(simOut);
                requested = numel(inputs) + numel(outputs);
                captured = obj.countCaptured(result);

                if ~isempty(errorMessage)
                    result.Status = 'PARTIAL';
                    result.Message = obj.formatSimulationError(errorMessage, stopTime, root);
                    obj.Diagnostics.record('ERROR', [mode ' simulation'], result.Message, ...
                        'SmartDebugger:SimulationCapturedError');
                else
                    result.Status = 'PASS';
                end

                if isempty(logs)
                    if isempty(errorMessage)
                        result.Status = 'PARTIAL';
                        result.Message = ['Simulation completed, but no signal-log Dataset was returned. ' ...
                            'Selected-port runtime values are unavailable.'];
                        obj.Diagnostics.record('WARNING', [mode ' capture'], result.Message, ...
                            'SmartDebugger:NoLogsout');
                    else
                        result.Status = 'FAILED';
                    end
                elseif requested > 0 && captured == 0
                    result.Status = 'PARTIAL';
                    result.Message = strtrim([result.Message ' No selected port produced readable runtime data.']);
                    obj.Diagnostics.record('WARNING', [mode ' capture'], result.Message, ...
                        'SmartDebugger:NoSelectedPortData');
                elseif captured < requested
                    result.Status = 'PARTIAL';
                    result.Message = strtrim(sprintf('%s Captured %d of %d selected ports.', ...
                        result.Message, captured, requested));
                    obj.Diagnostics.record('WARNING', [mode ' capture'], result.Message, ...
                        'SmartDebugger:PartialPortData');
                end

            catch ME
                result.SimulationOutput = simOut;
                result.Status = 'FAILED';
                result.Message = ME.message;
                obj.Diagnostics.recordException(ME, [mode ' simulation']);
            end
        end

        function ports = emptyPorts(~)
            template = struct('Port',0,'Name','','LogName','','Value',[], ...
                'DataType','','Dimension','','SampleTime','','Series',[], ...
                'LineHandle',-1,'SignalHandle',-1,'LoggingHandle',-1);
            ports = repmat(template, 0, 1);
        end

        function name = uniqueLogName(~)
            stamp = datestr(now, 'yyyymmdd_HHMMSSFFF');
            token = randi([0 2147483647]);
            name = matlab.lang.makeValidName(sprintf( ...
                'SmartDebugger_logsout_%s_%u', stamp, token));
        end

        function tf = isAutoStopTime(~, stopTime)
            s = strtrim(char(string(stopTime)));
            tf = isempty(s) || strcmpi(s, 'auto') || strcmpi(s, 'auto (model)');
        end

        function root = ensureModelLoaded(~, model, block)
            root = '';
            try, root = bdroot(block); catch, end
            if ~isempty(root)
                try
                    if bdIsLoaded(root), return; end
                catch
                end
            end
            [~, modelRoot, ext] = fileparts(model);
            if isempty(modelRoot), modelRoot = model; end
            if bdIsLoaded(modelRoot)
                root = modelRoot;
                return;
            end
            if isempty(ext)
                if exist([modelRoot '.slx'], 'file') == 2 || exist([modelRoot '.mdl'], 'file') == 2
                    load_system(modelRoot);
                else
                    error('SmartDebugger:ModelNotFound', 'Model not found: %s', model);
                end
            else
                if exist(model, 'file') ~= 2
                    error('SmartDebugger:ModelNotFound', 'Model file not found: %s', model);
                end
                load_system(model);
            end
            root = modelRoot;
        end

        function ports = instrumentPorts(obj, block, direction, tx)
            ports = obj.emptyPorts();
            template = struct('Port',0,'Name','','LogName','','Value',[], ...
                'DataType','','Dimension','','SampleTime','','Series',[], ...
                'LineHandle',-1,'SignalHandle',-1,'LoggingHandle',-1);
            ph = get_param(block, 'PortHandles');
            if strcmpi(direction, 'Inport')
                handles = ph.Inport; displayDirection = 'Input';
            else
                handles = ph.Outport; displayDirection = 'Output';
            end

            for k = 1:numel(handles)
                p = template;
                p.Port = k;
                p.SignalHandle = handles(k);
                p.Name = sprintf('%s %d', displayDirection, k);
                try, p.LineHandle = get_param(handles(k), 'Line'); catch, p.LineHandle = -1; end
                if isempty(p.LineHandle) || p.LineHandle == -1
                    ports(end+1,1) = p; %#ok<AGROW>
                    continue;
                end
                try
                    p.Name = smartdebugger.SignalNameResolver.resolve(p.LineHandle, k, displayDirection);
                catch
                end
                try, srcPort = get_param(p.LineHandle, 'SrcPortHandle'); catch, srcPort = -1; end
                if isempty(srcPort) || srcPort == -1
                    ports(end+1,1) = p; %#ok<AGROW>
                    continue;
                end
                p.LoggingHandle = srcPort;
                p.LogName = matlab.lang.makeValidName(sprintf( ...
                    'SmartDebugger_%s_%03d', lower(displayDirection), k));

                oldLogging = obj.safeGetParam(srcPort, 'DataLogging', 'off');
                oldMode = obj.safeGetParam(srcPort, 'DataLoggingNameMode', 'SignalName');
                oldName = obj.safeGetParam(srcPort, 'DataLoggingName', '');
                oldLimit = obj.safeGetParam(srcPort, 'DataLoggingLimitDataPoints', 'off');
                tx.record(srcPort, 'DataLogging', oldLogging);
                tx.record(srcPort, 'DataLoggingNameMode', oldMode);
                tx.record(srcPort, 'DataLoggingName', oldName);
                tx.record(srcPort, 'DataLoggingLimitDataPoints', oldLimit);

                try
                    set_param(srcPort, 'DataLogging', 'on', ...
                        'DataLoggingNameMode', 'Custom', ...
                        'DataLoggingName', p.LogName, ...
                        'DataLoggingLimitDataPoints', 'off');
                catch ME
                    p.LogName = '';
                    obj.Diagnostics.recordException(ME, sprintf( ...
                        '%s signal logging port %d', displayDirection, k));
                end
                ports(end+1,1) = p; %#ok<AGROW>
            end
        end

        function recordLoggingState(obj, root, inputs, outputs, logName)
            modelLogging = obj.safeGetParam(root, 'SignalLogging', '');
            modelLogName = obj.safeGetParam(root, 'SignalLoggingName', '');
            override = obj.safeGetParam(root, 'DataLoggingOverride', '');
            obj.Diagnostics.record('INFO', 'Logging configuration', sprintf( ...
                'Model SignalLogging=%s, SignalLoggingName=%s, DataLoggingOverride=%s, RunLogName=%s', ...
                obj.describeValue(modelLogging), obj.describeValue(modelLogName), ...
                obj.describeValue(override), logName), 'SmartDebugger:LoggingConfiguration');

            obj.recordPortDiagnostics(inputs);
            obj.recordPortDiagnostics(outputs);
        end

        function recordPortDiagnostics(obj, ports)
            for k = 1:numel(ports)
                if ports(k).LoggingHandle == -1, continue; end
                dl = obj.safeGetParam(ports(k).LoggingHandle, 'DataLogging', '');
                nm = obj.safeGetParam(ports(k).LoggingHandle, 'DataLoggingName', '');
                obj.Diagnostics.record('INFO', 'Port logging configuration', sprintf( ...
                    '%s port %d: DataLogging=%s, DataLoggingName=%s', ports(k).Name, ports(k).Port, ...
                    obj.describeValue(dl), obj.describeValue(nm)), 'SmartDebugger:PortLoggingConfiguration');
            end
        end

        function value = requiredGetParam(~, object, parameter)
            try
                value = get_param(object, parameter);
            catch ME
                error('SmartDebugger:RequiredModelParameter', ...
                    'Cannot read model parameter %s: %s', parameter, ME.message);
            end
        end

        function text = describeValue(~, value)
            if isempty(value), text = '[]'; return; end
            try, text = char(string(value)); catch, text = class(value); end
            if numel(text) > 160, text = [text(1:157) '...']; end
        end

        function message = simulationErrorMessage(~, simOut)
            message = '';
            if isempty(simOut), return; end
            try
                if isprop(simOut, 'ErrorMessage'), message = char(string(simOut.ErrorMessage)); end
            catch
            end
        end

        function message = formatSimulationError(~, errorMessage, stopTime, root)
            message = char(string(errorMessage));
            low = lower(message);
            if contains(low, 'tpt test is still running') || contains(low, 'stop time smaller than the length of the tpt test')
                if isempty(strtrim(stopTime)) || strcmpi(strtrim(stopTime), 'auto') || strcmpi(strtrim(stopTime), 'auto (model)')
                    message = [message ' Smart Debugger did not override StopTime; increase the TPT test-frame/model StopTime to cover the complete test case.'];
                else
                    message = [message ' Smart Debugger explicitly used StopTime=' stopTime '. Use auto or a value covering the complete TPT test case.'];
                end
            end
            try
                configured = get_param(root, 'StopTime');
                message = [message sprintf(' Model StopTime currently configured as %s.', char(string(configured)))];
            catch
            end
        end

        function logs = getLogs(~, simOut, logName)
            logs = [];
            if isempty(simOut), return; end
            try, if isprop(simOut, logName), logs = simOut.(logName); end; catch, end
            if isempty(logs), try, logs = simOut.get(logName); catch, end, end
            if isempty(logs), try, if isprop(simOut, 'logsout'), logs = simOut.logsout; end; catch, end, end
            if isempty(logs), try, logs = simOut.get('logsout'); catch, end, end
            if isempty(logs), return; end
            try
                if ~isa(logs, 'Simulink.SimulationData.Dataset'), logs = []; end
            catch
            end
        end

        function ports = readLogged(obj, logs, ports)
            if isempty(ports) || isempty(logs), return; end
            for k = 1:numel(ports)
                if isempty(ports(k).LogName), continue; end
                try
                    element = obj.findLogElement(logs, ports(k).LogName);
                    if isempty(element)
                        error('SmartDebugger:LoggedSignalMissing', ...
                            'Logged signal %s was not found in the simulation Dataset.', ports(k).LogName);
                    end
                    ts = element.Values;
                    ports(k).Series = ts;
                    if isprop(ts, 'Data')
                        data = ts.Data;
                        ports(k).Value = obj.lastSample(data);
                        ports(k).DataType = class(data);
                        ports(k).Dimension = mat2str(size(data));
                    end
                    if isprop(ts, 'Time') && ~isempty(ts.Time)
                        ports(k).SampleTime = obj.formatSampleTime(ts.Time);
                        obj.Diagnostics.record('INFO', 'Runtime capture', sprintf( ...
                            '%s: %d samples, t=%.12g..%.12g s, observed dt=%s', ports(k).Name, ...
                            numel(ts.Time), ts.Time(1), ts.Time(end), ports(k).SampleTime), 'SmartDebugger:RuntimeSeries');
                    end
                catch ME
                    obj.Diagnostics.recordException(ME, ['Read logged signal ' ports(k).LogName]);
                end
            end
        end

        function element = findLogElement(~, logs, name)
            element = [];
            try, element = logs.getElement(name); return; catch, end
            try
                n = logs.numElements;
                for k = 1:n
                    candidate = logs.getElement(k);
                    try
                        if strcmp(char(candidate.Name), name), element = candidate; return; end
                    catch
                    end
                end
            catch
            end
        end

        function n = countCaptured(~, result)
            n = 0;
            for k = 1:numel(result.Inputs)
                if ~isempty(result.Inputs(k).Series), n = n + 1; end
            end
            for k = 1:numel(result.Outputs)
                if ~isempty(result.Outputs(k).Series), n = n + 1; end
            end
        end

        function t = findFirstTime(~, result)
            t = [];
            for k = 1:numel(result.Inputs)
                if ~isempty(result.Inputs(k).Series)
                    t = result.Inputs(k).Series.Time(:); return;
                end
            end
            for k = 1:numel(result.Outputs)
                if ~isempty(result.Outputs(k).Series)
                    t = result.Outputs(k).Series.Time(:); return;
                end
            end
        end

        function value = safeGetParam(~, handle, parameter, defaultValue)
            try, value = get_param(handle, parameter); catch, value = defaultValue; end
        end

        function value = lastSample(~, data)
            if isempty(data), value = []; return; end
            subs = repmat({':'}, 1, ndims(data));
            subs{1} = size(data,1);
            value = data(subs{:});
        end

        function text = formatSampleTime(~, t)
            if numel(t) < 2, text = 'single/unknown'; return; end
            d = diff(t(:)); d = d(isfinite(d) & d > 0);
            if isempty(d), text = 'variable'; return; end
            dt = median(d);
            rounded = round(dt, 6);
            if abs(dt-rounded) < 1e-10, dt = rounded; end
            text = sprintf('%.12g s', dt);
        end
    end
end
