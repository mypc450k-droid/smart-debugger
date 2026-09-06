classdef SimulationManager < handle
    %SIMULATIONMANAGER Execute a debug simulation and capture selected ports.
    % Signal logging is configured only for an explicit Run Debug operation.
    % Bus-valued ports are expanded after simulation into their leaf signals.

    properties (SetAccess = private)
        Diagnostics
    end

    methods
        function obj = SimulationManager(diag)
            obj.Diagnostics = diag;
        end

        function result = runMIL(obj, model, block, stopTime)
            result = obj.run(model, block, stopTime, 'MIL');
        end

        function result = runSIL(obj, model, block, stopTime)
            result = obj.run(model, block, stopTime, 'SIL');
        end
    end

    methods (Access = private)
        function result = run(obj, model, block, stopTime, mode)
            model = char(string(model));
            block = char(string(block));
            stopTime = char(string(stopTime));

            result = struct('Mode', mode, 'Model', model, 'Block', block, ...
                'Time', [], 'Inputs', obj.emptyPorts(), 'Outputs', obj.emptyPorts(), ...
                'SimulationOutput', [], 'Status', 'FAILED', 'Message', '');

            simOut = [];
            logs = [];
            inputs = obj.emptyPorts();
            outputs = obj.emptyPorts();
            root = '';
            logName = 'logsout';

            tx = smartdebugger.TransactionManager();
            cleanup = onCleanup(@()tx.restore()); %#ok<NASGU>

            try
                root = obj.ensureModelLoaded(model, block);
                get_param(block, 'Handle');

                oldLogging = obj.requiredGetParam(root, 'SignalLogging');
                oldLogName = obj.safeGetParam(root, 'SignalLoggingName', 'logsout');
                if isempty(strtrim(char(string(oldLogName))))
                    oldLogName = 'logsout';
                end
                logName = char(string(oldLogName));

                tx.record(root, 'SignalLogging', oldLogging);
                tx.record(root, 'SignalLoggingName', oldLogName);
                set_param(root, 'SignalLogging', 'on');
                set_param(root, 'SignalLoggingName', logName);

                inputs = obj.instrumentPorts(block, 'Inport', tx);
                outputs = obj.instrumentPorts(block, 'Outport', tx);
                obj.recordLoggingState(root, inputs, outputs, logName);

                simArgs = {'ReturnWorkspaceOutputs', 'on'};
                if ~obj.isAutoStopTime(stopTime)
                    simArgs(end+1:end+2) = {'StopTime', stopTime};
                end
                if strcmpi(mode, 'MIL')
                    simArgs(end+1:end+2) = {'CaptureErrors', 'on'};
                end

                obj.Diagnostics.record('INFO', [mode ' simulation'], ...
                    sprintf('Starting simulation. Model=%s, Block=%s, StopTime=%s, SignalLogging=%s', ...
                    root, block, stopTime, logName), 'SmartDebugger:SimulationStart');

                simOut = sim(root, simArgs{:});
                result.SimulationOutput = simOut;

                logs = obj.getLogs(simOut, logName);
                result.Inputs = obj.readLogged(logs, inputs);
                result.Outputs = obj.readLogged(logs, outputs);
                result.Time = obj.firstTime(result);

                simError = obj.simulationErrorMessage(simOut);
                requested = numel(inputs) + numel(outputs);
                captured = obj.countCaptured(result);

                if isempty(simError)
                    result.Status = 'PASS';
                else
                    result.Status = 'PARTIAL';
                    result.Message = obj.formatSimulationError(simError, stopTime, root);
                    obj.Diagnostics.record('ERROR', [mode ' simulation'], ...
                        result.Message, 'SmartDebugger:SimulationCapturedError');
                end

                if isempty(logs)
                    if isempty(simError)
                        result.Status = 'PARTIAL';
                        result.Message = 'Simulation completed but no signal-log Dataset was returned.';
                        obj.Diagnostics.record('WARNING', [mode ' capture'], ...
                            result.Message, 'SmartDebugger:NoLogsout');
                    else
                        result.Status = 'FAILED';
                    end
                elseif requested > 0 && captured == 0
                    result.Status = 'PARTIAL';
                    result.Message = strtrim([result.Message ...
                        ' No selected port produced readable runtime data.']);
                    obj.Diagnostics.record('WARNING', [mode ' capture'], ...
                        result.Message, 'SmartDebugger:NoSelectedPortData');
                elseif captured < requested
                    result.Status = 'PARTIAL';
                    result.Message = strtrim(sprintf('%s Captured %d of %d selected top-level ports.', ...
                        result.Message, captured, requested));
                    obj.Diagnostics.record('WARNING', [mode ' capture'], ...
                        result.Message, 'SmartDebugger:PartialPortData');
                end
            catch ME
                result.SimulationOutput = simOut;
                result.Status = 'FAILED';
                result.Message = ME.message;
                obj.Diagnostics.recordException(ME, [mode ' simulation']);
            end
        end

        function ports = emptyPorts(~)
            template = struct('Port', 0, 'Name', '', 'LogName', '', 'Value', [], ...
                'DataType', '', 'Dimension', '', 'SampleTime', '', 'Series', [], ...
                'LineHandle', -1, 'SignalHandle', -1, 'LoggingHandle', -1);
            ports = repmat(template, 0, 1);
        end

        function root = ensureModelLoaded(~, model, block)
            root = '';
            try
                root = bdroot(block);
            catch
            end

            if ~isempty(root)
                try
                    if bdIsLoaded(root)
                        return;
                    end
                catch
                end
            end

            [~, modelRoot, ext] = fileparts(model);
            if isempty(modelRoot)
                modelRoot = model;
            end

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
            elseif exist(model, 'file') == 2
                load_system(model);
            else
                error('SmartDebugger:ModelNotFound', 'Model file not found: %s', model);
            end

            root = modelRoot;
        end

        function ports = instrumentPorts(obj, block, direction, tx)
            ports = obj.emptyPorts();
            template = struct('Port', 0, 'Name', '', 'LogName', '', 'Value', [], ...
                'DataType', '', 'Dimension', '', 'SampleTime', '', 'Series', [], ...
                'LineHandle', -1, 'SignalHandle', -1, 'LoggingHandle', -1);

            ph = get_param(block, 'PortHandles');
            if strcmpi(direction, 'Inport')
                handles = ph.Inport;
                displayDirection = 'Input';
            else
                handles = ph.Outport;
                displayDirection = 'Output';
            end

            for k = 1:numel(handles)
                p = template;
                p.Port = k;
                p.SignalHandle = handles(k);
                p.Name = sprintf('%s %d', displayDirection, k);

                try
                    p.LineHandle = get_param(handles(k), 'Line');
                catch
                    p.LineHandle = -1;
                end

                if isempty(p.LineHandle) || p.LineHandle == -1
                    ports(end+1, 1) = p; %#ok<AGROW>
                    continue;
                end

                try
                    p.Name = smartdebugger.SignalNameResolver.resolve( ...
                        p.LineHandle, k, displayDirection);
                catch
                end

                try
                    srcPort = get_param(p.LineHandle, 'SrcPortHandle');
                catch
                    srcPort = -1;
                end

                if isempty(srcPort) || srcPort == -1
                    ports(end+1, 1) = p; %#ok<AGROW>
                    continue;
                end

                p.LoggingHandle = srcPort;
                p.LogName = matlab.lang.makeValidName( ...
                    sprintf('SmartDebugger_%s_%03d', lower(displayDirection), k));

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
                    obj.Diagnostics.recordException(ME, ...
                        sprintf('%s signal logging port %d', displayDirection, k));
                end

                ports(end+1, 1) = p; %#ok<AGROW>
            end
        end

        function recordLoggingState(obj, root, inputs, outputs, logName)
            obj.Diagnostics.record('INFO', 'Logging configuration', ...
                sprintf('Model SignalLogging=%s, SignalLoggingName=%s, RunLogName=%s', ...
                obj.describeValue(obj.safeGetParam(root, 'SignalLogging', '')), ...
                obj.describeValue(obj.safeGetParam(root, 'SignalLoggingName', '')), ...
                logName), 'SmartDebugger:LoggingConfiguration');
            obj.recordPortDiagnostics(inputs);
            obj.recordPortDiagnostics(outputs);
        end

        function recordPortDiagnostics(obj, ports)
            for k = 1:numel(ports)
                if ports(k).LoggingHandle == -1
                    continue;
                end
                dl = obj.safeGetParam(ports(k).LoggingHandle, 'DataLogging', '');
                nm = obj.safeGetParam(ports(k).LoggingHandle, 'DataLoggingName', '');
                obj.Diagnostics.record('INFO', 'Port logging configuration', ...
                    sprintf('%s port %d: DataLogging=%s, DataLoggingName=%s', ...
                    ports(k).Name, ports(k).Port, obj.describeValue(dl), ...
                    obj.describeValue(nm)), 'SmartDebugger:PortLoggingConfiguration');
            end
        end

        function logs = getLogs(~, simOut, logName)
            logs = [];
            if isempty(simOut)
                return;
            end

            try
                if isprop(simOut, logName)
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
                    if isprop(simOut, 'logsout')
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

        function ports = readLogged(obj, logs, ports)
            if isempty(ports) || isempty(logs)
                return;
            end

            out = obj.emptyPorts();
            for k = 1:numel(ports)
                p = ports(k);
                if isempty(p.LogName)
                    out(end+1, 1) = p; %#ok<AGROW>
                    continue;
                end

                try
                    e = obj.findLogElement(logs, p.LogName);
                    if isempty(e)
                        error('SmartDebugger:LoggedSignalMissing', ...
                            'Logged signal %s not found.', p.LogName);
                    end

                    values = e.Values;
                    busLeaves = obj.expandBusValues(p, values);
                    if ~isempty(busLeaves)
                        out = [out; busLeaves]; %#ok<AGROW>
                    else
                        p.Series = values;
                        data = values.Data;
                        p.Value = obj.lastSample(data);
                        p.DataType = class(data);
                        p.Dimension = mat2str(size(data));
                        if ~isempty(values.Time)
                            p.SampleTime = obj.formatSampleTime(values.Time);
                            obj.logRuntimeInfo(p.Name, values);
                        end
                        out(end+1, 1) = p; %#ok<AGROW>
                    end
                catch ME
                    obj.Diagnostics.recordException(ME, ['Read logged signal ' p.LogName]);
                    out(end+1, 1) = p; %#ok<AGROW>
                end
            end
            ports = out;
        end

        function leaves = expandBusValues(obj, parent, values)
            % Signal logging stores a bus as a structure of timeseries objects.
            % Unlike a scalar signal, the Values property itself is the structure,
            % so there is no .Data property at this level.
            leaves = obj.emptyPorts();

            if isstruct(values)
                data = values;
            else
                data = [];
                try
                    data = values.Data;
                catch
                    return;
                end
                if ~isstruct(data)
                    return;
                end
            end

            leaves = obj.collectBusStruct(parent, data, '');

            if ~isempty(leaves)
                obj.Diagnostics.record('INFO', 'Bus expansion', ...
                    sprintf('%s expanded into %d leaf signals and all leaves were captured.', ...
                    parent.Name, numel(leaves)), 'SmartDebugger:BusExpansion');
            end
        end

        function leaves = collectBusStruct(obj, parent, value, prefix)
            leaves = obj.emptyPorts();

            if obj.isTimeSeriesLike(value)
                path = strtrim(prefix);
                if isempty(path)
                    return;
                end
                p = obj.makeBusLeaf(parent, value, path);
                leaves = p;
                return;
            end

            if isstruct(value)
                fields = fieldnames(value);
                for k = 1:numel(fields)
                    fieldName = fields{k};
                    if isempty(prefix)
                        childPath = fieldName;
                    else
                        childPath = [prefix '.' fieldName];
                    end

                    child = value.(fieldName);
                    childLeaves = obj.collectBusStruct(parent, child, childPath);
                    if ~isempty(childLeaves)
                        leaves = [leaves; childLeaves]; %#ok<AGROW>
                    end
                end
            end
        end

        function p = makeBusLeaf(obj, parent, value, path)
            p = parent;
            p.Name = [parent.Name '.' path];
            p.LogName = [parent.LogName '.' path];
            p.Series = value;

            try
                data = value.Data;
                p.Value = obj.lastSample(data);
                p.DataType = class(data);
                p.Dimension = mat2str(size(data));
                p.SampleTime = obj.formatSampleTime(value.Time);
                obj.logRuntimeInfo(p.Name, value);
            catch ME
                obj.Diagnostics.recordException(ME, ['Read bus leaf ' p.Name]);
            end
        end

        function tf = isTimeSeriesLike(~, value)
            tf = false;
            try
                tf = isa(value, 'timeseries');
            catch
            end
            if tf
                return;
            end

            try
                tf = isobject(value) && isprop(value, 'Time') && isprop(value, 'Data');
            catch
                tf = false;
            end
        end

        function logRuntimeInfo(obj, name, series)
            try
                if ~isempty(series.Time)
                    obj.Diagnostics.record('INFO', 'Runtime capture', ...
                        sprintf('%s: %d samples, t=%.12g..%.12g s, observed dt=%s', ...
                        name, numel(series.Time), series.Time(1), series.Time(end), ...
                        obj.formatSampleTime(series.Time)), 'SmartDebugger:RuntimeSeries');
                end
            catch
            end
        end

        function element = findLogElement(~, logs, name)
            element = [];
            try
                element = logs.getElement(name);
                return;
            catch
            end

            try
                for k = 1:logs.numElements
                    e = logs.getElement(k);
                    try
                        if strcmp(char(e.Name), name)
                            element = e;
                            return;
                        end
                    catch
                    end
                end
            catch
            end
        end

        function n = countCaptured(~, result)
            n = 0;
            for k = 1:numel(result.Inputs)
                if ~isempty(result.Inputs(k).Series)
                    n = n + 1;
                end
            end
            for k = 1:numel(result.Outputs)
                if ~isempty(result.Outputs(k).Series)
                    n = n + 1;
                end
            end
        end

        function t = firstTime(~, result)
            t = [];
            for k = 1:numel(result.Inputs)
                if ~isempty(result.Inputs(k).Series)
                    t = result.Inputs(k).Series.Time(:);
                    return;
                end
            end
            for k = 1:numel(result.Outputs)
                if ~isempty(result.Outputs(k).Series)
                    t = result.Outputs(k).Series.Time(:);
                    return;
                end
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

        function value = safeGetParam(~, object, parameter, defaultValue)
            try
                value = get_param(object, parameter);
            catch
                value = defaultValue;
            end
        end

        function text = describeValue(~, value)
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

        function text = simulationErrorMessage(~, simOut)
            text = '';
            if isempty(simOut)
                return;
            end
            try
                if isprop(simOut, 'ErrorMessage')
                    text = char(string(simOut.ErrorMessage));
                end
            catch
            end
        end

        function message = formatSimulationError(~, message, stopTime, root)
            message = char(string(message));
            low = lower(message);

            if contains(low, 'tpt test is still running') || ...
                    contains(low, 'stop time smaller than the length of the tpt test')
                if isempty(strtrim(stopTime)) || ...
                        strcmpi(strtrim(stopTime), 'auto') || ...
                        strcmpi(strtrim(stopTime), 'auto (model)')
                    message = [message ...
                        ' Smart Debugger did not override StopTime. Increase the TPT test-frame/model StopTime to cover the complete test case.'];
                else
                    message = [message ...
                        ' Smart Debugger explicitly used StopTime=' stopTime ...
                        '. Use auto or a value covering the complete TPT test case.'];
                end
            end

            try
                message = [message sprintf(' Model StopTime currently configured as %s.', ...
                    char(string(get_param(root, 'StopTime'))))];
            catch
            end
        end

        function tf = isAutoStopTime(~, stopTime)
            s = strtrim(char(string(stopTime)));
            tf = isempty(s) || strcmpi(s, 'auto') || strcmpi(s, 'auto (model)');
        end

        function value = lastSample(~, data)
            if isempty(data)
                value = [];
                return;
            end

            try
                if isvector(data)
                    value = data(end);
                else
                    subs = repmat({':'}, 1, ndims(data));
                    subs{1} = size(data, 1);
                    value = data(subs{:});
                end
            catch
                value = data(end);
            end
        end

        function text = formatSampleTime(~, t)
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
            r = round(dt, 6);
            if abs(dt - r) < 1e-10
                dt = r;
            end
            text = sprintf('%.12g s', dt);
        end
    end
end
