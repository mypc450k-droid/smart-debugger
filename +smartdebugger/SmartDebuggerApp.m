classdef SmartDebuggerApp < handle
    %SMARTDEBUGGERAPP Professional programmatic Smart Debugger UI.

    properties (SetAccess=private)
        UIFigure
        ModelManager
        SimulationManager
        ComparisonEngine
        DiagnosticsManager
        CompatibilityManager
        Mode = "MIL"
        SelectedBlock = ""
        SelectedSILBlock = ""
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
        ActiveResult
        Busy = false
    end

    methods
        function obj = SmartDebuggerApp(varargin)
            obj.DiagnosticsManager=smartdebugger.DiagnosticsManager();
            obj.CompatibilityManager=smartdebugger.CompatibilityManager();
            obj.ModelManager=smartdebugger.ModelManager(obj.DiagnosticsManager);
            obj.SimulationManager=smartdebugger.SimulationManager(obj.DiagnosticsManager);
            obj.ComparisonEngine=smartdebugger.ComparisonEngine();
            obj.buildUI();
            obj.updateCompatibility();
            obj.startSelectionWatcher();
            if ~isempty(varargin), obj.configure(varargin{:}); end
        end

        function configure(obj,varargin)
            p=inputParser;
            addParameter(p,'Model','',@(x)ischar(x)||isstring(x));
            addParameter(p,'SILModel','',@(x)ischar(x)||isstring(x));
            parse(p,varargin{:});
            if strlength(string(p.Results.Model))>0, obj.setMILModel(p.Results.Model); end
            if strlength(string(p.Results.SILModel))>0, obj.setSILModel(p.Results.SILModel); end
        end

        function setMILModel(obj,model)
            try
                obj.ModelManager.loadModel(model);
                obj.MILModelField.Value=char(model);
                obj.refreshModelTree();
                obj.refreshBlockSelection();
                obj.status("MIL model loaded: " + string(model));
            catch ME
                obj.handleError(ME,'Load MIL model');
            end
        end

        function setSILModel(obj,model)
            try
                model=char(string(model));
                if isempty(strtrim(model)), return; end
                [~,root,ext]=fileparts(model);
                if isempty(ext) && ~bdIsLoaded(root), load_system(root); elseif ~isempty(ext), load_system(model); end
                obj.SILModelField.Value=model;
                obj.status("SIL model ready: " + string(model));
            catch ME
                obj.handleError(ME,'Load SIL model');
            end
        end

        function refreshBlockSelection(obj)
            try
                path=obj.ModelManager.currentSimulinkSelection();
                if isempty(path)
                    obj.status('No selected Simulink block. Select one in the model, then click Import.');
                    return;
                end
                obj.setSelectedBlock(path);
            catch ME
                obj.handleError(ME,'Import selection');
            end
        end

        function setSelectedBlock(obj,path)
            path=char(string(path));
            if isempty(path), return; end
            obj.SelectedBlock=string(path);
            obj.BlockField.Value=path;
            obj.inspectBlock();
        end

        function inspectBlock(obj)
            path=strtrim(string(obj.BlockField.Value));
            if path=="", return; end
            info=obj.ModelManager.inspectBlock(char(path));
            if isempty(info)
                obj.status('Unable to inspect selected block. See Diagnostics.');
                obj.showDiagnostics();
                return;
            end
            obj.SelectedBlock=path;
            obj.populatePorts(info);
            obj.populateBlockInfo(info);
            obj.status("Selected: " + path);
        end

        function runDebug(obj)
            if obj.Busy, return; end
            obj.setBusy(true);
            try
                obj.validateRunInputs();
                obj.inspectBlock();
                stopTime=strtrim(string(obj.StopTimeField.Value));
                if obj.Mode=="MIL"
                    model=char(obj.MILModelField.Value);
                    block=char(obj.SelectedBlock);
                    obj.MILResult=obj.SimulationManager.runMIL(model,block,stopTime);
                    result=obj.MILResult;
                else
                    silModel=char(obj.SILModelField.Value);
                    [silBlock,confidence,mapMethod,candidates]= ...
                        smartdebugger.ModelMapper.mapBlock(char(obj.SelectedBlock),silModel);
                    if isempty(silBlock)
                        if strlength(string(obj.SILBlockField.Value))>0
                            silBlock=char(obj.SILBlockField.Value);
                            confidence='USER_DEFINED'; mapMethod='USER_DEFINED';
                        else
                            error('SmartDebugger:SILMappingRequired', ...
                                'Automatic MIL-to-SIL mapping failed. Specify the SIL block path manually.');
                        end
                    end
                    if strcmp(confidence,'AMBIGUOUS')
                        error('SmartDebugger:AmbiguousSILMapping', ...
                            'SIL mapping is ambiguous. Candidates: %s',strjoin(candidates,', '));
                    end
                    obj.SelectedSILBlock=string(silBlock);
                    obj.SILBlockField.Value=silBlock;
                    obj.SILResult=obj.SimulationManager.runSIL(silModel,silBlock,stopTime);
                    obj.SILResult.MappingConfidence=confidence;
                    obj.SILResult.MappingMethod=mapMethod;
                    result=obj.SILResult;
                end
                obj.ActiveResult=result;
                obj.displayRuntimeResult(result);
                obj.plotDefaultRuntimeTrace(result);
                obj.status(obj.Mode + " simulation completed: " + string(result.Status));
            catch ME
                obj.handleError(ME,'Debug run');
            end
            obj.setBusy(false);
        end

        function compare(obj)
            if obj.Busy, return; end
            try
                if isempty(obj.MILResult) || isempty(obj.SILResult)
                    error('SmartDebugger:MissingResults','Run MIL and SIL successfully before comparison.');
                end
                a=str2double(obj.AbsToleranceField.Value);
                r=str2double(obj.RelToleranceField.Value);
                if isnan(a) || isnan(r) || ~isfinite(a) || ~isfinite(r) || a<0 || r<0
                    error('SmartDebugger:InvalidTolerance','Tolerances must be finite nonnegative numbers.');
                end
                report=obj.ComparisonEngine.compare(obj.MILResult,obj.SILResult,a,r, ...
                    char(obj.AlignmentDropDown.Value));
                obj.ComparisonTable.Data=report.Table;
                obj.plotComparison(report);
                if strcmp(report.Status,'PASS')
                    obj.FirstDivergenceLabel.Text='MIL vs SIL: PASS | No mismatch outside tolerance';
                else
                    fd=report.FirstDivergence;
                    if isnan(fd.Time)
                        obj.FirstDivergenceLabel.Text='MIL vs SIL: FAIL | Divergence detected';
                    else
                        obj.FirstDivergenceLabel.Text=sprintf( ...
                            'FIRST OBSERVED DIVERGENCE: %s / Port %d at t = %.12g s', ...
                            fd.Direction,fd.Port,fd.Time);
                    end
                end
                obj.status("Comparison completed: " + string(report.Status));
            catch ME
                obj.handleError(ME,'MIL/SIL comparison');
            end
        end

        function navigateToBlock(obj)
            path=strtrim(string(obj.BlockField.Value));
            if path=="", return; end
            try
                open_system(char(path));
                try, hilite_system(char(path),'find'); catch, end
                obj.status("Opened: " + path);
            catch ME
                obj.handleError(ME,'Open selected block');
            end
        end

        function showDiagnostics(obj)
            if isempty(obj.DiagnosticsArea) || ~isvalid(obj.DiagnosticsArea), return; end
            obj.DiagnosticsArea.Value=obj.DiagnosticsManager.asCell();
        end

        function closeApp(obj)
            try
                if ~isempty(obj.SelectionTimer) && isvalid(obj.SelectionTimer)
                    stop(obj.SelectionTimer); delete(obj.SelectionTimer);
                end
            catch
            end
            if ~isempty(obj.UIFigure) && isvalid(obj.UIFigure), delete(obj.UIFigure); end
        end
    end

    methods (Access=private)
        function buildUI(obj)
            obj.UIFigure=uifigure('Name','Smart Debugger','Position',[70 50 1500 900], ...
                'Color',[0.96 0.97 0.98],'CloseRequestFcn',@(~,~)obj.closeApp());
            root=uigridlayout(obj.UIFigure,[4 3]);
            root.RowHeight={72,'1x',250,30}; root.ColumnWidth={310,'1x',390};
            root.Padding=[8 8 8 8]; root.RowSpacing=8; root.ColumnSpacing=8;
            obj.buildToolbar(root); obj.buildLeftPanel(root); obj.buildCenterPanel(root);
            obj.buildRightPanel(root); obj.buildPlotPanel(root); obj.buildStatusBar(root);
        end

        function buildToolbar(obj,parent)
            p=uipanel(parent); p.Layout.Row=1; p.Layout.Column=[1 3];
            g=uigridlayout(p,[2 12]); g.RowHeight={30,30};
            g.ColumnWidth={82,220,82,220,75,82,92,92,92,80,90,'1x'};
            uibutton(g,'Text','Open MIL','ButtonPushedFcn',@(~,~)obj.chooseMIL());
            obj.MILModelField=uieditfield(g,'text','Placeholder','MIL model path');
            uibutton(g,'Text','Open SIL','ButtonPushedFcn',@(~,~)obj.chooseSIL());
            obj.SILModelField=uieditfield(g,'text','Placeholder','SIL model path');
            obj.ModeGroup=uidropdown(g,'Items',{'MIL','SIL'},'Value','MIL','ValueChangedFcn',@(s,~)obj.modeChanged(s));
            uibutton(g,'Text','Import','ButtonPushedFcn',@(~,~)obj.refreshBlockSelection());
            uibutton(g,'Text','Inspect','ButtonPushedFcn',@(~,~)obj.inspectBlock());
            uibutton(g,'Text','Run Debug','ButtonPushedFcn',@(~,~)obj.runDebug());
            uibutton(g,'Text','Compare','ButtonPushedFcn',@(~,~)obj.compare());
            obj.StopTimeField=uieditfield(g,'text','Value','10','Tooltip','Simulation stop time');
            uilabel(g,'Text','Stop time');
            obj.StatusLabel=uilabel(g,'Text','Ready','HorizontalAlignment','left');
            obj.StatusLabel.Layout.Row=2; obj.StatusLabel.Layout.Column=[1 12];
        end

        function buildLeftPanel(obj,parent)
            p=uipanel(parent,'Title','Model / Debug Target'); p.Layout.Row=2; p.Layout.Column=1;
            g=uigridlayout(p,[9 1]); g.RowHeight={22,'1x',32,22,32,22,32,'1x',32};
            uilabel(g,'Text','Model hierarchy');
            obj.Tree=uitree(g,'SelectionChangedFcn',@(s,e)obj.treeSelectionChanged(e));
            uibutton(g,'Text','Refresh model tree','ButtonPushedFcn',@(~,~)obj.refreshModelTree());
            uilabel(g,'Text','MIL selected block');
            obj.BlockField=uieditfield(g,'text','Placeholder','model/subsystem/block');
            uibutton(g,'Text','Open / Highlight','ButtonPushedFcn',@(~,~)obj.navigateToBlock());
            uilabel(g,'Text','SIL mapped block (optional override)');
            obj.SILBlockField=uieditfield(g,'text','Placeholder','SIL model/subsystem/block');
            uibutton(g,'Text','Inspect selected block','ButtonPushedFcn',@(~,~)obj.inspectBlock());
        end

        function buildCenterPanel(obj,parent)
            p=uipanel(parent,'Title','Runtime Signals'); p.Layout.Row=2; p.Layout.Column=2;
            g=uigridlayout(p,[4 1]); g.RowHeight={'1x','1x','1x',30};
            obj.InputsTable=uitable(g,'ColumnName',{'Port','Input Signal','Current Value','Data Type','Dimension','Sample Time'}, ...
                'RowName',{},'ColumnEditable',false(1,6),'CellSelectionCallback',@(s,e)obj.runtimeSelection(s,e,'Input'));
            obj.OutputsTable=uitable(g,'ColumnName',{'Port','Output Signal','Current Value','Data Type','Dimension','Sample Time'}, ...
                'RowName',{},'ColumnEditable',false(1,6),'CellSelectionCallback',@(s,e)obj.runtimeSelection(s,e,'Output'));
            obj.ComparisonTable=uitable(g,'ColumnName',{'Direction','Port','MIL Signal','SIL Signal','Status','Max Abs Error','Max Rel Error','First Mismatch'}, ...
                'RowName',{},'ColumnEditable',false(1,8));
            obj.FirstDivergenceLabel=uilabel(g,'Text','No MIL/SIL comparison run yet','FontWeight','bold','HorizontalAlignment','left');
        end

        function buildRightPanel(obj,parent)
            p=uipanel(parent,'Title','Analysis / Diagnostics'); p.Layout.Row=2; p.Layout.Column=3;
            g=uigridlayout(p,[8 2]); g.RowHeight={22,28,22,28,22,28,'1x',34}; g.ColumnWidth={145,'1x'};
            uilabel(g,'Text','Absolute tolerance'); obj.AbsToleranceField=uieditfield(g,'text','Value','1e-6');
            uilabel(g,'Text','Relative tolerance'); obj.RelToleranceField=uieditfield(g,'text','Value','1e-4');
            uilabel(g,'Text','Time alignment'); obj.AlignmentDropDown=uidropdown(g,'Items',{'linear','nearest','zoh'},'Value','linear');
            uilabel(g,'Text','Compatibility'); obj.CompatibilityLabel=uilabel(g,'Text','Checking...');
            uilabel(g,'Text','Selected block'); obj.BlockInfoArea=uitextarea(g,'Editable','off','Value',{'No block selected.'});
            obj.BlockInfoArea.Layout.Row=[5 6]; obj.BlockInfoArea.Layout.Column=2;
            uilabel(g,'Text','Diagnostics'); obj.DiagnosticsArea=uitextarea(g,'Editable','off','Value',{'No diagnostics.'});
            obj.DiagnosticsArea.Layout.Row=7; obj.DiagnosticsArea.Layout.Column=[1 2];
            uibutton(g,'Text','Refresh diagnostics','ButtonPushedFcn',@(~,~)obj.showDiagnostics());
            uibutton(g,'Text','Clear diagnostics','ButtonPushedFcn',@(~,~)obj.clearDiagnostics());
        end

        function buildPlotPanel(obj,parent)
            p=uipanel(parent,'Title','MIL / SIL Trace'); p.Layout.Row=3; p.Layout.Column=[1 3];
            obj.PlotAxes=uiaxes(p,'Position',[10 10 1470 205]);
            title(obj.PlotAxes,'Selected signal comparison'); xlabel(obj.PlotAxes,'Time (s)');
            ylabel(obj.PlotAxes,'Value / Error'); grid(obj.PlotAxes,'on');
        end

        function buildStatusBar(obj,parent)
            p=uipanel(parent); p.Layout.Row=4; p.Layout.Column=[1 3];
            g=uigridlayout(p,[1 2]); g.ColumnWidth={'1x',350};
            uilabel(g,'Text','Smart Debugger | Non-destructive runtime capture | MIL + SIL');
            uilabel(g,'Text','');
        end

        function chooseMIL(obj)
            [f,p]=uigetfile({'*.slx;*.mdl','Simulink Models (*.slx, *.mdl)'},'Select MIL model');
            if isequal(f,0), return; end
            obj.setMILModel(fullfile(p,f));
        end
        function chooseSIL(obj)
            [f,p]=uigetfile({'*.slx;*.mdl','Simulink Models (*.slx, *.mdl)'},'Select SIL model');
            if isequal(f,0), return; end
            obj.setSILModel(fullfile(p,f));
        end
        function modeChanged(obj,s), obj.Mode=string(s.Value); obj.status("Mode: " + obj.Mode); end

        function validateRunInputs(obj)
            if isempty(strtrim(string(obj.MILModelField.Value))), error('SmartDebugger:MissingMILModel','Select a MIL model first.'); end
            if isempty(strtrim(string(obj.BlockField.Value))), error('SmartDebugger:MissingBlock','Select or enter a MIL block path first.'); end
            stopTime=str2double(obj.StopTimeField.Value);
            if isnan(stopTime) || ~isfinite(stopTime) || stopTime<0, error('SmartDebugger:InvalidStopTime','Stop time must be a finite nonnegative number.'); end
            if obj.Mode=="SIL" && isempty(strtrim(string(obj.SILModelField.Value))), error('SmartDebugger:MissingSILModel','Select a SIL model first.'); end
        end

        function populatePorts(obj,info)
            obj.InputsTable.Data=obj.portRows(info.Inputs); obj.OutputsTable.Data=obj.portRows(info.Outputs);
        end
        function rows=portRows(~,ports)
            if isempty(ports), rows=cell(0,6); return; end
            rows=cell(numel(ports),6);
            for k=1:numel(ports)
                p=ports(k); rows{k,1}=p.Port; rows{k,2}=p.Name; rows{k,3}=localFormatValue(p.Value);
                rows{k,4}=p.DataType; rows{k,5}=p.Dimension; rows{k,6}=p.SampleTime;
            end
        end
        function displayRuntimeResult(obj,result)
            if ~isstruct(result), return; end
            if isfield(result,'Inputs'), obj.InputsTable.Data=obj.portRows(result.Inputs); end
            if isfield(result,'Outputs'), obj.OutputsTable.Data=obj.portRows(result.Outputs); end
            if isfield(result,'Status') && strcmp(result.Status,'PARTIAL'), obj.status('Simulation completed with partial capture. See Diagnostics.'); end
        end

        function runtimeSelection(obj,table,event,direction)
            if isempty(event.Indices) || isempty(obj.ActiveResult), return; end
            row=event.Indices(1,1);
            if strcmp(direction,'Input') && row<=numel(obj.ActiveResult.Inputs)
                p=obj.ActiveResult.Inputs(row);
            elseif strcmp(direction,'Output') && row<=numel(obj.ActiveResult.Outputs)
                p=obj.ActiveResult.Outputs(row);
            else
                return;
            end
            obj.plotSingleRuntimeSeries(p,[direction ' ' char(p.Name)]);
        end

        function plotDefaultRuntimeTrace(obj,result)
            ports=[result.Outputs result.Inputs];
            for k=1:numel(ports)
                if ~isempty(ports(k).Series)
                    obj.plotSingleRuntimeSeries(ports(k),char(ports(k).Name));
                    return;
                end
            end
        end

        function plotSingleRuntimeSeries(obj,p,titleText)
            cla(obj.PlotAxes);
            try
                if isempty(p.Series), return; end
                t=p.Series.Time(:); d=p.Series.Data;
                if isnumeric(d) || islogical(d)
                    if isvector(d), plot(obj.PlotAxes,t,d,'DisplayName',titleText); else, plot(obj.PlotAxes,t,d(:,1),'DisplayName',titleText); end
                    title(obj.PlotAxes,titleText); xlabel(obj.PlotAxes,'Time (s)'); grid(obj.PlotAxes,'on'); legend(obj.PlotAxes,'show');
                else
                    text(obj.PlotAxes,0.1,0.5,'Non-numeric signal: use table for values','Units','normalized');
                end
            catch ME
                obj.DiagnosticsManager.recordException(ME,'Runtime plot'); obj.showDiagnostics();
            end
        end

        function populateBlockInfo(obj,info)
            lines={['Name: ' char(info.Name)],['Type: ' char(info.BlockType)],['Path: ' char(info.Path)]};
            if isfield(info,'LibraryLink') && ~isempty(info.LibraryLink), lines{end+1}=['Library: ' char(info.LibraryLink)]; end %#ok<AGROW>
            if isfield(info,'MaskType') && ~isempty(info.MaskType), lines{end+1}=['Mask: ' char(info.MaskType)]; end %#ok<AGROW>
            if isfield(info,'LinkStatus') && ~isempty(info.LinkStatus), lines{end+1}=['Link status: ' char(info.LinkStatus)]; end %#ok<AGROW>
            obj.BlockInfoArea.Value=lines;
        end

        function plotComparison(obj,report)
            cla(obj.PlotAxes);
            if isempty(report.Time), return; end
            hold(obj.PlotAxes,'on');
            localPlot(obj.PlotAxes,report.Time,report.MIL,'MIL');
            localPlot(obj.PlotAxes,report.Time,report.SIL,'SIL');
            localPlot(obj.PlotAxes,report.Time,report.Error,'MIL - SIL');
            hold(obj.PlotAxes,'off'); legend(obj.PlotAxes,'show','Location','best');
            title(obj.PlotAxes,['Comparison: ' char(report.Signal)]); grid(obj.PlotAxes,'on');
        end

        function refreshModelTree(obj)
            delete(obj.Tree.Children);
            model=strtrim(string(obj.MILModelField.Value)); if model=="", return; end
            try
                [~,root,~]=fileparts(char(model)); if ~bdIsLoaded(root), load_system(root); end
                rootNode=uitreenode(obj.Tree,'Text',root,'NodeData',root);
                children=find_system(root,'SearchDepth',1,'Type','Block'); children=children(~strcmp(children,root));
                for k=1:numel(children)
                    uitreenode(rootNode,'Text',get_param(children{k},'Name'),'NodeData',children{k});
                end
                expand(rootNode);
            catch ME
                obj.DiagnosticsManager.recordException(ME,'Model tree'); obj.showDiagnostics();
            end
        end

        function treeSelectionChanged(obj,event)
            try
                node=event.SelectedNodes; if isempty(node), return; end
                path=node(1).NodeData;
                if ischar(path) && contains(path,'/'), obj.setSelectedBlock(path); end
            catch ME
                obj.DiagnosticsManager.recordException(ME,'Tree selection');
            end
        end

        function startSelectionWatcher(obj)
            try
                obj.SelectionTimer=timer('ExecutionMode','fixedSpacing','Period',0.75,'BusyMode','drop','TimerFcn',@(~,~)obj.pollSelection());
                start(obj.SelectionTimer);
            catch ME
                obj.DiagnosticsManager.recordException(ME,'Selection watcher');
            end
        end

        function pollSelection(obj)
            if obj.Busy || isempty(obj.ModelManager.Model), return; end
            try
                path=obj.ModelManager.currentSimulinkSelection();
                if ~isempty(path) && ~strcmp(path,char(obj.SelectedBlock)), obj.setSelectedBlock(path); end
            catch
            end
        end

        function updateCompatibility(obj)
            c=obj.CompatibilityManager.snapshot();
            parts={['MATLAB ' char(c.MATLAB)]};
            if ~isempty(c.Simulink), parts{end+1}=['Simulink ' char(c.Simulink)]; end %#ok<AGROW>
            if c.StateflowAvailable, parts{end+1}='Stateflow available'; else, parts{end+1}='Stateflow unavailable'; end %#ok<AGROW>
            if c.SimulinkCoder, parts{end+1}='Simulink Coder available'; end %#ok<AGROW>
            if c.TargetLinkAvailable, parts{end+1}='TargetLink detected'; end %#ok<AGROW>
            obj.CompatibilityLabel.Text=strjoin(parts,' | ');
        end

        function clearDiagnostics(obj), obj.DiagnosticsManager.clear(); obj.showDiagnostics(); end
        function handleError(obj,ME,stage), obj.DiagnosticsManager.recordException(ME,stage); obj.status([stage ' failed. See Diagnostics.']); obj.showDiagnostics(); end
        function status(obj,msg), if ~isempty(obj.StatusLabel) && isvalid(obj.StatusLabel), obj.StatusLabel.Text=char(msg); end, end
        function setBusy(obj,value), obj.Busy=value; if ~isempty(obj.UIFigure) && isvalid(obj.UIFigure), if value, obj.UIFigure.Pointer='watch'; else, obj.UIFigure.Pointer='arrow'; end; drawnow; end, end
    end
end

function text=localFormatValue(value)
if isempty(value), text=''; return; end
try
    if ischar(value), text=value;
    elseif isstring(value) && isscalar(value), text=char(value);
    elseif isscalar(value), text=mat2str(value,8);
    elseif isnumeric(value) || islogical(value)
        sz=size(value);
        if numel(value)<=8, text=mat2str(value,8);
        else, text=sprintf('%s %s, min=%s, max=%s',class(value),mat2str(sz),mat2str(min(value(:)),8),mat2str(max(value(:)),8)); end
    else, text=['<' class(value) '>'];
    end
catch, text=['<' class(value) '>']; end
end

function localPlot(ax,t,data,name)
if isempty(data), return; end
try
    if isvector(data), plot(ax,t,data,'DisplayName',name);
    elseif isnumeric(data), plot(ax,t,data(:,1),'DisplayName',name); end
catch
end
end
