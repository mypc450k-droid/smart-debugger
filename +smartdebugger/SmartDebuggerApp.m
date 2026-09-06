classdef SmartDebuggerApp < handle
    %SMARTDEBUGGERAPP UI for live MIL/SIL debugging of Simulink blocks.

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
        SampleTable
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
        TreeModel = ''
        RunTargetBlock = ''
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
            addParameter(p, 'Model', '', @(x)ischar(x) || isstring(x));
            addParameter(p, 'SILModel', '', @(x)ischar(x) || isstring(x));
            parse(p, varargin{:});
            if ~isempty(strtrim(char(string(p.Results.Model))))
                obj.setMILModel(char(string(p.Results.Model)));
            end
            if ~isempty(strtrim(char(string(p.Results.SILModel))))
                obj.setSILModel(char(string(p.Results.SILModel)));
            end
        end

        function setMILModel(obj, model)
            try
                model = char(string(model));
                obj.ModelManager.loadModel(model);
                obj.MILModelField.Value = model;
                obj.refreshModelTree();
                obj.status(['MIL model ready: ' model ' | Select a block and click Import.']);
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
                if ~bdIsLoaded(root)
                    if isempty(ext)
                        if exist([root '.slx'], 'file') == 2 || exist([root '.mdl'], 'file') == 2
                            load_system(root);
                        else
                            error('SmartDebugger:SILModelNotFound', 'SIL model not found: %s', model);
                        end
                    elseif exist(model, 'file') == 2
                        load_system(model);
                    else
                        error('SmartDebugger:SILModelNotFound', 'SIL model file not found: %s', model);
                    end
                end
                obj.SILModelField.Value = model;
                obj.status(['SIL model ready: ' model]);
            catch ME
                obj.handleError(ME, 'Load SIL model');
            end
        end

        function refreshBlockSelection(obj)
            obj.importSelection(true);
        end

        function importSelection(obj, showMessage)
            if nargin < 2
                showMessage = true;
            end
            try
                path = obj.ModelManager.currentSimulinkSelection();
                if isempty(path)
                    candidate = char(string(obj.BlockField.Value));
                    if ~isempty(strtrim(candidate))
                        try
                            get_param(candidate, 'Handle');
                            path = candidate;
                        catch
                        end
                    end
                end
                if isempty(path)
                    if showMessage
                        obj.status('No block selected. Select a Simulink block, then click Import.');
                    end
                    return;
                end
                obj.attachToBlock(path, true);
            catch ME
                obj.handleError(ME, 'Import selection');
            end
        end

        function attachToBlock(obj, path, inspectNow)
            path = char(string(path));
            root = bdroot(path);
            if isempty(root) || ~bdIsLoaded(root)
                error('SmartDebugger:InvalidSelection', ...
                    'Selected block belongs to a model that is not loaded.');
            end
            obj.ModelManager.loadModel(root);
            obj.syncMILModelFromBlock(path);
            obj.SelectedBlock = path;
            obj.BlockField.Value = path;
            if ~strcmp(obj.TreeModel, root)
                obj.refreshModelTree();
            end
            if inspectNow
                obj.inspectBlock();
            else
                obj.status(['Selected: ' path]);
            end
        end

        function syncMILModelFromBlock(obj, path)
            root = bdroot(path);
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

        function inspectBlock(obj)
            path = char(string(obj.BlockField.Value));
            if isempty(strtrim(path))
                return;
            end
            try
                get_param(path, 'Handle');
            catch ME
                obj.handleError(ME, 'Inspect block');
                return;
            end
            info = obj.ModelManager.inspectBlock(path);
            if isempty(info)
                obj.status('Block inspection failed. See Diagnostics.');
                obj.showDiagnostics();
                return;
            end
            obj.SelectedBlock = path;
            obj.RunTargetBlock = path;
            obj.populatePorts(info);
            obj.populateBlockInfo(info);
            obj.status(['Selected: ' path]);
        end

        function runDebug(obj)
            if obj.Busy
                return;
            end

            snapshot = struct(...
                'Block', obj.SelectedBlock, ...
                'BlockField', char(string(obj.BlockField.Value)), ...
                'MILModel', char(string(obj.MILModelField.Value)), ...
                'SILBlock', obj.SelectedSILBlock, ...
                'SILBlockField', char(string(obj.SILBlockField.Value)));

            obj.RunTargetBlock = snapshot.Block;
            obj.setBusy(true);
            cleanupSelection = onCleanup(@()obj.restoreRunSelection(snapshot)); %#ok<NASGU>
            cleanupBusy = onCleanup(@()obj.setBusy(false)); %#ok<NASGU>

            try
                obj.ensureSelectedBlock();
                obj.validateRunInputs();
                stopTime = char(string(obj.StopTimeField.Value));

                if strcmpi(obj.Mode, 'MIL')
                    model = obj.resolveMILModel();
                    block = obj.RunTargetBlock;
                    obj.status(['Running MIL simulation for ' block ' ...']);
                    drawnow;
                    runResult = obj.SimulationManager.runMIL(model, block, stopTime);
                    obj.MILResult = runResult;
                else
                    silModel = char(string(obj.SILModelField.Value));
                    [silBlock, confidence, mapMethod, candidates] = ...
                        smartdebugger.ModelMapper.mapBlock(obj.RunTargetBlock, silModel);
                    if isempty(silBlock)
                        override = char(string(obj.SILBlockField.Value));
                        if isempty(strtrim(override))
                            error('SmartDebugger:SILMappingRequired', ...
                                'Automatic MIL-to-SIL mapping failed. Enter the SIL block path in the override field.');
                        end
                        silBlock = override;
                        confidence = 'USER_DEFINED';
                        mapMethod = 'USER_DEFINED';
                    end
                    if strcmpi(confidence, 'AMBIGUOUS')
                        error('SmartDebugger:AmbiguousSILMapping', ...
                            'SIL mapping is ambiguous. Candidates: %s', strjoin(candidates, ', '));
                    end
                    obj.SelectedSILBlock = silBlock;
                    obj.SILBlockField.Value = silBlock;
                    obj.status(['Running SIL simulation for ' silBlock ' ...']);
                    drawnow;
                    runResult = obj.SimulationManager.runSIL(silModel, silBlock, stopTime);
                    runResult.MappingConfidence = confidence;
                    runResult.MappingMethod = mapMethod;
                    obj.SILResult = runResult;
                end

                % All post-run UI code uses runResult. There is deliberately
                % no reference to a local simOut variable in this class.
                obj.ActiveResult = runResult;
                obj.displayRuntimeResult(runResult);
                obj.plotDefaultRuntimeTrace(runResult);
                obj.status([obj.Mode ' completed: ' runResult.Status ...
                    obj.optionalMessage(runResult.Message)]);
            catch ME
                obj.handleError(ME, 'Debug run');
            end
        end

        function compare(obj)
            try
                if isempty(obj.MILResult) || isempty(obj.SILResult)
                    error('SmartDebugger:MissingResults', ...
                        'Run MIL and SIL successfully before comparison.');
                end
                a = str2double(char(string(obj.AbsToleranceField.Value)));
                r = str2double(char(string(obj.RelToleranceField.Value)));
                if ~isscalar(a) || ~isfinite(a) || a < 0 || ...
                        ~isscalar(r) || ~isfinite(r) || r < 0
                    error('SmartDebugger:InvalidTolerance', ...
                        'Tolerances must be finite nonnegative numbers.');
                end
                report = obj.ComparisonEngine.compare(...
                    obj.MILResult, obj.SILResult, a, r, ...
                    char(string(obj.AlignmentDropDown.Value)));
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
                        obj.FirstDivergenceLabel.Text = sprintf(...
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
            obj.UIFigure = uifigure('Name', 'Smart Debugger', ...
                'Position', [50 40 1550 920], ...
                'CloseRequestFcn', @(~,~)obj.closeApp());
            root = uigridlayout(obj.UIFigure, [4 3]);
            root.RowHeight = {72, '1x', 290, 30};
            root.ColumnWidth = {360, '1x', 410};
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
            uibutton(g, 'Text', 'Open MIL', 'ButtonPushedFcn', @(~,~)obj.chooseMIL());
            obj.MILModelField = uieditfield(g, 'text', 'Placeholder', 'MIL model path');
            uibutton(g, 'Text', 'Open SIL', 'ButtonPushedFcn', @(~,~)obj.chooseSIL());
            obj.SILModelField = uieditfield(g, 'text', 'Placeholder', 'SIL model path');
            obj.ModeGroup = uidropdown(g, 'Items', {'MIL','SIL'}, 'Value', 'MIL', ...
                'ValueChangedFcn', @(s,~)obj.modeChanged(s));
            uibutton(g, 'Text', 'Import', 'ButtonPushedFcn', @(~,~)obj.refreshBlockSelection());
            uibutton(g, 'Text', 'Inspect', 'ButtonPushedFcn', @(~,~)obj.inspectBlock());
            uibutton(g, 'Text', 'Run Debug', 'ButtonPushedFcn', @(~,~)obj.runDebug());
            uibutton(g, 'Text', 'Compare', 'ButtonPushedFcn', @(~,~)obj.compare());
            obj.StopTimeField = uieditfield(g, 'text', 'Value', 'auto', ...
                'Placeholder', 'auto = model StopTime');
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
            uilabel(g, 'Text', 'Complete model hierarchy');
            obj.Tree = uitree(g, 'SelectionChangedFcn', @(~,e)obj.treeSelectionChanged(e));
            uibutton(g, 'Text', 'Refresh model tree', 'ButtonPushedFcn', @(~,~)obj.refreshModelTree());
            uilabel(g, 'Text', 'MIL selected block');
            obj.BlockField = uieditfield(g, 'text', 'Placeholder', 'model/subsystem/block');
            uibutton(g, 'Text', 'Open / Highlight', 'ButtonPushedFcn', @(~,~)obj.navigateToBlock());
            uilabel(g, 'Text', 'SIL mapped block (optional override)');
            obj.SILBlockField = uieditfield(g, 'text', 'Placeholder', 'SIL model/subsystem/block');
            uibutton(g, 'Text', 'Inspect selected block', 'ButtonPushedFcn', @(~,~)obj.inspectBlock());
        end

        function buildCenterPanel(obj, parent)
            p = uipanel(parent, 'Title', 'Runtime Signals');
            p.Layout.Row = 2;
            p.Layout.Column = 2;
            g = uigridlayout(p, [5 1]);
            g.RowHeight = {'1x' '1x' '1x' '1x' 30};
            obj.InputsTable = uitable(g, ...
                'ColumnName', {'Port','Input Signal','Current Value','Data Type','Dimension','Samples / Sample Time'}, ...
                'RowName', {}, 'ColumnEditable', false(1,6), ...
                'CellSelectionCallback', @(s,e)obj.runtimeSelection(s,e,'Input'));
            obj.OutputsTable = uitable(g, ...
                'ColumnName', {'Port','Output Signal','Current Value','Data Type','Dimension','Samples / Sample Time'}, ...
                'RowName', {}, 'ColumnEditable', false(1,6), ...
                'CellSelectionCallback', @(s,e)obj.runtimeSelection(s,e,'Output'));
            obj.ComparisonTable = uitable(g, ...
                'ColumnName', {'Direction','Port','MIL Signal','SIL Signal','Status','Max Abs Error','Max Rel Error','First Mismatch'}, ...
                'RowName', {}, 'ColumnEditable', false(1,8));
            obj.SampleTable = uitable(g, ...
                'ColumnName', {'Time (s)','Value'}, 'RowName', {}, ...
                'ColumnEditable', false(1,2));
            obj.FirstDivergenceLabel = uilabel(g, ...
                'Text', 'No MIL/SIL comparison run yet', 'FontWeight', 'bold');
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
            obj.AlignmentDropDown = uidropdown(g, 'Items', {'linear','nearest','zoh'}, 'Value', 'linear');
            uilabel(g, 'Text', 'Compatibility');
            obj.CompatibilityLabel = uilabel(g, 'Text', 'Checking...');
            uilabel(g, 'Text', 'Selected block');
            obj.BlockInfoArea = uitextarea(g, 'Editable', 'off', 'Value', {'No block selected.'});
            obj.BlockInfoArea.Layout.Row = [5 6];
            obj.BlockInfoArea.Layout.Column = 2;
            uilabel(g, 'Text', 'Diagnostics');
            obj.DiagnosticsArea = uitextarea(g, 'Editable', 'off', 'Value', {'No diagnostics.'});
            obj.DiagnosticsArea.Layout.Row = 7;
            obj.DiagnosticsArea.Layout.Column = [1 2];
            uibutton(g, 'Text', 'Refresh diagnostics', 'ButtonPushedFcn', @(~,~)obj.showDiagnostics());
            uibutton(g, 'Text', 'Clear diagnostics', 'ButtonPushedFcn', @(~,~)obj.clearDiagnostics());
        end

        function buildPlotPanel(obj, parent)
            p = uipanel(parent, 'Title', 'Runtime Trace | actual logged samples');
            p.Layout.Row = 3;
            p.Layout.Column = [1 3];
            obj.PlotAxes = uiaxes(p, 'Position', [10 10 1520 250]);
            title(obj.PlotAxes, 'Selected runtime signal');
            xlabel(obj.PlotAxes, 'Time (s)');
            ylabel(obj.PlotAxes, 'Value');
            grid(obj.PlotAxes, 'on');
        end

        function buildStatusBar(obj, parent)
            p = uipanel(parent);
            p.Layout.Row = 4;
            p.Layout.Column = [1 3];
            g = uigridlayout(p, [1 1]);
            uilabel(g, 'Text', 'Smart Debugger | live Simulink selection | runtime capture | MIL + SIL');
        end

        function chooseMIL(obj)
            [f,p] = uigetfile({'*.slx;*.mdl','Simulink Models (*.slx, *.mdl)'}, 'Select MIL model');
            if isequal(f,0), return; end
            obj.setMILModel(fullfile(p,f));
        end

        function chooseSIL(obj)
            [f,p] = uigetfile({'*.slx;*.mdl','Simulink Models (*.slx, *.mdl)'}, 'Select SIL model');
            if isequal(f,0), return; end
            obj.setSILModel(fullfile(p,f));
        end

        function modeChanged(obj, source)
            obj.Mode = char(string(source.Value));
            obj.status(['Mode: ' obj.Mode]);
        end

        function refreshModelTree(obj)
            root = '';
            try
                if ~isempty(obj.SelectedBlock)
                    root = bdroot(obj.SelectedBlock);
                end
            catch
            end
            if isempty(root)
                root = char(string(obj.MILModelField.Value));
                [~,root,~] = fileparts(root);
            end
            if isempty(root) || ~bdIsLoaded(root)
                obj.status('Load/select a MIL model before refreshing the hierarchy.');
                return;
            end
            try
                delete(obj.Tree.Children);
            catch
                try
                    obj.Tree.Children = matlab.ui.container.TreeNode.empty;
                catch
                end
            end
            obj.TreeModel = root;
            top = uitreenode(obj.Tree, 'Text', root, 'NodeData', root);
            obj.addTreeChildren(top, root);
            try
                expand(top);
            catch
            end
        end

        function addTreeChildren(obj, parentNode, parentPath)
            try
                children = find_system(parentPath, 'SearchDepth', 1, 'Type', 'Block');
            catch
                return;
            end
            for k = 1:numel(children)
                childPath = children{k};
                if strcmp(childPath, parentPath)
                    continue;
                end
                try
                    childName = get_param(childPath, 'Name');
                catch
                    childName = childPath;
                end
                node = uitreenode(parentNode, 'Text', childName, 'NodeData', childPath);
                try
                    bt = get_param(childPath, 'BlockType');
                    if strcmp(bt, 'SubSystem')
                        obj.addTreeChildren(node, childPath);
                    end
                catch
                end
            end
        end

        function treeSelectionChanged(obj, event)
            try
                node = event.SelectedNodes;
                if isempty(node), return; end
                path = node(1).NodeData;
                if ischar(path) || isstring(path)
                    obj.attachToBlock(char(string(path)), false);
                    obj.inspectBlock();
                end
            catch ME
                obj.handleError(ME, 'Tree selection');
            end
        end

        function populatePorts(obj, info)
            obj.InputsTable.Data = obj.portTableData(info.Inputs, false);
            obj.OutputsTable.Data = obj.portTableData(info.Outputs, false);
            obj.SampleTable.Data = cell(0,2);
        end

        function data = portTableData(~, ports, runtime)
            data = cell(numel(ports), 6);
            for k = 1:numel(ports)
                data{k,1} = ports(k).Port;
                data{k,2} = ports(k).Name;
                data{k,3} = '';
                data{k,4} = ports(k).DataType;
                data{k,5} = ports(k).Dimension;
                data{k,6} = ports(k).SampleTime;
                if runtime
                    data{k,3} = ports(k).ValueText;
                    data{k,4} = ports(k).DataType;
                    data{k,5} = ports(k).Dimension;
                    data{k,6} = ports(k).SampleTime;
                end
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
                lines{end+1} = 'Stateflow: supported object detected';
            end
            obj.BlockInfoArea.Value = lines;
        end

        function displayRuntimeResult(obj, result)
            obj.InputsTable.Data = obj.runtimeTableData(result.Inputs);
            obj.OutputsTable.Data = obj.runtimeTableData(result.Outputs);
            allPorts = [result.Inputs; result.Outputs];
            first = [];
            for k = 1:numel(allPorts)
                if ~isempty(allPorts(k).Series)
                    first = allPorts(k);
                    break;
                end
            end
            if ~isempty(first)
                obj.populateSampleTable(first);
            else
                obj.SampleTable.Data = cell(0,2);
            end
        end

        function data = runtimeTableData(obj, ports)
            data = cell(numel(ports), 6);
            for k = 1:numel(ports)
                data{k,1} = ports(k).Port;
                data{k,2} = ports(k).Name;
                data{k,3} = obj.formatValue(ports(k).Value);
                data{k,4} = ports(k).DataType;
                data{k,5} = ports(k).Dimension;
                data{k,6} = ports(k).SampleTime;
            end
        end

        function populateSampleTable(obj, port)
            try
                [t, y] = obj.seriesXY(port.Series);
                if isempty(t)
                    obj.SampleTable.Data = cell(0,2);
                    return;
                end
                n = numel(t);
                data = cell(n,2);
                for k = 1:n
                    data{k,1} = t(k);
                    data{k,2} = obj.formatValue(y(k));
                end
                obj.SampleTable.Data = data;
            catch ME
                obj.SampleTable.Data = cell(0,2);
                obj.DiagnosticsManager.recordException(ME, 'Display sample values');
            end
        end

        function runtimeSelection(obj, source, event, direction)
            try
                if isempty(event.Indices), return; end
                row = event.Indices(1);
                result = obj.ActiveResult;
                if isempty(result), return; end
                if strcmpi(direction, 'Input')
                    ports = result.Inputs;
                else
                    ports = result.Outputs;
                end
                if row < 1 || row > numel(ports), return; end
                port = ports(row);
                obj.plotRuntimeSignal(port);
                obj.populateSampleTable(port);
            catch ME
                obj.handleError(ME, 'Plot runtime signal');
            end
        end

        function plotDefaultRuntimeTrace(obj, result)
            cla(obj.PlotAxes);
            hold(obj.PlotAxes, 'on');
            allPorts = [result.Inputs; result.Outputs];
            plotted = false;
            names = {};
            for k = 1:numel(allPorts)
                if isempty(allPorts(k).Series), continue; end
                try
                    [t,y] = obj.seriesXY(allPorts(k).Series);
                    if isempty(t), continue; end
                    obj.plotSampleAccurate(t,y);
                    names{end+1} = allPorts(k).Name; %#ok<AGROW>
                    plotted = true;
                catch ME
                    obj.DiagnosticsManager.recordException(ME, ...
                        ['Plot ' allPorts(k).Name]);
                end
            end
            hold(obj.PlotAxes, 'off');
            if plotted
                legend(obj.PlotAxes, names, 'Interpreter', 'none', 'Location', 'best');
                title(obj.PlotAxes, 'Actual logged samples, first timestamp through last timestamp');
            else
                title(obj.PlotAxes, 'No runtime series captured');
            end
        end

        function plotRuntimeSignal(obj, port)
            cla(obj.PlotAxes);
            if isempty(port.Series)
                title(obj.PlotAxes, [port.Name ' | no runtime samples']);
                return;
            end
            try
                [t,y] = obj.seriesXY(port.Series);
                obj.plotSampleAccurate(t,y);
                title(obj.PlotAxes, [port.Name ' | ' num2str(numel(t)) ' actual samples']);
            catch ME
                obj.handleError(ME, 'Plot runtime signal');
            end
        end

        function plotSampleAccurate(obj, t, y)
            t = t(:);
            y = y(:);
            if isempty(t) || isempty(y), return; end
            n = min(numel(t), numel(y));
            t = t(1:n);
            y = y(1:n);
            if n >= 2
                d = diff(t);
                regular = all(abs(d - median(d)) <= max(1e-10, 1e-8*max(abs(median(d)),1)));
            else
                regular = false;
            end
            if islogical(y)
                yPlot = double(y);
            else
                yPlot = y;
            end
            if regular
                stairs(obj.PlotAxes, t, yPlot, 'Marker', '.', 'LineWidth', 1);
            else
                plot(obj.PlotAxes, t, yPlot, 'Marker', '.', 'LineStyle', '-');
            end
            if numel(t) > 1
                xlim(obj.PlotAxes, [t(1) t(end)]);
            else
                xlim(obj.PlotAxes, [t(1)-0.5 t(1)+0.5]);
            end
            xlabel(obj.PlotAxes, 'Time (s)');
            grid(obj.PlotAxes, 'on');
        end

        function [t,y] = seriesXY(~, series)
            t = [];
            y = [];
            if isempty(series), return; end
            t = series.Time(:);
            data = series.Data;
            if isempty(data), return; end
            if isvector(data)
                if numel(data) == numel(t)
                    y = data(:);
                elseif numel(t) == 1
                    y = data(1);
                    t = t(1);
                else
                    y = data(1:min(numel(data),numel(t)));
                    t = t(1:numel(y));
                end
            else
                sz = size(data);
                if sz(1) == numel(t)
                    y = data(:,1);
                elseif sz(end) == numel(t)
                    y = reshape(data, [], sz(end));
                    y = y(1,:).';
                    t = t(1:numel(y));
                else
                    y = data(:);
                    n = min(numel(t), numel(y));
                    y = y(1:n);
                    t = t(1:n);
                end
            end
            if iscell(y)
                y = cellfun(@double, y);
            end
            if ~isnumeric(y) && ~islogical(y)
                y = double(y);
            end
        end

        function plotComparison(obj, report)
            cla(obj.PlotAxes);
            try
                hold(obj.PlotAxes, 'on');
                if isfield(report, 'Time') && ~isempty(report.Time)
                    plot(obj.PlotAxes, report.Time, report.MIL, 'DisplayName', 'MIL');
                    plot(obj.PlotAxes, report.Time, report.SIL, 'DisplayName', 'SIL');
                    legend(obj.PlotAxes, 'show');
                end
                hold(obj.PlotAxes, 'off');
                title(obj.PlotAxes, 'MIL vs SIL');
            catch ME
                obj.DiagnosticsManager.recordException(ME, 'Plot comparison');
            end
        end

        function text = formatValue(~, value)
            if isempty(value)
                text = '';
                return;
            end
            try
                if isscalar(value)
                    if islogical(value)
                        text = char(string(value));
                    else
                        text = sprintf('%.12g', double(value));
                    end
                elseif ischar(value) || isstring(value)
                    text = char(string(value));
                else
                    text = mat2str(value, 8);
                end
            catch
                text = class(value);
            end
        end

        function text = optionalMessage(~, message)
            if isempty(message)
                text = '';
            else
                text = [' | ' char(string(message))];
            end
        end

        function ensureSelectedBlock(obj)
            path = char(string(obj.RunTargetBlock));
            if isempty(strtrim(path)), path = char(string(obj.SelectedBlock)); end
            if isempty(strtrim(path)), path = char(string(obj.BlockField.Value)); end
            if isempty(strtrim(path)), path = obj.ModelManager.currentSimulinkSelection(); end
            if isempty(path)
                error('SmartDebugger:MissingBlock', 'Select a Simulink block first.');
            end
            try
                get_param(path, 'Handle');
            catch
                error('SmartDebugger:InvalidBlock', 'Selected block is no longer valid: %s', path);
            end
            obj.SelectedBlock = path;
            obj.BlockField.Value = path;
            obj.RunTargetBlock = path;
        end

        function validateRunInputs(obj)
            if isempty(strtrim(obj.RunTargetBlock))
                error('SmartDebugger:MissingBlock', 'Select and import a Simulink block first.');
            end
            stopText = strtrim(char(string(obj.StopTimeField.Value)));
            if isempty(stopText) || strcmpi(stopText, 'auto') || strcmpi(stopText, 'auto (model)')
                if strcmpi(obj.Mode, 'SIL') && isempty(strtrim(char(string(obj.SILModelField.Value))))
                    error('SmartDebugger:MissingSILModel', 'Select a SIL model first.');
                end
                return;
            end
            stopValue = str2double(stopText);
            if ~isscalar(stopValue) || ~isfinite(stopValue) || stopValue < 0
                error('SmartDebugger:InvalidStopTime', ...
                    'Stop time must be a nonnegative number or "auto".');
            end
            if strcmpi(obj.Mode, 'SIL') && isempty(strtrim(char(string(obj.SILModelField.Value))))
                error('SmartDebugger:MissingSILModel', 'Select a SIL model first.');
            end
        end

        function model = resolveMILModel(obj)
            root = bdroot(obj.RunTargetBlock);
            if ~isempty(root) && bdIsLoaded(root)
                model = root;
            else
                model = char(string(obj.MILModelField.Value));
            end
            if isempty(strtrim(model))
                error('SmartDebugger:MissingMILModel', 'No MIL model could be resolved.');
            end
        end

        function restoreRunSelection(obj, snapshot)
            try
                obj.SelectedBlock = snapshot.Block;
                obj.BlockField.Value = snapshot.BlockField;
                obj.MILModelField.Value = snapshot.MILModel;
                obj.SelectedSILBlock = snapshot.SILBlock;
                obj.SILBlockField.Value = snapshot.SILBlockField;
                obj.RunTargetBlock = snapshot.Block;
            catch
            end
        end

        function setBusy(obj, value)
            obj.Busy = logical(value);
            try
                obj.ModeGroup.Enable = obj.enableText(~value);
                obj.StopTimeField.Enable = obj.enableText(~value);
            catch
            end
        end

        function value = enableText(~, tf)
            if tf, value = 'on'; else, value = 'off'; end
        end

        function status(obj, text)
            try
                obj.StatusLabel.Text = char(string(text));
                drawnow limitrate;
            catch
            end
        end

        function handleError(obj, ME, stage)
            obj.DiagnosticsManager.recordException(ME, stage);
            obj.status(['ERROR | ' stage ' | ' ME.message]);
            obj.showDiagnostics();
        end

        function showDiagnostics(obj)
            try
                obj.DiagnosticsArea.Value = obj.DiagnosticsManager.asCell();
            catch
            end
        end

        function clearDiagnostics(obj)
            obj.DiagnosticsManager.clear();
            obj.showDiagnostics();
        end

        function updateCompatibility(obj)
            try
                info = obj.CompatibilityManager.check();
                if isstruct(info) && isfield(info, 'Message')
                    obj.CompatibilityLabel.Text = char(string(info.Message));
                elseif ischar(info) || isstring(info)
                    obj.CompatibilityLabel.Text = char(string(info));
                else
                    obj.CompatibilityLabel.Text = 'Checked';
                end
            catch ME
                obj.CompatibilityLabel.Text = 'Compatibility check unavailable';
                obj.DiagnosticsManager.recordException(ME, 'Compatibility check');
            end
        end

        function startSelectionWatcher(obj)
            try
                obj.SelectionTimer = timer('ExecutionMode', 'fixedSpacing', ...
                    'Period', 0.75, 'BusyMode', 'drop', ...
                    'TimerFcn', @(~,~)obj.watchSelection());
                start(obj.SelectionTimer);
            catch ME
                obj.DiagnosticsManager.recordException(ME, 'Selection watcher');
            end
        end

        function watchSelection(obj)
            if obj.Busy, return; end
            try
                path = obj.ModelManager.currentSimulinkSelection();
                if isempty(path) || strcmp(path, obj.SelectedBlock), return; end
                obj.attachToBlock(path, true);
            catch
            end
        end
    end
end
