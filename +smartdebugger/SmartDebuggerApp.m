classdef SmartDebuggerApp < handle
    %SMARTDEBUGGERAPP Non-invasive Smart Debugger UI.
    % Model selection and inspection never compile/update the model.
    % Compilation is performed only by SimulationManager during Run Debug.

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
        ModeDropDown
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
        RuntimeTabs
        RuntimeSummary
        ActiveResult = []
        CursorIndex = 1
        CursorTimes = []
        CursorValues = []
        CursorSignalName = ''
        CursorLine = []
        CursorText = []
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
            if ~isempty(varargin)
                obj.configure(varargin{:});
            end
        end

        function configure(obj,varargin)
            p=inputParser;
            addParameter(p,'Model','',@(x)ischar(x)||isstring(x));
            addParameter(p,'SILModel','',@(x)ischar(x)||isstring(x));
            parse(p,varargin{:});
            if ~isempty(strtrim(char(string(p.Results.Model))))
                obj.setMILModel(char(string(p.Results.Model)));
            end
            if ~isempty(strtrim(char(string(p.Results.SILModel))))
                obj.setSILModel(char(string(p.Results.SILModel)));
            end
        end

        function setMILModel(obj,model)
            try
                model=char(string(model));
                obj.ModelManager.loadModel(model);
                obj.MILModelField.Value=model;
                obj.SelectedBlock='';
                obj.RunTargetBlock='';
                obj.refreshModelTree();
                obj.status(['MIL model ready: ' model]);
            catch ME
                obj.handleError(ME,'Load MIL model');
            end
        end

        function setSILModel(obj,model)
            try
                model=char(string(model));
                if isempty(strtrim(model)), return; end
                [~,root,ext]=fileparts(model);
                if isempty(root), root=model; end
                if ~bdIsLoaded(root)
                    if isempty(ext)
                        if exist([root '.slx'],'file')==2 || exist([root '.mdl'],'file')==2
                            load_system(root);
                        else
                            error('SmartDebugger:SILModelNotFound','SIL model not found: %s',model);
                        end
                    elseif exist(model,'file')==2
                        load_system(model);
                    else
                        error('SmartDebugger:SILModelNotFound','SIL model file not found: %s',model);
                    end
                end
                obj.SILModelField.Value=model;
                obj.status(['SIL model ready: ' model]);
            catch ME
                obj.handleError(ME,'Load SIL model');
            end
        end

        function refreshBlockSelection(obj)
            try
                path=obj.ModelManager.currentSimulinkSelection();
                if isempty(path), path=char(string(obj.BlockField.Value)); end
                if isempty(strtrim(path))
                    obj.status('No Simulink block selected.');
                    return
                end
                obj.selectBlock(path,false);
            catch ME
                obj.handleError(ME,'Import selection');
            end
        end

        function inspectBlock(obj)
            path=char(string(obj.BlockField.Value));
            if isempty(strtrim(path)), return; end
            try
                get_param(path,'Handle');
                info=obj.ModelManager.inspectBlock(path);
                if isempty(info)
                    obj.status('Inspection failed. See Diagnostics.');
                    obj.showDiagnostics();
                    return
                end
                obj.SelectedBlock=path;
                obj.RunTargetBlock=path;
                obj.populatePorts(info);
                obj.populateBlockInfo(info);
                obj.status(['Inspected: ' path]);
                obj.showDiagnostics();
            catch ME
                obj.handleError(ME,'Inspect block');
            end
        end

        function runDebug(obj)
            if obj.Busy, return; end
            try
                obj.ensureSelectedBlock();
                obj.validateRunInputs();
                obj.setBusy(true);
                cleanup=onCleanup(@()obj.setBusy(false)); %#ok<NASGU>
                stopTime=char(string(obj.StopTimeField.Value));
                if strcmpi(obj.Mode,'MIL')
                    model=obj.resolveMILModel();
                    obj.status(['Running MIL: ' obj.RunTargetBlock]);
                    drawnow;
                    runResult=obj.SimulationManager.runMIL(model,obj.RunTargetBlock,stopTime);
                    obj.MILResult=runResult;
                else
                    silModel=char(string(obj.SILModelField.Value));
                    [silBlock,confidence,mapMethod,candidates]=smartdebugger.ModelMapper.mapBlock(obj.RunTargetBlock,silModel);
                    if isempty(silBlock)
                        override=char(string(obj.SILBlockField.Value));
                        if isempty(strtrim(override))
                            error('SmartDebugger:SILMappingRequired','Automatic MIL-to-SIL mapping failed. Enter a SIL block override.');
                        end
                        silBlock=override; confidence='USER_DEFINED'; mapMethod='USER_DEFINED';
                    end
                    if strcmpi(confidence,'AMBIGUOUS')
                        error('SmartDebugger:AmbiguousSILMapping','SIL mapping is ambiguous. Candidates: %s',strjoin(candidates,', '));
                    end
                    obj.SelectedSILBlock=silBlock;
                    obj.SILBlockField.Value=silBlock;
                    obj.status(['Running SIL: ' silBlock]);
                    drawnow;
                    runResult=obj.SimulationManager.runSIL(silModel,silBlock,stopTime);
                    runResult.MappingConfidence=confidence;
                    runResult.MappingMethod=mapMethod;
                    obj.SILResult=runResult;
                end
                obj.ActiveResult=runResult;
                obj.displayRuntimeResult(runResult);
                obj.plotDefaultRuntimeTrace(runResult);
                obj.showDiagnostics();
                obj.status([obj.Mode ' completed: ' runResult.Status obj.optionalMessage(runResult.Message)]);
            catch ME
                obj.handleError(ME,'Debug run');
            end
        end

        function compare(obj)
            try
                if isempty(obj.MILResult)||isempty(obj.SILResult)
                    error('SmartDebugger:MissingResults','Run MIL and SIL before comparison.');
                end
                a=str2double(char(string(obj.AbsToleranceField.Value)));
                r=str2double(char(string(obj.RelToleranceField.Value)));
                if ~isscalar(a)||~isfinite(a)||a<0||~isscalar(r)||~isfinite(r)||r<0
                    error('SmartDebugger:InvalidTolerance','Tolerances must be finite nonnegative numbers.');
                end
                report=obj.ComparisonEngine.compare(obj.MILResult,obj.SILResult,a,r,char(string(obj.AlignmentDropDown.Value)));
                obj.ComparisonTable.Data=report.Table;
                obj.plotComparison(report);
                if strcmp(report.Status,'PASS')
                    obj.FirstDivergenceLabel.Text='MIL vs SIL: PASS | No mismatch outside tolerance';
                else
                    fd=report.FirstDivergence;
                    if isnan(fd.Time)
                        obj.FirstDivergenceLabel.Text='MIL vs SIL: FAIL | Divergence detected';
                    else
                        obj.FirstDivergenceLabel.Text=sprintf('FIRST DIVERGENCE: %s / Port %d at t = %.12g s',fd.Direction,fd.Port,fd.Time);
                    end
                end
                obj.showDiagnostics();
                obj.status(['Comparison completed: ' report.Status]);
            catch ME
                obj.handleError(ME,'MIL/SIL comparison');
            end
        end

        function closeApp(obj)
            try
                if ~isempty(obj.UIFigure)&&isvalid(obj.UIFigure)
                    delete(obj.UIFigure);
                end
            catch
            end
        end
    end

    methods (Access=private)
        function buildUI(obj)
            obj.UIFigure=uifigure('Name','Smart Debugger','Position',[50 40 1550 920], ...
                'CloseRequestFcn',@(~,~)obj.closeApp(), ...
                'WindowKeyPressFcn',@(~,e)obj.runtimeKeyPress(e));
            root=uigridlayout(obj.UIFigure,[4 3]);
            root.RowHeight={74,'1.35x',320,30};
            root.ColumnWidth={360,'1x',410};
            root.Padding=[8 8 8 8];
            root.RowSpacing=8;
            root.ColumnSpacing=8;
            obj.buildToolbar(root);
            obj.buildLeftPanel(root);
            obj.buildCenterPanel(root);
            obj.buildRightPanel(root);
            obj.buildPlotPanel(root);
            obj.buildStatusBar(root);
        end

        function buildToolbar(obj,parent)
            p=uipanel(parent); p.Layout.Row=1; p.Layout.Column=[1 3];
            g=uigridlayout(p,[2 12]);
            g.RowHeight={32,28};
            g.ColumnWidth={78,220,78,220,72,78,88,92,88,90,70,'1x'};
            uibutton(g,'Text','Open MIL','ButtonPushedFcn',@(~,~)obj.chooseMIL());
            obj.MILModelField=uieditfield(g,'text','Placeholder','MIL model path');
            uibutton(g,'Text','Open SIL','ButtonPushedFcn',@(~,~)obj.chooseSIL());
            obj.SILModelField=uieditfield(g,'text','Placeholder','SIL model path');
            obj.ModeDropDown=uidropdown(g,'Items',{'MIL','SIL'},'Value','MIL','ValueChangedFcn',@(s,~)obj.modeChanged(s));
            uibutton(g,'Text','Import','ButtonPushedFcn',@(~,~)obj.refreshBlockSelection());
            uibutton(g,'Text','Inspect','ButtonPushedFcn',@(~,~)obj.inspectBlock());
            uibutton(g,'Text','Run Debug','ButtonPushedFcn',@(~,~)obj.runDebug());
            uibutton(g,'Text','Compare','ButtonPushedFcn',@(~,~)obj.compare());
            obj.StopTimeField=uieditfield(g,'text','Value','auto','Placeholder','auto = model StopTime');
            uilabel(g,'Text','Stop time');
            obj.StatusLabel=uilabel(g,'Text','Ready'); obj.StatusLabel.Layout.Row=2; obj.StatusLabel.Layout.Column=[1 12];
        end

        function buildLeftPanel(obj,parent)
            p=uipanel(parent,'Title','Model / Debug Target'); p.Layout.Row=2; p.Layout.Column=1;
            g=uigridlayout(p,[9 1]); g.RowHeight={22,'1x',30,22,30,30,22,30,30};
            uilabel(g,'Text','Complete model hierarchy');
            obj.Tree=uitree(g,'SelectionChangedFcn',@(~,e)obj.treeSelectionChanged(e));
            uibutton(g,'Text','Refresh model tree','ButtonPushedFcn',@(~,~)obj.refreshModelTree());
            uilabel(g,'Text','MIL selected block');
            obj.BlockField=uieditfield(g,'text','Placeholder','model/subsystem/block');
            uibutton(g,'Text','Open / Highlight','ButtonPushedFcn',@(~,~)obj.navigateToBlock());
            uilabel(g,'Text','SIL mapped block (optional override)');
            obj.SILBlockField=uieditfield(g,'text','Placeholder','SIL model/subsystem/block');
            uibutton(g,'Text','Inspect selected block','ButtonPushedFcn',@(~,~)obj.inspectBlock());
        end

        function buildCenterPanel(obj,parent)
            p=uipanel(parent,'Title','Runtime Signals | Inputs, Outputs, Samples'); p.Layout.Row=2; p.Layout.Column=2;
            g=uigridlayout(p,[2 1]); g.RowHeight={30,'1x'}; g.RowSpacing=6;
            obj.RuntimeSummary=uilabel(g,'Text','No runtime capture yet | Select a row to plot it | Arrow keys move the sample cursor');
            obj.RuntimeTabs=uitabgroup(g);
            tabIn=uitab(obj.RuntimeTabs,'Title','Inputs');
            gi=uigridlayout(tabIn,[1 1]);
            obj.InputsTable=uitable(gi,'ColumnName',{'Port / Bus','Input Signal','Current Value','Data Type','Dimension','Samples / Sample Time'}, ...
                'RowName',{},'ColumnEditable',false(1,6),'CellSelectionCallback',@(s,e)obj.runtimeSelection(s,e,'Input'));
            tabOut=uitab(obj.RuntimeTabs,'Title','Outputs');
            go=uigridlayout(tabOut,[1 1]);
            obj.OutputsTable=uitable(go,'ColumnName',{'Port / Bus','Output Signal','Current Value','Data Type','Dimension','Samples / Sample Time'}, ...
                'RowName',{},'ColumnEditable',false(1,6),'CellSelectionCallback',@(s,e)obj.runtimeSelection(s,e,'Output'));
            tabCmp=uitab(obj.RuntimeTabs,'Title','MIL vs SIL');
            gc=uigridlayout(tabCmp,[1 1]);
            obj.ComparisonTable=uitable(gc,'ColumnName',{'Direction','Port','MIL Signal','SIL Signal','Status','Max Abs Error','Max Rel Error','First Mismatch'}, ...
                'RowName',{},'ColumnEditable',false(1,8));
            tabSamples=uitab(obj.RuntimeTabs,'Title','Samples');
            gs=uigridlayout(tabSamples,[1 1]);
            obj.SampleTable=uitable(gs,'ColumnName',{'Time (s)','Value'},'RowName',{},'ColumnEditable',false(1,2));
        end

        function buildRightPanel(obj,parent)
            p=uipanel(parent,'Title','Analysis / Diagnostics'); p.Layout.Row=2; p.Layout.Column=3;
            g=uigridlayout(p,[8 2]); g.RowHeight={22,28,22,28,22,28,'1x',34}; g.ColumnWidth={145,'1x'};
            uilabel(g,'Text','Absolute tolerance'); obj.AbsToleranceField=uieditfield(g,'text','Value','1e-6');
            uilabel(g,'Text','Relative tolerance'); obj.RelToleranceField=uieditfield(g,'text','Value','1e-4');
            uilabel(g,'Text','Time alignment'); obj.AlignmentDropDown=uidropdown(g,'Items',{'linear','nearest','zoh'},'Value','linear');
            uilabel(g,'Text','Compatibility'); obj.CompatibilityLabel=uilabel(g,'Text','Checking...');
            uilabel(g,'Text','Selected block'); obj.BlockInfoArea=uitextarea(g,'Editable','off','Value',{'No block selected.'}); obj.BlockInfoArea.Layout.Row=[5 6]; obj.BlockInfoArea.Layout.Column=2;
            uilabel(g,'Text','Diagnostics'); obj.DiagnosticsArea=uitextarea(g,'Editable','off','Value',{'No diagnostics.'}); obj.DiagnosticsArea.Layout.Row=7; obj.DiagnosticsArea.Layout.Column=[1 2];
            uibutton(g,'Text','Refresh diagnostics','ButtonPushedFcn',@(~,~)obj.showDiagnostics());
            uibutton(g,'Text','Clear diagnostics','ButtonPushedFcn',@(~,~)obj.clearDiagnostics());
        end

        function buildPlotPanel(obj,parent)
            p=uipanel(parent,'Title','Runtime Trace | sample-accurate cursor'); p.Layout.Row=3; p.Layout.Column=[1 3];
            obj.PlotAxes=uiaxes(p,'Position',[10 10 1520 285]);
            title(obj.PlotAxes,'Select a runtime signal'); xlabel(obj.PlotAxes,'Time (s)'); ylabel(obj.PlotAxes,'Value'); grid(obj.PlotAxes,'on');
        end

        function buildStatusBar(obj,parent)
            p=uipanel(parent); p.Layout.Row=4; p.Layout.Column=[1 3]; g=uigridlayout(p,[1 1]);
            uilabel(g,'Text','Smart Debugger | explicit inspection | explicit Run Debug | no background compilation | ←/→ sample cursor');
        end

        function chooseMIL(obj)
            [f,p]=uigetfile({'*.slx;*.mdl','Simulink Models'},'Select MIL model');
            if ~isequal(f,0), obj.setMILModel(fullfile(p,f)); end
        end
        function chooseSIL(obj)
            [f,p]=uigetfile({'*.slx;*.mdl','Simulink Models'},'Select SIL model');
            if ~isequal(f,0), obj.setSILModel(fullfile(p,f)); end
        end
        function modeChanged(obj,source)
            obj.Mode=char(string(source.Value)); obj.status(['Mode: ' obj.Mode]);
        end

        function refreshModelTree(obj)
            root='';
            try, if ~isempty(obj.SelectedBlock), root=bdroot(obj.SelectedBlock); end; catch, end
            if isempty(root), [~,root,~]=fileparts(char(string(obj.MILModelField.Value))); end
            if isempty(root)||~bdIsLoaded(root)
                obj.status('Load/select a MIL model before refreshing hierarchy.'); return
            end
            try, delete(obj.Tree.Children); catch, end
            obj.TreeModel=root;
            top=uitreenode(obj.Tree,'Text',root,'NodeData',root);
            obj.addTreeChildren(top,root);
            try, expand(top); catch, end
        end

        function addTreeChildren(obj,parentNode,parentPath)
            try, children=find_system(parentPath,'SearchDepth',1,'Type','Block'); catch, return; end
            for k=1:numel(children)
                cp=children{k};
                if strcmp(cp,parentPath), continue; end
                try, nm=get_param(cp,'Name'); catch, nm=cp; end
                node=uitreenode(parentNode,'Text',nm,'NodeData',cp);
                try, if strcmp(get_param(cp,'BlockType'),'SubSystem'), obj.addTreeChildren(node,cp); end; catch, end
            end
        end

        function treeSelectionChanged(obj,event)
            try
                nodes=event.SelectedNodes; if isempty(nodes), return; end
                path=nodes(1).NodeData;
                if ischar(path)||isstring(path), obj.selectBlock(char(string(path)),false); end
            catch ME
                obj.handleError(ME,'Tree selection');
            end
        end

        function selectBlock(obj,path,inspectNow)
            path=char(string(path)); root=bdroot(path);
            if isempty(root)||~bdIsLoaded(root), error('SmartDebugger:InvalidSelection','Selected block belongs to an unloaded model.'); end
            obj.ModelManager.loadModel(root);
            obj.syncMILModelFromBlock(path);
            obj.SelectedBlock=path; obj.RunTargetBlock=path; obj.BlockField.Value=path;
            if ~strcmp(obj.TreeModel,root), obj.refreshModelTree(); end
            if inspectNow, obj.inspectBlock(); end
        end

        function syncMILModelFromBlock(obj,path)
            root=bdroot(path); f='';
            try, f=get_param(root,'FileName'); catch, end
            if isempty(f), f=root; end
            obj.MILModelField.Value=f;
        end

        function populatePorts(obj,info)
            obj.InputsTable.Data=obj.inspectionTableData(info.Inputs);
            obj.OutputsTable.Data=obj.inspectionTableData(info.Outputs);
            obj.SampleTable.Data=cell(0,2);
            obj.RuntimeTabs.SelectedTab=obj.RuntimeTabs.Children(1);
        end

        function data=inspectionTableData(~,ports)
            data=cell(numel(ports),6);
            for k=1:numel(ports)
                data{k,1}=ports(k).Port; data{k,2}=ports(k).Name;
                data{k,4}=ports(k).DataType; data{k,5}=ports(k).Dimension; data{k,6}=ports(k).SampleTime;
            end
        end

        function populateBlockInfo(obj,info)
            obj.BlockInfoArea.Value={['Path: ' info.Path],['Name: ' info.Name],['Block type: ' info.BlockType],['Parent: ' info.Parent],['Mask type: ' info.MaskType],['Library link: ' info.LibraryLink]};
        end

        function displayRuntimeResult(obj,result)
            obj.InputsTable.Data=obj.runtimeTableData(result.Inputs);
            obj.OutputsTable.Data=obj.runtimeTableData(result.Outputs);
            n=numel(result.Inputs)+numel(result.Outputs);
            obj.RuntimeSummary.Text=sprintf('Captured %d runtime signals | Inputs: %d | Outputs: %d | Select a row, then use ←/→ to inspect every actual sample',obj.countSeries(result),numel(result.Inputs),numel(result.Outputs));
            first=[]; firstDir='Input';
            for k=1:numel(result.Inputs)
                if ~isempty(result.Inputs(k).Series), first=result.Inputs(k); firstDir='Input'; break; end
            end
            if isempty(first)
                for k=1:numel(result.Outputs)
                    if ~isempty(result.Outputs(k).Series), first=result.Outputs(k); firstDir='Output'; break; end
                end
            end
            if ~isempty(first)
                if strcmpi(firstDir,'Output'), obj.RuntimeTabs.SelectedTab=obj.RuntimeTabs.Children(2); else, obj.RuntimeTabs.SelectedTab=obj.RuntimeTabs.Children(1); end
                obj.selectRuntimePort(first);
            else
                obj.SampleTable.Data=cell(0,2); obj.clearCursor();
            end
        end

        function n=countSeries(~,result)
            n=0;
            for k=1:numel(result.Inputs), if ~isempty(result.Inputs(k).Series), n=n+1; end, end
            for k=1:numel(result.Outputs), if ~isempty(result.Outputs(k).Series), n=n+1; end, end
        end

        function data=runtimeTableData(obj,ports)
            data=cell(numel(ports),6);
            for k=1:numel(ports)
                data{k,1}=ports(k).Port; data{k,2}=ports(k).Name; data{k,3}=obj.formatValue(ports(k).Value);
                data{k,4}=ports(k).DataType; data{k,5}=ports(k).Dimension; data{k,6}=ports(k).SampleTime;
            end
        end

        function runtimeSelection(obj,~,event,direction)
            try
                if isempty(event.Indices)||isempty(obj.ActiveResult), return; end
                row=event.Indices(1);
                if strcmpi(direction,'Input'), ports=obj.ActiveResult.Inputs; else, ports=obj.ActiveResult.Outputs; end
                if row>=1&&row<=numel(ports), obj.selectRuntimePort(ports(row)); end
            catch ME
                obj.handleError(ME,'Plot runtime signal');
            end
        end

        function selectRuntimePort(obj,port)
            if isempty(port)||isempty(port.Series)
                obj.clearCursor();
                return
            end
            try
                [t,y]=obj.seriesXY(port.Series);
                obj.CursorTimes=t(:); obj.CursorValues=y(:); obj.CursorSignalName=port.Name; obj.CursorIndex=1;
                obj.plotRuntimeSignal(port);
                obj.updateCursor();
                obj.RuntimeSummary.Text=sprintf('%s | %d actual samples | sample cursor: 1/%d | use ←/→',port.Name,numel(t),numel(t));
                obj.RuntimeTabs.SelectedTab=obj.RuntimeTabs.Children(4);
                obj.populateSampleTable(port);
                obj.RuntimeTabs.SelectedTab=obj.tabForDirection(port);
            catch ME
                obj.handleError(ME,'Select runtime signal');
            end
        end

        function tab=tabForDirection(obj,port)
            tab=obj.RuntimeTabs.Children(1);
            if ~isempty(obj.ActiveResult)
                for k=1:numel(obj.ActiveResult.Outputs)
                    if strcmp(obj.ActiveResult.Outputs(k).Name,port.Name)&&isequal(obj.ActiveResult.Outputs(k).Series,port.Series)
                        tab=obj.RuntimeTabs.Children(2); return
                    end
                end
            end
        end

        function populateSampleTable(obj,port)
            try
                [t,y]=obj.seriesXY(port.Series); data=cell(numel(t),2);
                for k=1:numel(t), data{k,1}=t(k); data{k,2}=obj.formatValue(y(k)); end
                obj.SampleTable.Data=data;
            catch ME
                obj.DiagnosticsManager.recordException(ME,'Display sample values');
            end
        end

        function plotDefaultRuntimeTrace(obj,result)
            cla(obj.PlotAxes); hold(obj.PlotAxes,'on'); names={};
            for k=1:numel(result.Inputs)
                if isempty(result.Inputs(k).Series), continue; end
                try, [t,y]=obj.seriesXY(result.Inputs(k).Series); obj.plotSampleAccurate(t,y); names{end+1}=result.Inputs(k).Name; catch ME, obj.DiagnosticsManager.recordException(ME,['Plot ' result.Inputs(k).Name]); end
            end
            for k=1:numel(result.Outputs)
                if isempty(result.Outputs(k).Series), continue; end
                try, [t,y]=obj.seriesXY(result.Outputs(k).Series); obj.plotSampleAccurate(t,y); names{end+1}=result.Outputs(k).Name; catch ME, obj.DiagnosticsManager.recordException(ME,['Plot ' result.Outputs(k).Name]); end
            end
            hold(obj.PlotAxes,'off');
            if ~isempty(names), legend(obj.PlotAxes,names,'Interpreter','none','Location','best'); title(obj.PlotAxes,'All captured signals | actual logged samples'); else, title(obj.PlotAxes,'No runtime series captured'); end
        end

        function plotRuntimeSignal(obj,port)
            cla(obj.PlotAxes);
            if isempty(port.Series), title(obj.PlotAxes,[port.Name ' | no runtime samples']); return; end
            try
                [t,y]=obj.seriesXY(port.Series);
                obj.plotSampleAccurate(t,y);
                title(obj.PlotAxes,sprintf('%s | %d actual samples | ←/→ cursor',port.Name,numel(t)),'Interpreter','none');
            catch ME
                obj.handleError(ME,'Plot runtime signal');
            end
        end

        function plotSampleAccurate(obj,t,y)
            t=t(:); y=y(:); n=min(numel(t),numel(y)); if n==0, return; end
            t=t(1:n); y=y(1:n); if islogical(y), y=double(y); end
            regular=false;
            if n>=2
                d=diff(t); m=median(d); regular=all(abs(d-m)<=max(1e-10,1e-8*max(abs(m),1)));
            end
            if regular, stairs(obj.PlotAxes,t,y,'Marker','.','LineWidth',1); else, plot(obj.PlotAxes,t,y,'Marker','.','LineStyle','-'); end
            if n>1, xlim(obj.PlotAxes,[t(1) t(end)]); else, xlim(obj.PlotAxes,[t(1)-0.5 t(1)+0.5]); end
            xlabel(obj.PlotAxes,'Time (s)'); grid(obj.PlotAxes,'on');
        end

        function [t,y]=seriesXY(~,series)
            t=series.Time(:); data=series.Data; if isempty(data), y=[]; return; end
            if isvector(data)
                n=min(numel(data),numel(t)); y=data(1:n); t=t(1:n);
            else
                sz=size(data);
                if sz(1)==numel(t), y=data(:,1);
                elseif sz(end)==numel(t), flat=reshape(data,[],sz(end)); y=flat(1,:).'; t=t(1:numel(y));
                else, flat=data(:); n=min(numel(t),numel(flat)); y=flat(1:n); t=t(1:n); end
            end
            if ~islogical(y)&&~isnumeric(y), y=double(y); end
        end

        function runtimeKeyPress(obj,event)
            if isempty(obj.CursorTimes)||obj.Busy, return; end
            key=lower(char(string(event.Key)));
            switch key
                case {'rightarrow','right'}, obj.moveCursor(1);
                case {'leftarrow','left'}, obj.moveCursor(-1);
                case {'home'}, obj.CursorIndex=1; obj.updateCursor();
                case {'end'}, obj.CursorIndex=numel(obj.CursorTimes); obj.updateCursor();
            end
        end

        function moveCursor(obj,delta)
            n=numel(obj.CursorTimes); if n==0, return; end
            obj.CursorIndex=max(1,min(n,obj.CursorIndex+delta)); obj.updateCursor();
        end

        function updateCursor(obj)
            if isempty(obj.CursorTimes)||isempty(obj.CursorValues), obj.clearCursor(); return; end
            i=max(1,min(numel(obj.CursorTimes),obj.CursorIndex)); t=obj.CursorTimes(i); v=obj.CursorValues(i);
            try
                if ~isempty(obj.CursorLine)&&isvalid(obj.CursorLine), delete(obj.CursorLine); end
            catch, end
            try
                if ~isempty(obj.CursorText)&&isvalid(obj.CursorText), delete(obj.CursorText); end
            catch, end
            try
                obj.CursorLine=xline(obj.PlotAxes,t,'--','Cursor');
                obj.CursorText=text(obj.PlotAxes,t,v,sprintf('  #%d  t=%.12g s  value=%s',i,t,obj.formatValue(v)), ...
                    'Interpreter','none','VerticalAlignment','bottom');
            catch
            end
            data=cell(numel(obj.CursorTimes),2);
            for k=1:numel(obj.CursorTimes), data{k,1}=obj.CursorTimes(k); data{k,2}=obj.formatValue(obj.CursorValues(k)); end
            obj.SampleTable.Data=data;
            try, obj.SampleTable.Selection=[i 1]; end
            obj.RuntimeSummary.Text=sprintf('%s | sample %d/%d | t = %.12g s | value = %s | ←/→ move',obj.CursorSignalName,i,numel(obj.CursorTimes),t,obj.formatValue(v));
        end

        function clearCursor(obj)
            obj.CursorTimes=[]; obj.CursorValues=[]; obj.CursorIndex=1; obj.CursorSignalName=''; obj.SampleTable.Data=cell(0,2);
            try, if ~isempty(obj.CursorLine)&&isvalid(obj.CursorLine), delete(obj.CursorLine); end; catch, end
            try, if ~isempty(obj.CursorText)&&isvalid(obj.CursorText), delete(obj.CursorText); end; catch, end
            obj.CursorLine=[]; obj.CursorText=[];
        end

        function plotComparison(obj,report)
            cla(obj.PlotAxes);
            try
                if ~isempty(report.Time)
                    hold(obj.PlotAxes,'on'); plot(obj.PlotAxes,report.Time,report.MIL,'DisplayName','MIL'); plot(obj.PlotAxes,report.Time,report.SIL,'DisplayName','SIL'); hold(obj.PlotAxes,'off'); legend(obj.PlotAxes,'show');
                end
                title(obj.PlotAxes,'MIL vs SIL');
            catch ME
                obj.DiagnosticsManager.recordException(ME,'Plot comparison');
            end
        end

        function text=formatValue(~,value)
            if isempty(value), text=''; return; end
            try
                if islogical(value)&&isscalar(value), text=char(string(value));
                elseif isscalar(value), text=sprintf('%.12g',double(value));
                elseif ischar(value)||isstring(value), text=char(string(value));
                else, text=mat2str(value,8); end
            catch, text=class(value); end
        end

        function text=optionalMessage(~,message)
            if isempty(message), text=''; else, text=[' | ' char(string(message))]; end
        end

        function ensureSelectedBlock(obj)
            path=strtrim(char(string(obj.RunTargetBlock)));
            if isempty(path), path=strtrim(char(string(obj.SelectedBlock))); end
            if isempty(path), path=strtrim(char(string(obj.BlockField.Value))); end
            if isempty(path), error('SmartDebugger:MissingBlock','Select a Simulink block first.'); end
            try, get_param(path,'Handle'); catch, error('SmartDebugger:InvalidBlock','Selected block is invalid: %s',path); end
            obj.SelectedBlock=path; obj.RunTargetBlock=path; obj.BlockField.Value=path;
        end

        function validateRunInputs(obj)
            obj.ensureSelectedBlock(); s=strtrim(char(string(obj.StopTimeField.Value)));
            if isempty(s), obj.StopTimeField.Value='auto'; s='auto'; end
            if ~strcmpi(s,'auto')
                v=str2double(s); if ~isscalar(v)||~isfinite(v)||v<0, error('SmartDebugger:InvalidStopTime','Stop time must be a nonnegative number or auto.'); end
            end
            if strcmpi(obj.Mode,'SIL')&&isempty(strtrim(char(string(obj.SILModelField.Value)))), error('SmartDebugger:MissingSILModel','Select a SIL model first.'); end
        end

        function model=resolveMILModel(obj)
            root=bdroot(obj.RunTargetBlock);
            if ~isempty(root)&&bdIsLoaded(root), model=root; else, model=char(string(obj.MILModelField.Value)); end
            if isempty(strtrim(model)), error('SmartDebugger:MissingMILModel','No MIL model could be resolved.'); end
        end

        function setBusy(obj,value)
            obj.Busy=logical(value);
            try, obj.ModeDropDown.Enable=~value; obj.StopTimeField.Enable=~value; catch, end
        end

        function status(obj,text)
            try, obj.StatusLabel.Text=char(string(text)); drawnow limitrate; catch, end
        end

        function handleError(obj,ME,stage)
            obj.DiagnosticsManager.recordException(ME,stage); obj.status(['ERROR | ' stage ' | ' ME.message]); obj.showDiagnostics();
        end

        function showDiagnostics(obj)
            try, obj.DiagnosticsArea.Value=obj.DiagnosticsManager.asCell(); catch, end
        end

        function clearDiagnostics(obj)
            obj.DiagnosticsManager.clear(); obj.showDiagnostics();
        end

        function updateCompatibility(obj)
            try
                info=obj.CompatibilityManager.snapshot();
                obj.CompatibilityLabel.Text=sprintf('MATLAB %s | Simulink %s | Stateflow %s | TargetLink %s',obj.safeText(info.MATLAB),obj.safeText(info.Simulink),obj.safeText(info.Stateflow),obj.boolText(info.TargetLinkAvailable));
            catch ME
                obj.CompatibilityLabel.Text='Compatibility check unavailable'; obj.DiagnosticsManager.recordException(ME,'Compatibility check');
            end
        end

        function text=safeText(~,v)
            if isempty(v), text='n/a'; else, text=char(string(v)); end
        end
        function text=boolText(~,v)
            if logical(v), text='available'; else, text='not detected'; end
        end

        function navigateToBlock(obj)
            path=char(string(obj.BlockField.Value)); if isempty(strtrim(path)), return; end
            try, open_system(path); try, hilite_system(path,'find'); catch, end; obj.status(['Opened: ' path]); catch ME, obj.handleError(ME,'Open selected block'); end
        end
    end
end