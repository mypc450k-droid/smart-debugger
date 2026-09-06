classdef SmartDebuggerApp < handle
    %SMARTDEBUGGERAPP Live Simulink MIL/SIL debugging UI.
    properties (SetAccess=private)
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

    properties (Access=private)
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

        function configure(obj,varargin)
            p = inputParser;
            addParameter(p,'Model','',@(x)ischar(x)||isstring(x));
            addParameter(p,'SILModel','',@(x)ischar(x)||isstring(x));
            parse(p,varargin{:});
            model = char(string(p.Results.Model));
            silModel = char(string(p.Results.SILModel));
            if ~isempty(strtrim(model))
                obj.setMILModel(model);
            end
            if ~isempty(strtrim(silModel))
                obj.setSILModel(silModel);
            end
        end

        function setMILModel(obj,model)
            try
                model = char(string(model));
                obj.ModelManager.loadModel(model);
                obj.MILModelField.Value = model;
                obj.refreshModelTree();
                % Do not import a global Simulink selection here. A selection
                % can belong to another open model, which was the source of
                % the previous "selected block changed" behavior.
                obj.status(['MIL model ready: ' model ' | Select a block and click Import.']);
            catch ME
                obj.handleError(ME,'Load MIL model');
            end
        end

        function setSILModel(obj,model)
            try
                model = char(string(model));
                if isempty(strtrim(model))
                    return;
                end
                [~,root,ext] = fileparts(model);
                if ~bdIsLoaded(root)
                    if isempty(ext)
                        load_system(root);
                    elseif exist(model,'file') == 2
                        load_system(model);
                    else
                        error('SmartDebugger:SILModelNotFound','SIL model file not found: %s',model);
                    end
                end
                obj.SILModelField.Value = model;
                obj.status(['SIL model ready: ' model]);
            catch ME
                obj.handleError(ME,'Load SIL model');
            end
        end

        function refreshBlockSelection(obj)
            obj.importSelection(true);
        end

        function importSelection(obj,showMessage)
            if nargin < 2
                showMessage = true;
            end
            try
                path = obj.ModelManager.currentSimulinkSelection();
                if isempty(path)
                    candidate = char(string(obj.BlockField.Value));
                    if ~isempty(strtrim(candidate))
                        try
                            get_param(candidate,'Handle');
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
                obj.attachToBlock(path,true);
            catch ME
                obj.handleError(ME,'Import selection');
            end
        end

        function attachToBlock(obj,path,inspectNow)
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
            if ~strcmp(obj.TreeModel,root)
                obj.refreshModelTree();
            end
            if inspectNow
                obj.inspectBlock();
            else
                obj.status(['Selected: ' path]);
            end
        end

        function syncMILModelFromBlock(obj,path)
            root = bdroot(path);
            modelFile = '';
            try
                modelFile = get_param(root,'FileName');
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
                get_param(path,'Handle');
            catch ME
                obj.handleError(ME,'Inspect block');
                return;
            end
            info = obj.ModelManager.inspectBlock(path);
            if isempty(info)
                obj.status('Block inspection failed. See Diagnostics.');
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

            % Freeze the exact debug target. TPT/Simulink may change the
            % editor selection while the test frame is executing, but that
            % must never change the target represented by this run.
            snapshot = struct(...
                'Block',obj.SelectedBlock, ...
                'BlockField',char(string(obj.BlockField.Value)), ...
                'MILModel',char(string(obj.MILModelField.Value)), ...
                'SILBlock',obj.SelectedSILBlock, ...
                'SILBlockField',char(string(obj.SILBlockField.Value)));
            obj.RunTargetBlock = snapshot.Block;

            obj.setBusy(true);
            restoreSelection = onCleanup(@()obj.restoreRunSelection(snapshot)); %#ok<NASGU>
            restoreBusy = onCleanup(@()obj.setBusy(false)); %#ok<NASGU>

            try
                obj.ensureSelectedBlock();
                obj.validateRunInputs();
                stopTime = char(string(obj.StopTimeField.Value));

                if strcmpi(obj.Mode,'MIL')
                    model = obj.resolveMILModel();
                    block = obj.RunTargetBlock;
                    obj.status(['Running MIL simulation for ' block ' ...']);
                    drawnow;
                    obj.MILResult = obj.SimulationManager.runMIL(model,block,stopTime);
                    result = obj.MILResult;
                else
                    silModel = char(obj.SILModelField.Value);
                    [silBlock,confidence,mapMethod,candidates] = ...
                        smartdebugger.ModelMapper.mapBlock(obj.RunTargetBlock,silModel);
                    if isempty(silBlock)
                        override = char(obj.SILBlockField.Value);
                        if isempty(strtrim(override))
                            error('SmartDebugger:SILMappingRequired', ...
                                'Automatic MIL-to-SIL mapping failed. Enter the SIL block path in the override field.');
                        end
                        silBlock = override;
                        confidence = 'USER_DEFINED';
                        mapMethod = 'USER_DEFINED';
                    end
                    if strcmp(confidence,'AMBIGUOUS')
                        error('SmartDebugger:AmbiguousSILMapping', ...
                            'SIL mapping is ambiguous. Candidates: %s',strjoin(candidates,', '));
                    end
                    obj.SelectedSILBlock = silBlock;
                    obj.SILBlockField.Value = silBlock;
                    obj.status(['Running SIL simulation for ' silBlock ' ...']);
                    drawnow;
                    obj.SILResult = obj.SimulationManager.runSIL(silModel,silBlock,stopTime);
                    obj.SILResult.MappingConfidence = confidence;
                    obj.SILResult.MappingMethod = mapMethod;
                    result = obj.SILResult;
                end

                obj.ActiveResult = result;
                if ~isempty(result)
                    obj.displayRuntimeResult(result);
                    obj.plotDefaultRuntimeTrace(result);
                end

                if isfield(result,'Message') && ~isempty(result.Message)
                    obj.status([obj.Mode ' completed: ' result.Status ' | ' result.Message]);
                else
                    obj.status([obj.Mode ' simulation completed: ' result.Status]);
                end
            catch ME
                % Keep the last successful runtime tables visible. Diagnostics
                % are appended, never cleared, when a run fails.
                obj.handleError(ME,'Debug run');
            end
        end

        function ensureSelectedBlock(obj)
            path = char(string(obj.RunTargetBlock));
            if isempty(strtrim(path))
                path = char(string(obj.SelectedBlock));
            end
            if isempty(strtrim(path))
                path = char(string(obj.BlockField.Value));
            end
            if isempty(strtrim(path))
                path = obj.ModelManager.currentSimulinkSelection();
            end
            if isempty(path)
                error('SmartDebugger:MissingBlock','Select a Simulink block first.');
            end
            try
                get_param(path,'Handle');
            catch
                error('SmartDebugger:InvalidBlock','Selected block is no longer valid: %s',path);
            end
            obj.SelectedBlock = path;
            obj.BlockField.Value = path;
            obj.RunTargetBlock = path;
        end

        function validateRunInputs(obj)
            if isempty(strtrim(obj.RunTargetBlock))
                error('SmartDebugger:MissingBlock','Select and import a Simulink block first.');
            end
            stopText = strtrim(char(string(obj.StopTimeField.Value)));
            if isempty(stopText) || strcmpi(stopText,'auto') || strcmpi(stopText,'auto (model)')
                return;
            end
            stopTime = str2double(stopText);
            if ~isscalar(stopTime) || ~isfinite(stopTime) || stopTime < 0
                error('SmartDebugger:InvalidStopTime', ...
                    'Stop time must be a nonnegative number or "auto".');
            end
            if strcmpi(obj.Mode,'SIL') && isempty(strtrim(char(obj.SILModelField.Value)))
                error('SmartDebugger:MissingSILModel','Select a SIL model first.');
            end
        end

        function model = resolveMILModel(obj)
            root = bdroot(obj.RunTargetBlock);
            if bdIsLoaded(root)
                model = root;
            else
                model = char(obj.MILModelField.Value);
            end
            if isempty(model)
                error('SmartDebugger:MissingMILModel','No MIL model could be resolved.');
            end
        end

        function compare(obj)
            try
                if isempty(obj.MILResult) || isempty(obj.SILResult)
                    error('SmartDebugger:MissingResults','Run MIL and SIL successfully before comparison.');
                end
                a = str2double(char(obj.AbsToleranceField.Value));
                r = str2double(char(obj.RelToleranceField.Value));
                if ~isscalar(a) || ~isfinite(a) || a < 0 || ~isscalar(r) || ~isfinite(r) || r < 0
                    error('SmartDebugger:InvalidTolerance','Tolerances must be finite nonnegative numbers.');
                end
                report = obj.ComparisonEngine.compare(obj.MILResult,obj.SILResult,a,r,char(obj.AlignmentDropDown.Value));
                obj.ComparisonTable.Data = report.Table;
                obj.plotComparison(report);
                if strcmp(report.Status,'PASS')
                    obj.FirstDivergenceLabel.Text = 'MIL vs SIL: PASS | No mismatch outside tolerance';
                else
                    fd = report.FirstDivergence;
                    if isnan(fd.Time)
                        obj.FirstDivergenceLabel.Text = 'MIL vs SIL: FAIL | Divergence detected';
                    else
                        obj.FirstDivergenceLabel.Text = sprintf( ...
                            'FIRST OBSERVED DIVERGENCE: %s / Port %d at t = %.12g s', ...
                            fd.Direction,fd.Port,fd.Time);
                    end
                end
                obj.status(['Comparison completed: ' report.Status]);
            catch ME
                obj.handleError(ME,'MIL/SIL comparison');
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
                    hilite_system(path,'find');
                catch
                end
                obj.status(['Opened: ' path]);
            catch ME
                obj.handleError(ME,'Open selected block');
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

    methods (Access=private)
        function buildUI(obj)
            obj.UIFigure = uifigure('Name','Smart Debugger', ...
                'Position',[50 40 1550 920], ...
                'CloseRequestFcn',@(~,~)obj.closeApp());
            root = uigridlayout(obj.UIFigure,[4 3]);
            root.RowHeight = {72,'1x',250,30};
            root.ColumnWidth = {360,'1x',410};
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

        function buildToolbar(obj,parent)
            p = uipanel(parent);
            p.Layout.Row = 1;
            p.Layout.Column = [1 3];
            g = uigridlayout(p,[2 12]);
            g.RowHeight = {30,30};
            g.ColumnWidth = {82,220,82,220,75,82,92,92,92,80,90,'1x'};
            uibutton(g,'Text','Open MIL','ButtonPushedFcn',@(~,~)obj.chooseMIL());
            obj.MILModelField = uieditfield(g,'text','Placeholder','MIL model path');
            uibutton(g,'Text','Open SIL','ButtonPushedFcn',@(~,~)obj.chooseSIL());
            obj.SILModelField = uieditfield(g,'text','Placeholder','SIL model path');
            obj.ModeGroup = uidropdown(g,'Items',{'MIL','SIL'},'Value','MIL', ...
                'ValueChangedFcn',@(s,~)obj.modeChanged(s));
            uibutton(g,'Text','Import','ButtonPushedFcn',@(~,~)obj.refreshBlockSelection());
            uibutton(g,'Text','Inspect','ButtonPushedFcn',@(~,~)obj.inspectBlock());
            uibutton(g,'Text','Run Debug','ButtonPushedFcn',@(~,~)obj.runDebug());
            uibutton(g,'Text','Compare','ButtonPushedFcn',@(~,~)obj.compare());
            obj.StopTimeField = uieditfield(g,'text','Value','auto', ...
                'Placeholder','auto = model StopTime');
            uilabel(g,'Text','Stop time');
            obj.StatusLabel = uilabel(g,'Text','Ready');
            obj.StatusLabel.Layout.Row = 2;
            obj.StatusLabel.Layout.Column = [1 12];
        end

        function buildLeftPanel(obj,parent)
            p = uipanel(parent,'Title','Model / Debug Target');
            p.Layout.Row = 2;
            p.Layout.Column = 1;
            g = uigridlayout(p,[9 1]);
            g.RowHeight = {22,'1x',32,22,32,22,32,'1x',32};
            uilabel(g,'Text','Complete model hierarchy');
            obj.Tree = uitree(g,'SelectionChangedFcn',@(~,e)obj.treeSelectionChanged(e));
            uibutton(g,'Text','Refresh model tree','ButtonPushedFcn',@(~,~)obj.refreshModelTree());
            uilabel(g,'Text','MIL selected block');
            obj.BlockField = uieditfield(g,'text','Placeholder','model/subsystem/block');
            uibutton(g,'Text','Open / Highlight','ButtonPushedFcn',@(~,~)obj.navigateToBlock());
            uilabel(g,'Text','SIL mapped block (optional override)');
            obj.SILBlockField = uieditfield(g,'text','Placeholder','SIL model/subsystem/block');
            uibutton(g,'Text','Inspect selected block','ButtonPushedFcn',@(~,~)obj.inspectBlock());
        end

        function buildCenterPanel(obj,parent)
            p = uipanel(parent,'Title','Runtime Signals');
            p.Layout.Row = 2;
            p.Layout.Column = 2;
            g = uigridlayout(p,[4 1]);
            g.RowHeight = {'1x','1x','1x',30};
            obj.InputsTable = uitable(g,'ColumnName', ...
                {'Port','Input Signal','Current Value','Data Type','Dimension','Sample Time'}, ...
                'RowName',{},'ColumnEditable',false(1,6), ...
                'CellSelectionCallback',@(s,e)obj.runtimeSelection(s,e,'Input'));
            obj.OutputsTable = uitable(g,'ColumnName', ...
                {'Port','Output Signal','Current Value','Data Type','Dimension','Sample Time'}, ...
                'RowName',{},'ColumnEditable',false(1,6), ...
                'CellSelectionCallback',@(s,e)obj.runtimeSelection(s,e,'Output'));
            obj.ComparisonTable = uitable(g,'ColumnName', ...
                {'Direction','Port','MIL Signal','SIL Signal','Status','Max Abs Error','Max Rel Error','First Mismatch'}, ...
                'RowName',{},'ColumnEditable',false(1,8));
            obj.FirstDivergenceLabel = uilabel(g,'Text','No MIL/SIL comparison run yet','FontWeight','bold');
        end

        function buildRightPanel(obj,parent)
            p = uipanel(parent,'Title','Analysis / Diagnostics');
            p.Layout.Row = 2;
            p.Layout.Column = 3;
            g = uigridlayout(p,[8 2]);
            g.RowHeight = {22,28,22,28,22,28,'1x',34};
            g.ColumnWidth = {145,'1x'};
            uilabel(g,'Text','Absolute tolerance');
            obj.AbsToleranceField = uieditfield(g,'text','Value','1e-6');
            uilabel(g,'Text','Relative tolerance');
            obj.RelToleranceField = uieditfield(g,'text','Value','1e-4');
            uilabel(g,'Text','Time alignment');
            obj.AlignmentDropDown = uidropdown(g,'Items',{'linear','nearest','zoh'},'Value','linear');
            uilabel(g,'Text','Compatibility');
            obj.CompatibilityLabel = uilabel(g,'Text','Checking...');
            uilabel(g,'Text','Selected block');
            obj.BlockInfoArea = uitextarea(g,'Editable','off','Value',{'No block selected.'});
            obj.BlockInfoArea.Layout.Row = [5 6];
            obj.BlockInfoArea.Layout.Column = 2;
            uilabel(g,'Text','Diagnostics');
            obj.DiagnosticsArea = uitextarea(g,'Editable','off','Value',{'No diagnostics.'});
            obj.DiagnosticsArea.Layout.Row = 7;
            obj.DiagnosticsArea.Layout.Column = [1 2];
            uibutton(g,'Text','Refresh diagnostics','ButtonPushedFcn',@(~,~)obj.showDiagnostics());
            uibutton(g,'Text','Clear diagnostics','ButtonPushedFcn',@(~,~)obj.clearDiagnostics());
        end

        function buildPlotPanel(obj,parent)
            p = uipanel(parent,'Title','MIL / SIL Trace');
            p.Layout.Row = 3;
            p.Layout.Column = [1 3];
            obj.PlotAxes = uiaxes(p,'Position',[10 10 1520 205]);
            title(obj.PlotAxes,'Selected signal comparison');
            xlabel(obj.PlotAxes,'Time (s)');
            grid(obj.PlotAxes,'on');
        end

        function buildStatusBar(obj,parent)
            p = uipanel(parent);
            p.Layout.Row = 4;
            p.Layout.Column = [1 3];
            g = uigridlayout(p,[1 1]);
            uilabel(g,'Text','Smart Debugger | live Simulink selection | runtime capture | MIL + SIL');
        end

        function chooseMIL(obj)
            [f,p] = uigetfile({'*.slx;*.mdl','Simulink Models (*.slx, *.mdl)'},'Select MIL model');
            if isequal(f,0)
                return;
            end
            obj.setMILModel(fullfile(p,f));
        end

        function chooseSIL(obj)
            [f,p] = uigetfile({'*.slx;*.mdl','Simulink Models (*.slx, *.mdl)'},'Select SIL model');
            if isequal(f,0)
                return;
            end
            obj.setSILModel(fullfile(p,f));
        end

        function modeChanged(obj,source)
            obj.Mode = char(source.Value);
            obj.status(['Mode: ' obj.Mode]);
        end

        function refreshModelTree(obj)
            root = '';
            if ~isempty(obj.ModelManager.Model)
                root = char(obj.ModelManager.Model);
            end
            if isempty(root)
                candidate = char(string(obj.MILModelField.Value));
                if ~isempty(strtrim(candidate))
                    [~,root,~] = fileparts(candidate);
                end
            end
            if isempty(root) || ~bdIsLoaded(root)
                obj.TreeModel = '';
                obj.Tree.Children = matlab.ui.container.TreeNode.empty;
                return;
            end

            obj.TreeModel = root;
            obj.Tree.Children = matlab.ui.container.TreeNode.empty;
            top = uitreenode(obj.Tree,'Text',root,'NodeData',root);
            obj.addTreeChildren(top,root);
            obj.expandTreeNodeRecursive(top);
        end

        function addTreeChildren(obj,parentNode,parentPath)
            try
                blocks = find_system(parentPath,'SearchDepth',1,'Type','Block', ...
                    'LookUnderMasks','all','FollowLinks','off');
            catch
                try
                    blocks = find_system(parentPath,'SearchDepth',1,'Type','Block');
                catch
                    blocks = {};
                end
            end
            for k = 1:numel(blocks)
                path = blocks{k};
                if strcmp(path,parentPath)
                    continue;
                end
                try
                    nodeText = get_param(path,'Name');
                catch
                    nodeText = path;
                end
                node = uitreenode(parentNode,'Text',nodeText,'NodeData',path);
                obj.addTreeChildren(node,path);
            end
        end

        function expandTreeNodeRecursive(~,node)
            try
                expand(node);
            catch
            end
            try
                children = node.Children;
                for k = 1:numel(children)
                    % Only nodes with descendants need expansion, but expanding
                    % atomic blocks is harmless and makes the hierarchy fully
                    % visible when the tree is first loaded.
                    expandTreeNodeRecursive([],children(k));
                end
            catch
            end
        end

        function treeSelectionChanged(obj,event)
            try
                nodes = event.SelectedNodes;
                if isempty(nodes)
                    return;
                end
                path = char(string(nodes(1).NodeData));
                if isempty(path)
                    return;
                end
                % Tree navigation must not trigger a TargetLink compile on
                % every click. Import/Inspect performs the expensive inspection.
                obj.attachToBlock(path,false);
            catch ME
                obj.handleError(ME,'Tree selection');
            end
        end

        function startSelectionWatcher(obj)
            obj.SelectionTimer = timer('ExecutionMode','fixedSpacing', ...
                'Period',0.75,'BusyMode','drop', ...
                'TimerFcn',@(~,~)obj.pollSelection());
            start(obj.SelectionTimer);
        end

        function pollSelection(obj)
            if obj.Busy || isempty(obj.UIFigure) || ~isvalid(obj.UIFigure)
                return;
            end
            try
                path = obj.ModelManager.currentSimulinkSelection();
                if isempty(path) || strcmp(path,obj.SelectedBlock)
                    return;
                end
                obj.syncMILModelFromBlock(path);
                obj.SelectedBlock = path;
                obj.BlockField.Value = path;
                obj.status(['Simulink selection detected: ' path ' | click Import to inspect']);
            catch
            end
        end

        function populatePorts(obj,info)
            obj.InputsTable.Data = obj.portTable(info.Inputs);
            obj.OutputsTable.Data = obj.portTable(info.Outputs);
        end

        function data = portTable(~,ports)
            data = cell(numel(ports),6);
            for k = 1:numel(ports)
                data{k,1} = ports(k).Port;
                data{k,2} = ports(k).Name;
                data{k,3} = '';
                data{k,4} = ports(k).DataType;
                data{k,5} = ports(k).Dimension;
                data{k,6} = ports(k).SampleTime;
            end
        end

        function populateBlockInfo(obj,info)
            lines = { ...
                ['Path: ' info.Path] ...
                ['Name: ' info.Name] ...
                ['Block Type: ' info.BlockType] ...
                ['Parent: ' info.Parent] ...
                ['Mask: ' info.MaskType] ...
                ['Library: ' info.LibraryLink]};
            obj.BlockInfoArea.Value = lines;
        end

        function displayRuntimeResult(obj,result)
            % Never clear diagnostics or successful runtime data merely because
            % a new run is starting. A failed TPT run can still return partial
            % SimulationOutput when CaptureErrors is enabled for MIL.
            if isfield(result,'Inputs') && ~isempty(result.Inputs)
                obj.InputsTable.Data = obj.runtimeTable(result.Inputs);
            end
            if isfield(result,'Outputs') && ~isempty(result.Outputs)
                obj.OutputsTable.Data = obj.runtimeTable(result.Outputs);
            end
            obj.showDiagnostics();
        end

        function data = runtimeTable(~,ports)
            data = cell(numel(ports),6);
            for k = 1:numel(ports)
                data{k,1} = ports(k).Port;
                data{k,2} = ports(k).Name;
                data{k,3} = ports(k).Value;
                data{k,4} = ports(k).DataType;
                data{k,5} = ports(k).Dimension;
                data{k,6} = ports(k).SampleTime;
            end
        end

        function plotDefaultRuntimeTrace(obj,result)
            cla(obj.PlotAxes);
            allPorts = [result.Inputs result.Outputs];
            plotted = false;
            for k = 1:numel(allPorts)
                try
                    if ~isempty(allPorts(k).Series)
                        ts = allPorts(k).Series;
                        plot(obj.PlotAxes,ts.Time,ts.Data,'DisplayName',allPorts(k).Name);
                        hold(obj.PlotAxes,'on');
                        plotted = true;
                    end
                catch
                end
            end
            hold(obj.PlotAxes,'off');
            if plotted
                legend(obj.PlotAxes,'show','Location','best');
            else
                legend(obj.PlotAxes,'off');
            end
        end

        function plotComparison(obj,report)
            cla(obj.PlotAxes);
            try
                plot(obj.PlotAxes,report.Time,report.MIL,'DisplayName','MIL');
                hold(obj.PlotAxes,'on');
                plot(obj.PlotAxes,report.Time,report.SIL,'DisplayName','SIL');
                hold(obj.PlotAxes,'off');
                legend(obj.PlotAxes,'show','Location','best');
            catch
            end
        end

        function runtimeSelection(obj,~,event,direction)
            try
                if isempty(event.Indices)
                    return;
                end
                row = event.Indices(1);
                ports = [];
                if strcmpi(direction,'Input') && ~isempty(obj.ActiveResult)
                    ports = obj.ActiveResult.Inputs;
                elseif strcmpi(direction,'Output') && ~isempty(obj.ActiveResult)
                    ports = obj.ActiveResult.Outputs;
                end
                if row <= numel(ports) && ~isempty(ports(row).Series)
                    ts = ports(row).Series;
                    cla(obj.PlotAxes);
                    plot(obj.PlotAxes,ts.Time,ts.Data,'DisplayName',ports(row).Name);
                    legend(obj.PlotAxes,'show');
                end
            catch
            end
        end

        function updateCompatibility(obj)
            try
                c = obj.CompatibilityManager.snapshot();
                targetLink = 'no';
                if c.TargetLinkAvailable
                    targetLink = 'yes';
                end
                obj.CompatibilityLabel.Text = sprintf( ...
                    'MATLAB %s | Simulink %s | TargetLink: %s', ...
                    c.MATLAB,c.Simulink,targetLink);
            catch ME
                obj.CompatibilityLabel.Text = 'Compatibility check failed';
                obj.DiagnosticsManager.recordException(ME,'Compatibility');
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

        function status(obj,message)
            if ~isempty(obj.StatusLabel) && isvalid(obj.StatusLabel)
                obj.StatusLabel.Text = char(message);
                drawnow limitrate;
            end
        end

        function handleError(obj,ME,stage)
            obj.DiagnosticsManager.recordException(ME,stage);
            obj.status([stage ': ' ME.message]);
            obj.showDiagnostics();
        end

        function setBusy(obj,value)
            obj.Busy = logical(value);
            if isempty(obj.UIFigure) || ~isvalid(obj.UIFigure)
                return;
            end
            try
                obj.ModeGroup.Enable = ~obj.Busy;
            catch
            end
        end

        function restoreRunSelection(obj,snapshot)
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
    end
end
