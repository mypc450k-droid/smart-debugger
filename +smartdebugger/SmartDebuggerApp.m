classdef SmartDebuggerApp < handle
    %SMARTDEBUGGERAPP Main programmatic UI for MIL/SIL debugging.
    properties (SetAccess=private)
        UIFigure
        ModelManager
        SimulationManager
        ComparisonEngine
        DiagnosticsManager
        CompatibilityManager
        Mode = "MIL"
        SelectedBlock = ""
        MILResult = []
        SILResult = []
    end
    properties (Access=private)
        ModelField
        SILModelField
        StopTimeField
        ModeGroup
        BlockField
        InputsTable
        OutputsTable
        StatusLabel
        DiagnosticsArea
        ComparisonTable
        Axes
        ToleranceAbsField
        ToleranceRelField
    end
    methods
        function obj = SmartDebuggerApp(varargin)
            obj.DiagnosticsManager = smartdebugger.DiagnosticsManager();
            obj.CompatibilityManager = smartdebugger.CompatibilityManager();
            obj.ModelManager = smartdebugger.ModelManager(obj.DiagnosticsManager);
            obj.SimulationManager = smartdebugger.SimulationManager(obj.DiagnosticsManager);
            obj.ComparisonEngine = smartdebugger.ComparisonEngine();
            obj.buildUI();
            if ~isempty(varargin)
                obj.configure(varargin{:});
            end
            obj.updateCompatibility();
        end
        function configure(obj,varargin)
            p = inputParser;
            addParameter(p,'Model','',@(x)ischar(x)||isstring(x));
            addParameter(p,'SILModel','',@(x)ischar(x)||isstring(x));
            parse(p,varargin{:});
            if strlength(string(p.Results.Model)) > 0, obj.setMILModel(p.Results.Model); end
            if strlength(string(p.Results.SILModel)) > 0, obj.SILModelField.Value = char(p.Results.SILModel); end
        end
        function setMILModel(obj,model)
            obj.ModelField.Value = char(model);
            obj.ModelManager.loadModel(char(model));
            obj.status("MIL model loaded: " + string(model));
            obj.refreshBlockSelection();
        end
        function refreshBlockSelection(obj)
            try
                path = obj.ModelManager.currentSimulinkSelection();
                if strlength(string(path)) > 0
                    obj.SelectedBlock = string(path);
                    obj.BlockField.Value = char(path);
                    obj.inspectBlock();
                else
                    obj.status("No Simulink block is currently selected.");
                end
            catch ME
                obj.DiagnosticsManager.recordException(ME,'Selection');
                obj.showDiagnostics();
            end
        end
        function inspectBlock(obj)
            path = strtrim(string(obj.BlockField.Value));
            if path == "", return; end
            obj.SelectedBlock = path;
            info = obj.ModelManager.inspectBlock(char(path));
            if isempty(info)
                obj.status("Block could not be inspected.");
                return
            end
            obj.populatePorts(info);
            obj.status("Selected: " + path);
        end
        function runDebug(obj)
            try
                obj.inspectBlock();
                model = char(obj.ModelField.Value);
                block = char(obj.SelectedBlock);
                stopTime = char(obj.StopTimeField.Value);
                if isempty(model) || isempty(block)
                    error('SmartDebugger:MissingTarget','Select a model and block first.');
                end
                obj.setBusy(true);
                if obj.Mode == "MIL"
                    obj.MILResult = obj.SimulationManager.runMIL(model,block,stopTime);
                    result = obj.MILResult;
                else
                    silModel = char(obj.SILModelField.Value);
                    if isempty(silModel), error('SmartDebugger:MissingSILModel','Specify a SIL model before SIL debugging.'); end
                    result = obj.SimulationManager.runSIL(silModel,block,stopTime);
                    obj.SILResult = result;
                end
                obj.displayRuntimeResult(result);
                obj.status(obj.Mode + " debug completed.");
            catch ME
                obj.DiagnosticsManager.recordException(ME,'Debug run');
                obj.status("Debug run failed. See Diagnostics.");
                obj.showDiagnostics();
            end
            obj.setBusy(false);
        end
        function compare(obj)
            try
                if isempty(obj.MILResult) || isempty(obj.SILResult)
                    error('SmartDebugger:MissingResults','Run both MIL and SIL before comparison.');
                end
                a = str2double(obj.ToleranceAbsField.Value);
                r = str2double(obj.ToleranceRelField.Value);
                report = obj.ComparisonEngine.compare(obj.MILResult,obj.SILResult,a,r);
                obj.displayComparison(report);
                obj.plotComparison(report);
                obj.status("Comparison completed: " + string(report.Status));
            catch ME
                obj.DiagnosticsManager.recordException(ME,'MIL/SIL comparison');
                obj.showDiagnostics();
            end
        end
        function showDiagnostics(obj)
            if isempty(obj.DiagnosticsArea) || ~isvalid(obj.DiagnosticsArea), return; end
            obj.DiagnosticsArea.Value = obj.DiagnosticsManager.asCell();
        end
    end
    methods (Access=private)
        function buildUI(obj)
            obj.UIFigure = uifigure('Name','Smart Debugger','Position',[80 60 1400 820]);
            obj.UIFigure.CloseRequestFcn = @(~,~)obj.closeApp();
            g = uigridlayout(obj.UIFigure,[3 3]);
            g.RowHeight = {55,'1x',190}; g.ColumnWidth = {270,'1x',360};
            top = uipanel(g); top.Layout.Row=1; top.Layout.Column=[1 3];
            tg = uigridlayout(top,[1 10]); tg.ColumnWidth={90,170,170,80,80,90,90,90,90,'1x'};
            uibutton(tg,'Text','Open MIL','ButtonPushedFcn',@(~,~)obj.chooseMIL());
            obj.ModelField = uieditfield(tg,'text','Placeholder','MIL model');
            obj.SILModelField = uieditfield(tg,'text','Placeholder','SIL model');
            obj.ModeGroup = uidropdown(tg,'Items',{'MIL','SIL'},'Value','MIL','ValueChangedFcn',@(s,~)obj.modeChanged(s));
            uibutton(tg,'Text','Import Selection','ButtonPushedFcn',@(~,~)obj.refreshBlockSelection());
            uibutton(tg,'Text','Inspect','ButtonPushedFcn',@(~,~)obj.inspectBlock());
            uibutton(tg,'Text','Debug','ButtonPushedFcn',@(~,~)obj.runDebug());
            uibutton(tg,'Text','Compare','ButtonPushedFcn',@(~,~)obj.compare());
            obj.StopTimeField = uieditfield(tg,'text','Value','10');
            obj.StatusLabel = uilabel(tg,'Text','Ready');
            left = uipanel(g,'Title','Debug Target'); left.Layout.Row=2; left.Layout.Column=1;
            lg=uigridlayout(left,[5 1]); lg.RowHeight={22,35,35,'1x',35};
            uilabel(lg,'Text','Selected block path');
            obj.BlockField=uieditfield(lg,'text','Placeholder','model/subsystem/block');
            uibutton(lg,'Text','Inspect block','ButtonPushedFcn',@(~,~)obj.inspectBlock());
            obj.DiagnosticsArea=uitextarea(lg,'Editable','off','Value',{'Diagnostics'});
            uibutton(lg,'Text','Refresh diagnostics','ButtonPushedFcn',@(~,~)obj.showDiagnostics());
            center=uipanel(g,'Title','Runtime Signals'); center.Layout.Row=2; center.Layout.Column=2;
            cg=uigridlayout(center,[3 1]); cg.RowHeight={'1x','1x','1x'};
            obj.InputsTable=uitable(cg,'ColumnName',{'Port','Name','Value','Type','Size','SampleTime'});
            obj.OutputsTable=uitable(cg,'ColumnName',{'Port','Name','Value','Type','Size','SampleTime'});
            obj.ComparisonTable=uitable(cg,'ColumnName',{'Signal','Status','MaxAbsError','MaxRelError','FirstMismatch'});
            right=uipanel(g,'Title','Comparison / Settings'); right.Layout.Row=2; right.Layout.Column=3;
            rg=uigridlayout(right,[6 2]); rg.RowHeight={25,25,25,25,'1x',30};
            uilabel(rg,'Text','Absolute tolerance'); obj.ToleranceAbsField=uieditfield(rg,'text','Value','1e-6');
            uilabel(rg,'Text','Relative tolerance'); obj.ToleranceRelField=uieditfield(rg,'text','1e-4');
            uilabel(rg,'Text','Mode'); uilabel(rg,'Text','MIL / SIL');
            uilabel(rg,'Text','Model compatibility'); uilabel(rg,'Text','Checking...','Tag','Compatibility');
            obj.Axes=uiaxes(rg); obj.Axes.Layout.Row=[5 6]; obj.Axes.Layout.Column=[1 2];
            bottom=uipanel(g,'Title','Instructions'); bottom.Layout.Row=3; bottom.Layout.Column=[1 3];
            uitextarea(bottom,'Editable','off','Value',{ ...
                'Workflow: open MIL model -> select a block in Simulink -> Import Selection -> Inspect -> Debug.', ...
                'For SIL, enter the SIL model and select SIL mode. Use Compare after both simulations complete.', ...
                'The app uses adapters and capability checks. Unsupported runtime inspection is reported rather than fabricated.', ...
                'No permanent Scope/To Workspace/TargetLink Sink blocks are created by this application.'});
        end
        function chooseMIL(obj)
            [f,p]=uigetfile({'*.slx;*.mdl','Simulink Models'},'Select MIL model');
            if isequal(f,0), return; end
            obj.setMILModel(fullfile(p,f));
        end
        function modeChanged(obj,s)
            obj.Mode=string(s.Value); obj.status("Mode: " + obj.Mode);
        end
        function updateCompatibility(obj)
            c=obj.CompatibilityManager.snapshot();
            obj.status("Ready | " + string(c.MATLAB));
        end
        function populatePorts(obj,info)
            obj.InputsTable.Data=obj.portRows(info.Inputs);
            obj.OutputsTable.Data=obj.portRows(info.Outputs);
        end
        function rows=portRows( obj, ports ) %#ok<INUSD>
            if isempty(ports), rows=cell(0,6); return; end
            rows=cell(numel(ports),6);
            for k=1:numel(ports)
                p=ports(k); rows{k,1}=p.Port; rows{k,2}=p.Name; rows{k,3}=p.Value;
                rows{k,4}=p.DataType; rows{k,5}=p.Dimension; rows{k,6}=p.SampleTime;
            end
        end
        function displayRuntimeResult(obj,result)
            if ~isstruct(result), return; end
            if isfield(result,'Inputs'), obj.InputsTable.Data=obj.portRows(result.Inputs); end
            if isfield(result,'Outputs'), obj.OutputsTable.Data=obj.portRows(result.Outputs); end
        end
        function displayComparison(obj,report)
            obj.ComparisonTable.Data=report.Table;
        end
        function plotComparison(obj,report)
            cla(obj.Axes);
            if isfield(report,'Time') && ~isempty(report.Time)
                hold(obj.Axes,'on');
                if isfield(report,'MIL'), plot(obj.Axes,report.Time,report.MIL,'DisplayName','MIL'); end
                if isfield(report,'SIL'), plot(obj.Axes,report.Time,report.SIL,'DisplayName','SIL'); end
                if isfield(report,'Error'), plot(obj.Axes,report.Time,report.Error,'DisplayName','Error'); end
                hold(obj.Axes,'off'); legend(obj.Axes,'show'); grid(obj.Axes,'on');
            end
        end
        function status(obj,msg), obj.StatusLabel.Text=char(msg); end
        function setBusy(obj,b), obj.UIFigure.Pointer = ternary(b,'watch','arrow'); drawnow; end
        function closeApp(obj), delete(obj.UIFigure); end
    end
end
function y=ternary(c,a,b), if c,y=a;else,y=b;end,end
