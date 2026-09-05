classdef SmartDebuggerApp < handle
    %SMARTDEBUGGERAPP Smart Debugger UI for live Simulink MIL/SIL debugging.

    properties (SetAccess = private)
        UIFigure
        ModelManager
        SimulationManager
        ComparisonEngine
        DiagnosticsManager
        CompatibilityManager
        Mode = 'MIL'
        SelectedBlock = ''
        SelectedSILBlock = ''
        MILResult = []
        SILResult = []
    end

    properties (Access = private)
        MILModelField
        SILModelField
        StopTimeField
        ModeGroup
        BlockField
        SILBlockField
        InputsTable
        OutputsTable
        ComparisonTable
        DiagnosticsArea
        PlotAxes
        StatusLabel
        CompatibilityLabel
        BlockInfoArea
        FirstDivergenceLabel
        AbsToleranceField
        RelToleranceField
        AlignmentDropDown
        Tree
        SelectionTimer
        ActiveResult = []
        Busy = false
    end

    methods
        function obj = SmartDebuggerApp(varargin)
            obj.DiagnosticsManager = smartdebugger.DiagnosticsManager();
            obj.CompatibilityManager = smartdebugger.CompatibilityManager();
            obj.ModelManager = smartdebugger.ModelManager(obj.DiagnosticsManager);
            obj.SimulationManager = smartdebugger.SimulationManager(obj.DiagnosticsManager);
            obj.ComparisonEngine = smartdebugger.ComparisonEngine();

            obj.buildUI();
            obj.updateCompatibility();
            obj.startSelectionWatcher();

            if ~isempty(varargin)
                obj.configure(varargin{:});
            end
        end

        function configure(obj, varargin)
            p = inputParser;
            addParameter(p, 'Model', '', @(x) ischar(x) || isstring(x));
            addParameter(p, 'SILModel', '', @(x) ischar(x) || isstring(x));
            parse(p, varargin{:});

            model = char(string(p.Results.Model));
            silModel = char(string(p.Results.SILModel));
            if ~isempty(strtrim(model))
                obj.setMILModel(model);
            end
            if ~isempty(strtrim(silModel))
                obj.setSILModel(silModel);
            end
        end

        function setMILModel(obj, model)
            try
                model = char(string(model));
                obj.ModelManager.loadModel(model);
                obj.MILModelField.Value = model;
                obj.refreshModelTree();
                obj.refreshBlockSelection();
                obj.status(['MIL model ready: ' model]);
            catch ME
                obj.handleError(ME, 'Load MIL model');
            end
        end

        function setSILModel(obj, model)
            try
                model = char(string(model));
                if isempty(strtrim(model))
                    return;
                end

                [~, root, ext] = fileparts(model);
                if bdIsLoaded(root)
                    % Already loaded, including generated/working models whose
                    % source file is not currently present on disk.
                elseif isempty(ext)
                    load_system(root);
                elseif exist(model, 'file') == 2
                    load_system(model);
                else
                    error('SmartDebugger:SILModelNotFound', ...
                        'SIL model file not found: %s', model);
                end

                obj.SILModelField.Value = model;
                obj.status(['SIL model ready: ' model]);
            catch ME
                obj.handleError(ME, 'Load SIL model');
            end
        end

        function refreshBlockSelection(obj)
            try
                path = obj.ModelManager.currentSimulinkSelection();
                if isempty(path)
                    obj.status('No selected Simulink block. Select a block in an open model and click Import.');
                    return;
                end

                obj.syncMILModelFromBlock(path);
                obj.setSelectedBlock(path);
            catch ME
                obj.handleError(ME, 'Import selection');
            end
        end

        function syncMILModelFromBlock(obj, path)
            root = bdroot(path);
            obj.ModelManager.loadModel(root);

            modelFile = '';
            try
                modelFile = get_param(root, 'FileName');
            catch
            end

            if isempty(modelFile)
                modelFile = root;
            end
            obj.MILModelField.Value = modelFile;
        end

        function setSelectedBlock(obj, path)
            path = char(string(path));
            if isempty(strtrim(path))
                return;
            end

            obj.SelectedBlock = path;
            obj.BlockField.Value = path;
            obj.inspectBlock();
        end

        function inspectBlock(obj)
            path = char(string(obj.BlockField.Value));
            if isempty(strtrim(path))
                return;
            end

            info = obj.ModelManager.inspectBlock(path);
            if isempty(info)
                obj.status('Unable to inspect selected block. See Diagnostics.');
                obj.showDiagnostics();
                return;
            end

            obj.SelectedBlock = path;
            obj.populatePorts(info);
            obj.populateBlockInfo(info);
            obj.status(['Selected: ' path]);
        end

        function runDebug(obj)
            if obj.Busy
                return;
            end

            obj.setBusy(true);
            cleanup = onCleanup(@() obj.setBusy(false)); %#ok<NASGU>

            try
                obj.refreshBlockSelectionIfNeeded();
                obj.validateRunInputs();
                obj.inspectBlock();

                stopTime = char(string(obj.StopTimeField.Value));

                if strcmpi(obj.Mode, 'MIL')
                    model = obj.resolveMILModel();
                    block = char(obj.SelectedBlock);
                    obj.MILResult = obj.SimulationManager.runMIL(model, block, stopTime);
                    result = obj.MILResult;
                else
                    silModel = char(obj.SILModelField.Value);
                    [silBlock, confidence, mapMethod, candidates] = ...
                        smartdebugger.ModelMapper.mapBlock(char(obj.SelectedBlock), silModel);

                    if isempty(silBlock)
                        override = char(obj.SILBlockField.Value);
                        if ~isempty(strtrim(override))
                            silBlock = override;
                            confidence = 'USER_DEFINED';
                            mapMethod = 'USER_DEFINED';
                        else
                            error('SmartDebugger:SILMappingRequired', ...
                                'Automatic MIL-to-SIL mapping failed. Enter the SIL block path in the override field.');
                        end
                    end

                    if strcmp(confidence, 'AMBIGUOUS')
                        error('SmartDebugger:AmbiguousSILMapping', ...
                            'SIL mapping is ambiguous. Candidates: %s', ...
                            strjoin(candidates, ', '));
                    end

                    obj.SelectedSILBlock = silBlock;
                    obj.SILBlockField.Value = silBlock;
                    obj.SILResult = obj.SimulationManager.runSIL(silModel, silBlock, stopTime);
                    obj.SILResult.MappingConfidence = confidence;
                    obj.SILResult.MappingMethod = mapMethod;
                    result = obj.SILResult;
                end

                obj.ActiveResult = result;
                obj.displayRuntimeResult(result);
                obj.plotDefaultRuntimeTrace(result);
                obj.status([obj.Mode ' simulation completed: ' result.Status]);
            catch ME
                obj.handleError(ME, 'Debug run');
            end
        end

        function compare(obj)
            if obj.Busy
                return;
            end

            try
                if isempty(obj.MILResult) || isempty(obj.SILResult)
                    error('SmartDebugger:MissingResults', ...
                        'Run MIL and SIL successfully before comparison.');
                end

                absTol = str2double(char(obj.AbsToleranceField.Value));
                relTol = str2double(char(obj.RelToleranceField.Value));
                if ~isscalar(absTol) || ~isfinite(absTol) || absTol < 0 || ...
                        ~isscalar(relTol) || ~isfinite(relTol) || relTol < 0
                    error('SmartDebugger:InvalidTolerance', ...
                        'Tolerances must be finite nonnegative numbers.');
                end

                report = obj.ComparisonEngine.compare( ...
                    obj.MILResult, obj.SILResult, absTol, relTol, ...
                    char(obj.AlignmentDropDown.Value));

                obj.ComparisonTable.Data = report.Table;
                obj.plotComparison(report);

                if strcmp(report.Status, 'PASS')
                    obj.FirstDivergenceLabel.Text = ...
                        'MIL vs SIL: PASS | No mismatch outside tolerance';
                else
                    fd = report.FirstDivergence;
                    if isnan(fd.Time)
                        obj.FirstDivergenceLabel.Text = ...
                            'MIL vs SIL: FAIL | Divergence detected';
                    else
                        obj.FirstDivergenceLabel.Text = sprintf( ...
                            'FIRST OBSERVED DIVERGENCE: %s / Port %d at t = %.12g s', ...
                            fd.Direction, fd.Port, fd.Time);
                    end
                end

                obj.status(['Comparison completed: ' report.Status]);
            catch ME
                obj.handleError(ME, 'MIL/SIL comparison');
            end
        end

        function navigateToBlock(obj)
            path = char(string(obj.BlockField.Value));
            if isempty(strtrim(path))
                return;
            end

            try
                open_system(path);
                try
                    hilite_system(path, 'find');
                catch
                end
                obj.status(['Opened: ' path]);
            catch ME
                obj.handleError(ME, 'Open selected block');
            end
        end

        function closeApp(obj)
            try
                if ~isempty(obj.SelectionTimer) && isvalid(obj.SelectionTimer)
                    stop(obj.SelectionTimer);
                    delete(obj.SelectionTimer);
                end
            catch
            end

            try
                if ~isempty(obj.UIFigure) && isvalid(obj.UIFigure)
                    delete(obj.UIFigure);
                end
            catch
            end
        end
    end

    methods (Access = private)
        function buildUI(obj)
            obj.UIFigure = uifigure( ...
                'Name', 'Smart Debugger', ...
                'Position', [70 50 1500 900], ...
                'CloseRequestFcn', @(~,~) obj.closeApp());

            root = uigridlayout(obj.UIFigure, [4 3]);
            root.RowHeight = {72, '1x', 250, 30};
            root.ColumnWidth = {310, '1x', 390};
            root.Padding = [8 8 8 8];
            root.RowSpacing = 8;
            root.ColumnSpacing = 8;

            obj.buildToolbar(root);
            obj.buildLeftPanel(root);
            obj.buildCenterPanel(root);
            obj.buildRightPanel(root);
            obj.buildPlotPanel(root);
            obj.buildStatusBar(root);
        end

        function buildToolbar(obj, parent)
            p = uipanel(parent);
            p.Layout.Row = 1;
            p.Layout.Column = [1 3];

            g = uigridlayout(p, [2 12]);
            g.RowHeight = {30 30};
            g.ColumnWidth = {82 220 82 220 75 82 92 92 92 80 90 '1x'};

            uibutton(g, 'Text', 'Open MIL', ...
                'ButtonPushedFcn', @(~,~) obj.chooseMIL());
            obj.MILModelField = uieditfield(g, 'text', ...
                'Placeholder', 'MIL model path');

            uibutton(g, 'Text', 'Open SIL', ...
                'ButtonPushedFcn', @(~,~) obj.chooseSIL());
            obj.SILModelField = uieditfield(g, 'text', ...
                'Placeholder', 'SIL model path');

            obj.ModeGroup = uidropdown(g, ...
                'Items', {'MIL','SIL'}, ...
                'Value', 'MIL', ...
                'ValueChangedFcn', @(s,~) obj.modeChanged(s));

            uibutton(g, 'Text', 'Import', ...
                'ButtonPushedFcn', @(~,~) obj.refreshBlockSelection());
            uibutton(g, 'Text', 'Inspect', ...
                'ButtonPushedFcn', @(~,~) obj.inspectBlock());
            uibutton(g, 'Text', 'Run Debug', ...
                'ButtonPushedFcn', @(~,~) obj.runDebug());
            uibutton(g, 'Text', 'Compare', ...
                'ButtonPushedFcn', @(~,~) obj.compare());

            obj.StopTimeField = uieditfield(g, 'text', 'Value', '10');
            uilabel(g, 'Text', 'Stop time');

            obj.StatusLabel = uilabel(g, 'Text', 'Ready');
            obj.StatusLabel.Layout.Row = 2;
            obj.StatusLabel.Layout.Column = [1 12];
        end

        function buildLeftPanel(obj, parent)
            p = uipanel(parent, 'Title', 'Model / Debug Target');
            p.Layout.Row = 2;
            p.Layout.Column = 1;

            g = uigridlayout(p, [9 1]);
            g.RowHeight = {22 '1x' 32 22 32 22 32 '1x' 32};

            uilabel(g, 'Text', 'Model hierarchy');
            obj.Tree = uitree(g, 'SelectionChangedFcn', ...
                @(~,e) obj.treeSelectionChanged(e));

            uibutton(g, 'Text', 'Refresh model tree', ...
                'ButtonPushedFcn', @(~,~) obj.refreshModelTree());
            uilabel(g, 'Text', 'MIL selected block');
            obj.BlockField = uieditfield(g, 'text', ...
                'Placeholder', 'model/subsystem/block');
            uibutton(g, 'Text', 'Open / Highlight', ...
                'ButtonPushedFcn', @(~,~) obj.navigateToBlock());
            uilabel(g, 'Text', 'SIL mapped block (optional override)');
            obj.SILBlockField = uieditfield(g, 'text', ...
                'Placeholder', 'SIL model/subsystem/block');
            uibutton(g, 'Text', 'Inspect selected block', ...
                'ButtonPushedFcn', @(~,~) obj.inspectBlock());
        end

        function buildCenterPanel(obj, parent)
            p = uipanel(parent, 'Title', 'Runtime Signals');
            p.Layout.Row = 2;
            p.Layout.Column = 2;

            g = uigridlayout(p, [4 1]);
            g.RowHeight = {'1x' '1x' '1x' 30};

            obj.InputsTable = uitable(g, ...
                'ColumnName', {'Port','Input Signal','Current Value','Data Type','Dimension','Sample Time'}, ...
                'RowName', {}, ...
                'ColumnEditable', false(1,6), ...
                'CellSelectionCallback', @(s,e) obj.runtimeSelection(s,e,'Input'));

            obj.OutputsTable = uitable(g, ...
                'ColumnName', {'Port','Output Signal','Current Value','Data Type','Dimension','Sample Time'}, ...
                'RowName', {}, ...
                'ColumnEditable', false(1,6), ...
                'CellSelectionCallback', @(s,e) obj.runtimeSelection(s,e,'Output'));

            obj.ComparisonTable = uitable(g, ...
                'ColumnName', {'Direction','Port','MIL Signal','SIL Signal','Status','Max Abs Error','Max Rel Error','First Mismatch'}, ...
                'RowName', {}, ...
                'ColumnEditable', false(1,8));

            obj.FirstDivergenceLabel = uilabel(g, ...
                'Text', 'No MIL/SIL comparison run yet', ...
                'FontWeight', 'bold');
        end

        function buildRightPanel(obj, parent)
            p = uipanel(parent, 'Title', 'Analysis / Diagnostics');
            p.Layout.Row = 2;
            p.Layout.Column = 3;

            g = uigridlayout(p, [8 2]);
            g.RowHeight = {22 28 22 28 22 28 '1x' 34};
            g.ColumnWidth = {145 '1x'};

            uilabel(g, 'Text', 'Absolute tolerance');
            obj.AbsToleranceField = uieditfield(g, 'text', 'Value', '1e-6');
            uilabel(g, 'Text', 'Relative tolerance');
            obj.RelToleranceField = uieditfield(g, 'text', 'Value', '1e-4');
            uilabel(g, 'Text', 'Time alignment');
            obj.AlignmentDropDown = uidropdown(g, ...
                'Items', {'linear','nearest','zoh'}, 'Value', 'linear');
            uilabel(g, 'Text', 'Compatibility');
            obj.CompatibilityLabel = uilabel(g, 'Text', 'Checking...');
            uilabel(g, 'Text', 'Selected block');
            obj.BlockInfoArea = uitextarea(g, ...
                'Editable', 'off', 'Value', {'No block selected.'});
            obj.BlockInfoArea.Layout.Row = [5 6];
            obj.BlockInfoArea.Layout.Column = 2;

            uilabel(g, 'Text', 'Diagnostics');
            obj.DiagnosticsArea = uitextarea(g, ...
                'Editable', 'off', 'Value', {'No diagnostics.'});
            obj.DiagnosticsArea.Layout.Row = 7;
            obj.DiagnosticsArea.Layout.Column = [1 2];

            uibutton(g, 'Text', 'Refresh diagnostics', ...
                'ButtonPushedFcn', @(~,~) obj.showDiagnostics());
            uibutton(g, 'Text', 'Clear diagnostics', ...
                'ButtonPushedFcn', @(~,~) obj.clearDiagnostics());
        end

        function buildPlotPanel(obj, parent)
            p = uipanel(parent, 'Title', 'MIL / SIL Trace');
            p.Layout.Row = 3;
            p.Layout.Column = [1 3];
            obj.PlotAxes = uiaxes(p, 'Position', [10 10 1470 205]);
            title(obj.PlotAxes, 'Selected signal comparison');
            xlabel(obj.PlotAxes, 'Time (s)');
            grid(obj.PlotAxes, 'on');
        end

        function buildStatusBar(obj, parent)
            p = uipanel(parent);
            p.Layout.Row = 4;
            p.Layout.Column = [1 3];
            g = uigridlayout(p, [1 2]);
            g.ColumnWidth = {'1x' 350};
            uilabel(g, 'Text', 'Smart Debugger | Live Simulink selection | MIL + SIL');
            uilabel(g, 'Text', '');
        end

        function chooseMIL(obj)
            [f,p] = uigetfile({'*.slx;*.mdl','Simulink Models (*.slx, *.mdl)'}, ...
                'Select MIL model');
            if isequal(f,0)
                return;
            end
            obj.setMILModel(fullfile(p,f));
        end

        function chooseSIL(obj)
            [f,p] = uigetfile({'*.slx;*.mdl','Simulink Models (*.slx, *.mdl)'}, ...
                'Select SIL model');
            if isequal(f,0)
                return;
            end
            obj.setSILModel(fullfile(p,f));
        end

        function modeChanged(obj, src)
            obj.Mode = char(src.Value);
            obj.status(['Mode: ' obj.Mode]);
        end

        function validateRunInputs(obj)
            if isempty(strtrim(obj.SelectedBlock))
                error('SmartDebugger:MissingBlock', ...
                    'Select a Simulink block first.');
            end

            stopTime = str2double(char(obj.StopTimeField.Value));
            if ~isscalar(stopTime) || ~isfinite(stopTime) || stopTime < 0
                error('SmartDebugger:InvalidStopTime', ...
                    'Stop time must be finite and nonnegative.');
            end

            if strcmpi(obj.Mode, 'SIL') && ...
                    isempty(strtrim(char(obj.SILModelField.Value)))
                error('SmartDebugger:MissingSILModel', ...
                    'Select a SIL model first.');
            end
        end

        function populatePorts(obj, info)
            obj.InputsTable.Data = obj.portRows(info.Inputs);
            obj.OutputsTable.Data = obj.portRows(info.Outputs);
        end

        function rows = portRows(obj, ports)
            if isempty(ports)
                rows = cell(0,6);
                return;
            end

            rows = cell(numel(ports),6);
            for k = 1:numel(ports)
                p = ports(k);
                rows{k,1} = p.Port;
                rows{k,2} = p.Name;
                rows{k,3} = obj.formatValue(p.Value);
                rows{k,4} = p.DataType;
                rows{k,5} = p.Dimension;
                rows{k,6} = p.SampleTime;
            end
        end

        function displayRuntimeResult(obj, result)
            if ~isstruct(result)
                return;
            end
            if isfield(result, 'Inputs')
                obj.InputsTable.Data = obj.portRows(result.Inputs);
            end
            if isfield(result, 'Outputs')
                obj.OutputsTable.Data = obj.portRows(result.Outputs);
            end
        end

        function runtimeSelection(obj, ~, event, direction)
            if isempty(event.Indices) || isempty(obj.ActiveResult)
                return;
            end

            row = event.Indices(1,1);
            if strcmpi(direction, 'Input') && row <= numel(obj.ActiveResult.Inputs)
                p = obj.ActiveResult.Inputs(row);
            elseif strcmpi(direction, 'Output') && row <= numel(obj.ActiveResult.Outputs)
                p = obj.ActiveResult.Outputs(row);
            else
                return;
            end

            obj.plotSingleRuntimeSeries(p, [direction ' ' p.Name]);
        end

        function plotSingleRuntimeSeries(obj, port, labelText)
            cla(obj.PlotAxes);
            series = port.Series;
            if isempty(series)
                title(obj.PlotAxes, [labelText ' | no runtime series captured']);
                return;
            end

            try
                t = series.Time;
                y = series.Data;
                plot(obj.PlotAxes, t, y);
                title(obj.PlotAxes, labelText);
                xlabel(obj.PlotAxes, 'Time (s)');
                grid(obj.PlotAxes, 'on');
            catch ME
                obj.DiagnosticsManager.recordException(ME, 'Plot runtime signal');
                obj.showDiagnostics();
            end
        end

        function plotDefaultRuntimeTrace(obj, result)
            if ~isstruct(result)
                return;
            end

            ports = [];
            if isfield(result, 'Outputs') && ~isempty(result.Outputs)
                ports = result.Outputs;
            elseif isfield(result, 'Inputs') && ~isempty(result.Inputs)
                ports = result.Inputs;
            end

            if ~isempty(ports)
                obj.plotSingleRuntimeSeries(ports(1), [obj.Mode ' ' ports(1).Name]);
            end
        end

        function plotComparison(obj, report)
            cla(obj.PlotAxes);
            if isempty(report.Time)
                title(obj.PlotAxes, 'No comparable signal data');
                return;
            end

            hold(obj.PlotAxes, 'on');
            plot(obj.PlotAxes, report.Time, report.MIL, 'DisplayName', 'MIL');
            plot(obj.PlotAxes, report.Time, report.SIL, 'DisplayName', 'SIL');
            hold(obj.PlotAxes, 'off');
            legend(obj.PlotAxes, 'show', 'Location', 'best');
            title(obj.PlotAxes, ['Comparison: ' report.Signal]);
            xlabel(obj.PlotAxes, 'Time (s)');
            grid(obj.PlotAxes, 'on');
        end

        function refreshModelTree(obj)
            delete(obj.Tree.Children);
            root = obj.ModelManager.Model;
            if isempty(root) || ~bdIsLoaded(root)
                return;
            end

            rootNode = uitreenode(obj.Tree, 'Text', root, 'NodeData', root);
            blocks = find_system(root, 'SearchDepth', 1, 'Type', 'Block');
            for k = 1:numel(blocks)
                path = blocks{k};
                if strcmp(path, root)
                    continue;
                end
                uitreenode(rootNode, 'Text', get_param(path, 'Name'), 'NodeData', path);
            end
        end

        function treeSelectionChanged(obj, event)
            if isempty(event.SelectedNodes)
                return;
            end
            node = event.SelectedNodes(1);
            if isempty(node.NodeData)
                return;
            end
            path = char(string(node.NodeData));
            if bdIsLoaded(bdroot(path)) && ~strcmp(path, bdroot(path))
                obj.setSelectedBlock(path);
            end
        end

        function startSelectionWatcher(obj)
            try
                obj.SelectionTimer = timer( ...
                    'ExecutionMode', 'fixedSpacing', ...
                    'Period', 0.75, ...
                    'BusyMode', 'drop', ...
                    'TimerFcn', @(~,~) obj.pollSelection());
                start(obj.SelectionTimer);
            catch ME
                obj.DiagnosticsManager.recordException(ME, 'Selection watcher');
            end
        end

        function pollSelection(obj)
            if obj.Busy || isempty(obj.UIFigure) || ~isvalid(obj.UIFigure)
                return;
            end

            try
                path = obj.ModelManager.currentSimulinkSelection();
                if isempty(path)
                    return;
                end
                if ~strcmp(path, obj.SelectedBlock)
                    obj.syncMILModelFromBlock(path);
                    obj.setSelectedBlock(path);
                end
            catch ME
                obj.DiagnosticsManager.recordException(ME, 'Selection watcher');
            end
        end

        function refreshBlockSelectionIfNeeded(obj)
            if isempty(strtrim(obj.SelectedBlock))
                obj.refreshBlockSelection();
                return;
            end

            try
                get_param(obj.SelectedBlock, 'Handle');
            catch
                obj.refreshBlockSelection();
            end
        end

        function model = resolveMILModel(obj)
            root = bdroot(obj.SelectedBlock);
            if bdIsLoaded(root)
                modelFile = '';
                try
                    modelFile = get_param(root, 'FileName');
                catch
                end
                if isempty(modelFile) || exist(modelFile, 'file') ~= 2
                    model = root;
                else
                    model = modelFile;
                end
            else
                model = char(obj.MILModelField.Value);
            end

            if isempty(model)
                error('SmartDebugger:MissingMILModel', ...
                    'No loaded MIL model could be resolved from the selected block.');
            end
        end

        function populateBlockInfo(obj, info)
            lines = { ...
                ['Path: ' info.Path], ...
                ['Name: ' info.Name], ...
                ['Block type: ' info.BlockType], ...
                ['Parent: ' info.Parent], ...
                ['Mask type: ' info.MaskType], ...
                ['Library link: ' info.LibraryLink]};

            if isfield(info, 'IsStateflow') && info.IsStateflow
                lines{end+1} = 'Stateflow: detected';
            end
            obj.BlockInfoArea.Value = lines;
        end

        function updateCompatibility(obj)
            try
                c = obj.CompatibilityManager.snapshot();
                targetLinkText = 'no';
                if c.TargetLinkAvailable
                    targetLinkText = 'yes';
                end
                obj.CompatibilityLabel.Text = sprintf( ...
                    'MATLAB %s | Simulink %s | TargetLink: %s', ...
                    c.MATLAB, c.Simulink, targetLinkText);
            catch ME
                obj.CompatibilityLabel.Text = 'Compatibility check failed';
                obj.DiagnosticsManager.recordException(ME, 'Compatibility');
            end
        end

        function showDiagnostics(obj)
            if ~isempty(obj.DiagnosticsArea) && isvalid(obj.DiagnosticsArea)
                obj.DiagnosticsArea.Value = obj.DiagnosticsManager.asCell();
            end
        end

        function clearDiagnostics(obj)
            obj.DiagnosticsManager.clear();
            obj.showDiagnostics();
        end

        function status(obj, message)
            if ~isempty(obj.StatusLabel) && isvalid(obj.StatusLabel)
                obj.StatusLabel.Text = char(message);
                drawnow limitrate;
            end
        end

        function handleError(obj, ME, stage)
            obj.DiagnosticsManager.recordException(ME, stage);
            obj.status([stage ': ' ME.message]);
            obj.showDiagnostics();
        end

        function setBusy(obj, value)
            obj.Busy = logical(value);
            if isempty(obj.UIFigure) || ~isvalid(obj.UIFigure)
                return;
            end
            try
                obj.ModeGroup.Enable = ~obj.Busy;
            catch
            end
        end

        function text = formatValue(~, value)
            if isempty(value)
                text = '';
                return;
            end
            if ischar(value)
                text = value;
                return;
            end
            try
                text = mat2str(value);
                if numel(text) > 120
                    text = [text(1:117) '...'];
                end
            catch
                text = class(value);
            end
        end
    end
end
