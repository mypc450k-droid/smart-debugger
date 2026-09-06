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
        function obj=SmartDebuggerApp(varargin)
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
            addParameter(p,'MILModel','',@(x)ischar(x)||isstring(x));
            addParameter(p,'SILModel','',@(x)ischar(x)||isstring(x));
            addParameter(p,'Mode','MIL',@(x)ischar(x)||isstring(x));
            parse(p,varargin{:});
            obj.MILModelField.Value=char(string(p.Results.MILModel));
            obj.SILModelField.Value=char(string(p.Results.SILModel));
            obj.Mode=upper(char(string(p.Results.Mode)));
            obj.ModeDropDown.Value=obj.Mode;
        end

        function runDebug(obj)
            if obj.Busy, return; end
            obj.setBusy(true); cleanup=onCleanup(@()obj.setBusy(false));
            try
                obj.validateRunInputs();
                stopTime=strtrim(char(string(obj.StopTimeField.Value)));
                if strcmpi(obj.Mode,'MIL')
                    model=obj.resolveMILModel();
                    obj.status(['Running MIL: ' obj.RunTargetBlock]); drawnow;
                    runResult=obj.SimulationManager.run(model,obj.RunTargetBlock,stopTime,'MIL');
                    obj.MILResult=runResult;
                else
                    % TargetLink SIL is intentionally routed through the native
                    % TargetLink manager. Do not use SimulationManager.runSIL
                    % here: that path is the generic Simulink logsout/sigsOut
                    % mechanism and is not the TargetLink Data Server path.
                    silModel=char(string(obj.SILModelField.Value));
                    if isempty(strtrim(silModel))
                        error('SmartDebugger:SILModelRequired','A TargetLink/SIL model is required for SIL.');
                    end
                    silBlock=obj.RunTargetBlock;
                    override=char(string(obj.SILBlockField.Value));
                    if ~isempty(strtrim(override))
                        silBlock=override;
                    end
                    obj.SelectedSILBlock=silBlock;
                    obj.SILBlockField.Value=silBlock;
                    obj.status(['Running TargetLink SIL: ' silBlock]);
                    drawnow;

                    tlManager=smartdebugger.TargetLinkSILManager();
                    runResult=tlManager.run(silModel,silBlock,stopTime,false);
                    runResult.Mode='SIL';
                    runResult.Block=silBlock;
                    runResult.SimulationOutput=[];
                    runResult=obj.adaptTargetLinkResultForRuntimeUI(runResult,silBlock);
                    obj.SILResult=runResult;
                end
                obj.displayRuntimeResult(runResult);
                obj.status(sprintf('Run complete | %s | %d runtime series',obj.Mode,obj.countSeries(runResult)));
            catch ME
                obj.handleError(ME,'Debug run');
            end
        end

        function compare(obj)
            if isempty(obj.MILResult)||isempty(obj.SILResult)
                error('SmartDebugger:MissingRunResults','Run both MIL and SIL before comparison.');
            end
            obj.FirstDivergenceLabel.Text='Comparing...';
            try
                report=obj.ComparisonEngine.compare(obj.MILResult,obj.SILResult,...
                    str2double(char(string(obj.AbsToleranceField.Value))),...
                    str2double(char(string(obj.RelToleranceField.Value))),...
                    char(string(obj.AlignmentDropDown.Value)));
                obj.ComparisonTable.Data=report.Table;
                obj.plotComparison(report);
                if report.HasMismatch
                    obj.FirstDivergenceLabel.Text=sprintf('First divergence: %s',report.FirstDivergence);
                else
                    obj.FirstDivergenceLabel.Text='No divergence within tolerance.';
                end
            catch ME
                obj.handleError(ME,'Compare');
            end
        end

        function selectBlock(obj,block)
            try
                obj.SelectedBlock=char(string(block));
                obj.RunTargetBlock=obj.SelectedBlock;
                obj.BlockField.Value=obj.SelectedBlock;
                obj.SILBlockField.Value=obj.SelectedBlock;
                info=obj.ModelManager.inspectBlock(obj.SelectedBlock);
                obj.BlockInfoArea.Value=obj.infoToLines(info);
            catch ME
                obj.handleError(ME,'Inspect block');
            end
        end

        function modeChanged(obj,value)
            obj.Mode=upper(char(string(value)));
            obj.status(['Mode: ' obj.Mode]);
        end
    end

    methods (Access=private)
        function buildUI(obj)
            obj.UIFigure=uifigure('Name','Smart Debugger','Position',[100 100 1450 850]);
            obj.UIFigure.WindowKeyPressFcn=@(src,event)obj.runtimeKeyPress(event);
            g=uigridlayout(obj.UIFigure,[3 3]); g.RowHeight={50,'1x',190}; g.ColumnWidth={360,'1x',430};
            top=uigridlayout(g,[1 8]); top.Layout.Row=1; top.Layout.Column=[1 3]; top.ColumnWidth={70,210,70,210,70,120,100,'1x'};
            uilabel(top,'Text','Mode'); obj.ModeDropDown=uidropdown(top,'Items',{'MIL','SIL'},'Value','MIL','ValueChangedFcn',@(src,event)obj.modeChanged(src.Value));
            uilabel(top,'Text','MIL Model'); obj.MILModelField=uieditfield(top,'text','Placeholder','model');
            uilabel(top,'Text','SIL Model'); obj.SILModelField=uieditfield(top,'text','Placeholder','TargetLink model');
            uilabel(top,'Text','Stop'); obj.StopTimeField=uieditfield(top,'text','Value','auto');
            uibutton(top,'Text','Run Debug','ButtonPushedFcn',@(src,event)obj.runDebug());
            uibutton(top,'Text','Compare','ButtonPushedFcn',@(src,event)obj.compare());
            uibutton(top,'Text','Clear Diagnostics','ButtonPushedFcn',@(src,event)obj.clearDiagnostics());
            obj.CompatibilityLabel=uilabel(top,'Text','Compatibility');
            left=uipanel(g,'Title','Selected Block'); left.Layout.Row=2; left.Layout.Column=1;
            lg=uigridlayout(left,[6 1]); lg.RowHeight={22,22,40,90,'1x',30};
            obj.BlockField=uieditfield(lg,'text','Editable','off');
            obj.SILBlockField=uieditfield(lg,'text','Value','','Placeholder','Optional SIL block override');
            obj.BlockInfoArea=uitextarea(lg,'Editable','off');
            obj.StatusLabel=uilabel(lg,'Text','Ready');
            obj.FirstDivergenceLabel=uilabel(lg,'Text','No comparison yet');
            right=uipanel(g,'Title','Diagnostics'); right.Layout.Row=2; right.Layout.Column=3;
            obj.DiagnosticsArea=uitextarea(right,'Editable','off','Position',[10 10 400 620]);
            center=uipanel(g,'Title','Runtime'); center.Layout.Row=2; center.Layout.Column=2;
            cg=uigridlayout(center,[2 1]); cg.RowHeight={'1x',160};
            obj.PlotAxes=uiaxes(cg); obj.PlotAxes.Layout.Row=1;
            obj.RuntimeSummary=uilabel(cg,'Text','No runtime data'); obj.RuntimeSummary.Layout.Row=2;
            obj.RuntimeTabs=uitabgroup(center,'Position',[10 10 690 145]);
            t1=uitab(obj.RuntimeTabs,'Title','Inputs'); t2=uitab(obj.RuntimeTabs,'Title','Outputs'); t3=uitab(obj.RuntimeTabs,'Title','Samples'); t4=uitab(obj.RuntimeTabs,'Title','Trace');
            obj.InputsTable=uitable(t1,'ColumnName',{'Port','Name','Value','Data Type','Dimension','Sample Time'},'CellSelectionCallback',@(src,event)obj.runtimeSelection(src,event,'Input'),'Position',[5 5 660 120]);
            obj.OutputsTable=uitable(t2,'ColumnName',{'Port','Name','Value','Data Type','Dimension','Sample Time'},'CellSelectionCallback',@(src,event)obj.runtimeSelection(src,event,'Output'),'Position',[5 5 660 120]);
            obj.SampleTable=uitable(t3,'ColumnName',{'Time (s)','Value'},'Position',[5 5 660 120]);
            obj.AbsToleranceField=uieditfield(t4,'text','Value','1e-9','Position',[5 90 120 22]);
            obj.RelToleranceField=uieditfield(t4,'text','Value','1e-6','Position',[135 90 120 22]);
            obj.AlignmentDropDown=uidropdown(t4,'Items',{'intersection','resample'},'Value','intersection','Position',[265 90 120 22]);
            g2=uigridlayout(g,[1 3]); g2.Layout.Row=3; g2.Layout.Column=[1 3]; g2.ColumnWidth={'1x','1x','1x'};
            uilabel(g2,'Text','Smart Debugger | Native TargetLink SIL uses TargetLink Data Server');
            obj.TreeModel='';
        end

        function text=infoToLines(~,info)
            if isempty(info), text={}; return; end
            text={};
            if isfield(info,'Path'), text{end+1}=['Path: ' char(string(info.Path))]; end
            if isfield(info,'BlockType'), text{end+1}=['Type: ' char(string(info.BlockType))]; end
            if isfield(info,'MaskType'), text{end+1}=['Mask: ' char(string(info.MaskType))]; end
            if isfield(info,'TargetLinkBlockType'), text{end+1}=['TL Type: ' char(string(info.TargetLinkBlockType))]; end
            if isfield(info,'Inputs'), text{end+1}=sprintf('Inputs: %d',numel(info.Inputs)); end
            if isfield(info,'Outputs'), text{end+1}=sprintf('Outputs: %d',numel(info.Outputs)); end
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

        function result=adaptTargetLinkResultForRuntimeUI(obj,result,silBlock)
            % Convert native TargetLink Data Server rows into the existing
            % runtime-signal UI contract. MIL result handling is untouched.
            if ~isfield(result,'RuntimeSignals') || isempty(result.RuntimeSignals)
                result.Inputs=obj.safeInspectedPorts(silBlock,'Inputs');
                result.Outputs=obj.safeInspectedPorts(silBlock,'Outputs');
                return
            end

            inPorts=obj.safeInspectedPorts(silBlock,'Inputs');
            outPorts=obj.safeInspectedPorts(silBlock,'Outputs');
            used=false(1,numel(result.RuntimeSignals));

            % First attach runtime rows to inspected port names where possible.
            for k=1:numel(inPorts)
                idx=obj.findRuntimeMatch(result.RuntimeSignals,inPorts(k).Name,used);
                if idx>0
                    inPorts(k)=obj.attachRuntimeSeries(inPorts(k),result.RuntimeSignals(idx));
                    used(idx)=true;
                end
            end
            for k=1:numel(outPorts)
                idx=obj.findRuntimeMatch(result.RuntimeSignals,outPorts(k).Name,used);
                if idx>0
                    outPorts(k)=obj.attachRuntimeSeries(outPorts(k),result.RuntimeSignals(idx));
                    used(idx)=true;
                end
            end

            % Never discard native TargetLink log rows. If a row cannot be
            % matched to a selected port, expose it using a direction hint
            % from its name, with Outputs as the conservative fallback.
            for k=1:numel(result.RuntimeSignals)
                if used(k), continue; end
                row=result.RuntimeSignals(k);
                p=obj.makeRuntimePort(row);
                if obj.looksLikeInputSignal(row)
                    inPorts(end+1)=p; %#ok<AGROW>
                else
                    outPorts(end+1)=p; %#ok<AGROW>
                end
                used(k)=true;
            end

            result.Inputs=inPorts;
            result.Outputs=outPorts;
            result.SignalCount=obj.countSeries(result);
            result.RuntimeSignalCount=numel(result.RuntimeSignals);
            result.RuntimeUIDataSource='TargetLink Data Server';
        end

        function ports=safeInspectedPorts(obj,block,direction)
            % Always build a fresh homogeneous runtime-port array. The
            % ModelManager inspection structs intentionally have a smaller
            % schema, so assigning them directly and then adding Series can
            % trigger MATLAB:heterogeneousStrucAssignment.
            ports=obj.emptyRuntimePorts();
            try
                info=obj.ModelManager.inspectBlock(block);
                if ~isfield(info,direction) || isempty(info.(direction)), return; end

                sourcePorts=info.(direction);
                for k=1:numel(sourcePorts)
                    src=sourcePorts(k);
                    p=struct('Port',0,'Name','','LogName','','Value',[], ...
                        'DataType','','Dimension',[],'SampleTime','','Series',[], ...
                        'LineHandle',[],'SignalHandle',[],'LoggingHandle',[]);

                    if isfield(src,'Port'), p.Port=src.Port; end
                    if isfield(src,'Name'), p.Name=src.Name; end
                    if isfield(src,'LogName'), p.LogName=src.LogName; end
                    if isfield(src,'Value'), p.Value=src.Value; end
                    if isfield(src,'DataType'), p.DataType=src.DataType; end
                    if isfield(src,'Dimension'), p.Dimension=src.Dimension; end
                    if isfield(src,'SampleTime'), p.SampleTime=src.SampleTime; end
                    if isfield(src,'LineHandle'), p.LineHandle=src.LineHandle; end
                    if isfield(src,'SignalHandle'), p.SignalHandle=src.SignalHandle; end
                    if isfield(src,'LoggingHandle'), p.LoggingHandle=src.LoggingHandle; end

                    if isempty(p.Name), p.Name=sprintf('%s %d',direction,k); end
                    if isempty(p.LogName), p.LogName=p.Name; end
                    ports(end+1)=p; %#ok<AGROW>
                end
            catch ME
                ports=obj.emptyRuntimePorts();
                obj.DiagnosticsManager.recordException(ME,['Inspect TargetLink ' direction]);
            end
        end

        function ports=emptyRuntimePorts(~)
            ports=struct('Port',{},'Name',{},'LogName',{},'Value',{}, ...
                'DataType',{},'Dimension',{},'SampleTime',{},'Series',{}, ...
                'LineHandle',{},'SignalHandle',{},'LoggingHandle',{});
        end

        function p=ensureRuntimePortFields(~,p)
            defaults=struct('Port',0,'Name','','LogName','','Value',[], ...
                'DataType','','Dimension',[],'SampleTime','','Series',[], ...
                'LineHandle',[],'SignalHandle',[],'LoggingHandle',[]);
            names=fieldnames(defaults);
            for k=1:numel(names)
                if ~isfield(p,names{k}), p.(names{k})=defaults.(names{k}); end
            end
            if isempty(p.LogName), p.LogName=p.Name; end
            if isempty(p.Series)
                p.Value=[];
            end
        end

        function p=attachRuntimeSeries(obj,p,row)
            p=obj.ensureRuntimePortFields(p);
            p.Name=char(string(row.Name));
            p.LogName=char(string(row.SourcePath));
            p.Series=struct('Time',row.Time,'Data',row.Data);
            p.Value=obj.lastRuntimeValue(row.Data);
            p.DataType=row.DataType;
            p.Dimension=row.Dimension;
            p.SampleTime=obj.inferSampleTime(row.Time);
        end

        function p=makeRuntimePort(obj,row)
            p=struct('Port',0,'Name','','LogName','','Value',[], ...
                'DataType','','Dimension',[],'SampleTime','','Series',[], ...
                'LineHandle',[],'SignalHandle',[],'LoggingHandle',[]);
            p.Name=char(string(row.Name));
            p.LogName=char(string(row.SourcePath));
            p.Value=obj.lastRuntimeValue(row.Data);
            p.DataType=row.DataType;
            p.Dimension=row.Dimension;
            p.SampleTime=obj.inferSampleTime(row.Time);
            p.Series=struct('Time',row.Time,'Data',row.Data);
        end

        function idx=findRuntimeMatch(obj,rows,name,used)
            idx=0;
            target=lower(strtrim(char(string(name))));
            if isempty(target), return; end
            best=inf;
            for k=1:numel(rows)
                if used(k), continue; end
                candidates={char(string(rows(k).Name)),char(string(rows(k).SourcePath))};
                for j=1:numel(candidates)
                    c=lower(strtrim(candidates{j}));
                    if isempty(c), continue; end
                    exact=strcmp(c,target);
                    suffix=endsWith(c,['/' target]) || endsWith(c,['.' target]);
                    leaf=strcmp(obj.leafName(c),obj.leafName(target));
                    if exact
                        score=1;
                    elseif suffix
                        score=2;
                    elseif leaf
                        score=3;
                    else
                        continue;
                    end
                    if score<best
                        best=score; idx=k;
                    end
                end
            end
        end

        function tf=looksLikeInputSignal(~,row)
            s=lower([char(string(row.Name)) ' ' char(string(row.SourcePath))]);
            tf=contains(s,'input') || contains(s,'inport') || ...
                ~isempty(regexp(s,'(^|[/_.])in([/_.]|[0-9]|$)','once'));
        end

        function value=lastRuntimeValue(~,data)
            if isempty(data), value=[]; return; end
            try
                if isvector(data), value=data(end);
                else, value=data(end,:); end
            catch, value=[]; end
        end

        function st=inferSampleTime(~,t)
            st='';
            try
                t=t(:); if numel(t)>=2, d=diff(t); d=d(isfinite(d)); if ~isempty(d), st=sprintf('%.12g',median(d)); end, end
            catch, end
        end

        function name=leafName(~,path)
            s=char(string(path)); parts=strsplit(strrep(s,'\\','/'),'/'); name=parts{end};
        end
    end
end
