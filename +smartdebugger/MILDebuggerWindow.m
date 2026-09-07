classdef MILDebuggerWindow < handle
    %MILDEBUGGERWINDOW Dedicated MIL window with multi-plot runtime view.
    % Uses the existing ModelManager and SimulationManager. No MIL engine,
    % logging, bus extraction, or diagnostics implementation is duplicated.

    properties (SetAccess=private)
        UIFigure
        ModelManager
        SimulationManager
        DiagnosticsManager
        Model = ''
        SelectedBlock = ''
        Result = []
    end

    properties (Access=private)
        Tree
        ModelLabel
        BlockLabel
        StopTimeField
        RunButton
        StatusLabel
        InputsTable
        OutputsTable
        SampleTable
        DiagnosticsArea
        GraphGrid
        Graphs
        ActiveGraph = 1
        DragGraph = 0
        Busy = false
    end

    methods
        function obj=MILDebuggerWindow(varargin)
            obj.DiagnosticsManager = smartdebugger.DiagnosticsManager();
            obj.ModelManager = smartdebugger.ModelManager(obj.DiagnosticsManager);
            obj.SimulationManager = smartdebugger.SimulationManager(obj.DiagnosticsManager);
            obj.Graphs = struct('Panel',{},'Axes',{},'DropDown',{},'Times',{}, ...
                'Values',{},'Index',{},'CursorLine',{},'CursorText',{});
            obj.buildUI();
            obj.autoDetectModel();
            if ~isempty(varargin)
                obj.configure(varargin{:});
            end
        end

        function configure(obj,varargin)
            p = inputParser;
            addParameter(p,'Model','',@(x)ischar(x)||isstring(x));
            parse(p,varargin{:});
            m = char(string(p.Results.Model));
            if ~isempty(strtrim(m))
                obj.setModel(m);
            end
        end

        function setModel(obj,model)
            try
                obj.ModelManager.loadModel(char(string(model)));
                obj.Model = obj.ModelManager.Model;
                obj.ModelLabel.Text = ['Detected model: ' obj.Model];
                obj.refreshTree();
                obj.status(['MIL model ready: ' obj.Model]);
            catch ME
                obj.handleError(ME,'Detect MIL model');
            end
        end

        function close(obj)
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
            obj.UIFigure = uifigure('Name','Smart Debugger | MIL Debugger', ...
                'Position',[30 40 1600 950], ...
                'CloseRequestFcn',@(~,~)obj.close(), ...
                'WindowKeyPressFcn',@(~,e)obj.keyPress(e), ...
                'WindowButtonDownFcn',@(~,~)obj.mouseDown(), ...
                'WindowButtonMotionFcn',@(~,~)obj.mouseMove(), ...
                'WindowButtonUpFcn',@(~,~)obj.mouseUp());

            r = uigridlayout(obj.UIFigure,[3 3]);
            r.RowHeight = {64,320,'1x'};
            r.ColumnWidth = {330,'1x',360};
            r.Padding = [8 8 8 8];
            r.RowSpacing = 8;
            r.ColumnSpacing = 8;
            obj.buildToolbar(r);
            obj.buildTree(r);
            obj.buildRuntime(r);
            obj.buildDiagnostics(r);
            obj.buildGraphs(r);
        end

        function buildToolbar(obj,p)
            q = uipanel(p);
            q.Layout.Row = 1;
            q.Layout.Column = [1 3];
            g = uigridlayout(q,[2 9]);
            g.RowHeight = {30,24};
            g.ColumnWidth = {80,280,85,260,80,90,80,100,'1x'};

            uibutton(g,'Text','Refresh', ...
                'ButtonPushedFcn',@(~,~)obj.autoDetectModel());
            obj.ModelLabel = uilabel(g,'Text','Detecting model...');
            uilabel(g,'Text','Selected block');
            obj.BlockLabel = uilabel(g,'Text','None');
            uibutton(g,'Text','Inspect', ...
                'ButtonPushedFcn',@(~,~)obj.inspectSelected());
            uilabel(g,'Text','Stop time');
            obj.StopTimeField = uieditfield(g,'text','Value','auto');
            obj.RunButton = uibutton(g,'Text','Run MIL', ...
                'ButtonPushedFcn',@(~,~)obj.runMIL());
            obj.StatusLabel = uilabel(g,'Text','Ready');
            obj.StatusLabel.Layout.Row = 2;
            obj.StatusLabel.Layout.Column = [1 9];
        end

        function buildTree(obj,p)
            q = uipanel(p,'Title','Model / Debug Target');
            q.Layout.Row = 2;
            q.Layout.Column = 1;
            g = uigridlayout(q,[2 1]);
            g.RowHeight = {30,'1x'};
            uibutton(g,'Text','Refresh model hierarchy', ...
                'ButtonPushedFcn',@(~,~)obj.refreshTree());
            obj.Tree = uitree(g,'SelectionChangedFcn',@(~,e)obj.treeChanged(e));
        end

        function buildRuntime(obj,p)
            q = uipanel(p,'Title','Runtime Signals | MIL');
            q.Layout.Row = 2;
            q.Layout.Column = 2;
            g = uigridlayout(q,[2 1]);
            g.RowHeight = {28,'1x'};
            uilabel(g,'Text','Select a signal row to send it to Graph 1.');
            tabs = uitabgroup(g);

            ti = uitab(tabs,'Title','Inputs');
            gi = uigridlayout(ti,[1 1]);
            obj.InputsTable = uitable(gi, ...
                'ColumnName',{'Port / Bus','Input Signal','Current Value','Data Type','Dimension','Samples / Sample Time'}, ...
                'RowName',{},'ColumnEditable',false(1,6), ...
                'CellSelectionCallback',@(s,e)obj.runtimeSelection(s,e,'Input'));

            to = uitab(tabs,'Title','Outputs');
            go = uigridlayout(to,[1 1]);
            obj.OutputsTable = uitable(go, ...
                'ColumnName',{'Port / Bus','Output Signal','Current Value','Data Type','Dimension','Samples / Sample Time'}, ...
                'RowName',{},'ColumnEditable',false(1,6), ...
                'CellSelectionCallback',@(s,e)obj.runtimeSelection(s,e,'Output'));

            ts = uitab(tabs,'Title','Samples');
            gs = uigridlayout(ts,[1 1]);
            obj.SampleTable = uitable(gs, ...
                'ColumnName',{'Time (s)','Value'},'RowName',{}, ...
                'ColumnEditable',false(1,2));
        end

        function buildDiagnostics(obj,p)
            q = uipanel(p,'Title','Analysis / Diagnostics');
            q.Layout.Row = 2;
            q.Layout.Column = 3;
            g = uigridlayout(q,[2 1]);
            g.RowHeight = {30,'1x'};
            uibutton(g,'Text','Refresh diagnostics', ...
                'ButtonPushedFcn',@(~,~)obj.showDiagnostics());
            obj.DiagnosticsArea = uitextarea(g,'Editable','off', ...
                'Value',{'No diagnostics.'});
        end

        function buildGraphs(obj,p)
            q = uipanel(p,'Title','MIL Runtime Graphs | multiple signals');
            q.Layout.Row = 3;
            q.Layout.Column = [1 3];
            g = uigridlayout(q,[2 1]);
            g.RowHeight = {34,'1x'};
            uibutton(g,'Text','+ Add graph', ...
                'ButtonPushedFcn',@(~,~)obj.addGraph());
            obj.GraphGrid = uigridlayout(g,[1 2]);
            obj.GraphGrid.Layout.Row = 2;
            obj.GraphGrid.Layout.Column = 1;
            obj.GraphGrid.ColumnWidth = {'1x','1x'};
            obj.GraphGrid.RowHeight = {'1x'};
            obj.addGraph();
            obj.addGraph();
        end

        function addGraph(obj)
            n = numel(obj.Graphs) + 1;
            if n > 12
                obj.status('Maximum of 12 MIL graphs reached.');
                return;
            end
            p = uipanel(obj.GraphGrid,'Title',sprintf('Graph %d',n));
            p.Layout.Column = mod(n-1,2) + 1;
            p.Layout.Row = ceil(n/2);
            g = uigridlayout(p,[2 2]);
            g.RowHeight = {28,'1x'};
            g.ColumnWidth = {'1x',65};
            d = uidropdown(g,'Items',{'Select runtime signal'}, ...
                'ItemsData',{''},'Value','');
            d.Layout.Column = 1;
            d.Layout.Row = 1;
            d.ValueChangedFcn = @(s,~)obj.graphChanged(obj.graphForDropdown(s),s);
            uibutton(g,'Text','Remove', ...
                'ButtonPushedFcn',@(~,~)obj.removeGraph(obj.graphForPanel(p)));
            ax = uiaxes(g);
            ax.Layout.Row = 2;
            ax.Layout.Column = [1 2];
            grid(ax,'on');
            xlabel(ax,'Time (s)');
            ylabel(ax,'Value');
            obj.Graphs(n) = struct('Panel',p,'Axes',ax,'DropDown',d, ...
                'Times',[],'Values',[],'Index',1,'CursorLine',[],'CursorText',[]);
            obj.rebuildGraphs();
            obj.refreshGraphChoices();
            obj.refreshGraphCallbacks();
        end

        function removeGraph(obj,n)
            if numel(obj.Graphs) <= 1
                obj.status('At least one graph must remain.');
                return;
            end
            if n < 1 || n > numel(obj.Graphs)
                return;
            end
            try
                delete(obj.Graphs(n).Panel);
            catch
            end
            obj.Graphs(n) = [];
            obj.rebuildGraphs();
            obj.refreshGraphChoices();
            obj.refreshGraphCallbacks();
            obj.ActiveGraph = min(obj.ActiveGraph,max(1,numel(obj.Graphs)));
        end

        function rebuildGraphs(obj)
            n = numel(obj.Graphs);
            if n == 0
                return;
            end
            obj.GraphGrid.RowHeight = repmat({'1x'},1,max(1,ceil(n/2)));
            for k = 1:n
                obj.Graphs(k).Panel.Layout.Row = ceil(k/2);
                obj.Graphs(k).Panel.Layout.Column = mod(k-1,2) + 1;
                obj.Graphs(k).Panel.Title = sprintf('Graph %d',k);
            end
        end

        function refreshGraphCallbacks(obj)
            for k = 1:numel(obj.Graphs)
                p = obj.Graphs(k).Panel;
                d = obj.Graphs(k).DropDown;
                d.ValueChangedFcn = @(s,~)obj.graphChanged(obj.graphForDropdown(s),s);
                b = findobj(p,'Type','uibutton','-regexp','Text','^Remove$');
                for j = 1:numel(b)
                    b(j).ButtonPushedFcn = @(~,~)obj.removeGraph(obj.graphForPanel(p));
                end
            end
        end

        function n = graphForDropdown(obj,d)
            n = 0;
            for k = 1:numel(obj.Graphs)
                try
                    if isequal(obj.Graphs(k).DropDown,d)
                        n = k;
                        return;
                    end
                catch
                end
            end
        end

        function n = graphForPanel(obj,p)
            n = 0;
            for k = 1:numel(obj.Graphs)
                try
                    if isequal(obj.Graphs(k).Panel,p)
                        n = k;
                        return;
                    end
                catch
                end
            end
        end

        function autoDetectModel(obj)
            m = obj.detectOpenModel();
            if isempty(m)
                obj.ModelLabel.Text = 'No open Simulink model detected';
                obj.status('Open the Simulink model, then press Refresh.');
                return;
            end
            if ~strcmp(obj.Model,m)
                obj.setModel(m);
            else
                obj.refreshTree();
            end
        end

        function m = detectOpenModel(~)
            m = '';
            try
                s = get_param(0,'CurrentSystem');
                if ~isempty(s)
                    m = bdroot(s);
                end
            catch
            end
            if isempty(m)
                try
                    s = gcs;
                    if ~isempty(s)
                        m = bdroot(s);
                    end
                catch
                end
            end
            if isempty(m)
                try
                    r = find_system(0,'SearchDepth',0,'Type','block_diagram');
                    if ~isempty(r)
                        m = char(string(r{1}));
                    end
                catch
                end
            end
            if ~isempty(m)
                try
                    if ~bdIsLoaded(m)
                        m = '';
                    end
                catch
                end
            end
        end

        function refreshTree(obj)
            if isempty(obj.Model) || ~bdIsLoaded(obj.Model)
                return;
            end
            try
                delete(obj.Tree.Children);
            catch
            end
            top = uitreenode(obj.Tree,'Text',obj.Model,'NodeData',obj.Model);
            obj.addChildren(top,obj.Model);
            try
                expand(top);
            catch
            end
        end

        function addChildren(obj,parent,path)
            try
                c = find_system(path,'SearchDepth',1,'Type','Block');
            catch
                return;
            end
            for k = 1:numel(c)
                if strcmp(c{k},path)
                    continue;
                end
                try
                    nm = get_param(c{k},'Name');
                catch
                    nm = c{k};
                end
                n = uitreenode(parent,'Text',nm,'NodeData',c{k}); %#ok<NASGU>
                try
                    if strcmpi(get_param(c{k},'BlockType'),'SubSystem')
                        obj.addChildren(n,c{k});
                    end
                catch
                end
            end
        end

        function treeChanged(obj,e)
            try
                if isempty(e.SelectedNodes)
                    return;
                end
                p = char(string(e.SelectedNodes(1).NodeData));
                get_param(p,'Handle');
                obj.SelectedBlock = p;
                obj.BlockLabel.Text = p;
            catch ME
                obj.handleError(ME,'Tree selection');
            end
        end

        function inspectSelected(obj)
            if isempty(obj.SelectedBlock)
                obj.status('Select a block first.');
                return;
            end
            try
                info = obj.ModelManager.inspectBlock(obj.SelectedBlock);
                if isempty(info)
                    obj.status('Inspection failed.');
                else
                    obj.status(['Inspected: ' obj.SelectedBlock]);
                end
            catch ME
                obj.handleError(ME,'Inspect block');
            end
        end

        function runMIL(obj)
            if obj.Busy
                return;
            end
            if isempty(obj.Model)
                obj.autoDetectModel();
            end
            if isempty(obj.Model)
                return;
            end
            if isempty(obj.SelectedBlock)
                obj.SelectedBlock = obj.detectSelectedBlock();
                if ~isempty(obj.SelectedBlock)
                    obj.BlockLabel.Text = obj.SelectedBlock;
                end
            end
            if isempty(obj.SelectedBlock)
                obj.status('Select a debug block before running MIL.');
                return;
            end
            stopTime = char(string(obj.StopTimeField.Value));
            if isempty(strtrim(stopTime))
                stopTime = 'auto';
            end
            obj.Busy = true;
            obj.RunButton.Enable = 'off';
            c = onCleanup(@()obj.finishRun()); %#ok<NASGU>
            try
                obj.status(['Running MIL: ' obj.SelectedBlock]);
                drawnow;
                obj.Result = obj.SimulationManager.runMIL(obj.Model,obj.SelectedBlock,stopTime);
                obj.displayResult(obj.Result);
                obj.status(['MIL completed: ' obj.Result.Status ...
                    obj.optionalMessage(obj.Result.Message)]);
            catch ME
                obj.handleError(ME,'MIL run');
            end
        end

        function finishRun(obj)
            obj.Busy = false;
            try
                obj.RunButton.Enable = 'on';
            catch
            end
        end

        function p = detectSelectedBlock(~)
            p = '';
            try
                s = get_param(0,'SelectedBlocks');
                if iscell(s) && ~isempty(s)
                    p = s{1};
                elseif isstring(s) && ~isempty(s)
                    p = char(s(1));
                elseif ischar(s)
                    p = s;
                end
            catch
            end
            if isempty(p)
                try
                    p = gcb;
                    get_param(p,'Handle');
                catch
                    p = '';
                end
            end
        end

        function displayResult(obj,r)
            obj.InputsTable.Data = obj.tableData(r.Inputs);
            obj.OutputsTable.Data = obj.tableData(r.Outputs);
            obj.SampleTable.Data = cell(0,2);
            obj.refreshGraphChoices();
            all = obj.signalItems(r);
            for k = 1:min(numel(all),numel(obj.Graphs))
                obj.Graphs(k).DropDown.Value = all{k}.Key;
                obj.graphChanged(k,obj.Graphs(k).DropDown);
            end
            obj.showDiagnostics();
        end

        function d = tableData(obj,p)
            d = cell(numel(p),6);
            for k = 1:numel(p)
                d{k,1} = p(k).Port;
                d{k,2} = p(k).Name;
                d{k,3} = obj.formatValue(p(k).Value);
                d{k,4} = p(k).DataType;
                d{k,5} = p(k).Dimension;
                d{k,6} = p(k).SampleTime;
            end
        end

        function runtimeSelection(obj,~,e,dir)
            if isempty(e.Indices) || isempty(obj.Result)
                return;
            end
            k = e.Indices(1);
            if strcmpi(dir,'Input')
                p = obj.Result.Inputs;
            else
                p = obj.Result.Outputs;
            end
            if k <= numel(p) && ~isempty(p(k).Series)
                obj.setGraphSignal(1,[dir ':' num2str(k)]);
            end
        end

        function items = signalItems(~,r)
            items = {};
            for k = 1:numel(r.Inputs)
                if ~isempty(r.Inputs(k).Series)
                    items{end+1} = struct('Key',['Input:' num2str(k)], ...
                        'Display',['Input | ' r.Inputs(k).Name]); %#ok<AGROW>
                end
            end
            for k = 1:numel(r.Outputs)
                if ~isempty(r.Outputs(k).Series)
                    items{end+1} = struct('Key',['Output:' num2str(k)], ...
                        'Display',['Output | ' r.Outputs(k).Name]); %#ok<AGROW>
                end
            end
        end

        function refreshGraphChoices(obj)
            items = {'Select runtime signal'};
            data = {''};
            if ~isempty(obj.Result)
                a = obj.signalItems(obj.Result);
                for k = 1:numel(a)
                    items{end+1} = a{k}.Display; %#ok<AGROW>
                    data{end+1} = a{k}.Key; %#ok<AGROW>
                end
            end
            for k = 1:numel(obj.Graphs)
                d = obj.Graphs(k).DropDown;
                old = char(string(d.Value));
                d.Items = items;
                d.ItemsData = data;
                if any(strcmp(data,old))
                    d.Value = old;
                else
                    d.Value = '';
                end
            end
        end

        function setGraphSignal(obj,n,key)
            if n < 1 || n > numel(obj.Graphs)
                return;
            end
            d = obj.Graphs(n).DropDown;
            if any(strcmp(d.ItemsData,key))
                d.Value = key;
                obj.graphChanged(n,d);
            end
        end

        function graphChanged(obj,n,d)
            if n < 1 || n > numel(obj.Graphs) || isempty(obj.Result)
                return;
            end
            key = char(string(d.Value));
            [t,y,name] = obj.resolveSignal(key);
            obj.Graphs(n).Times = t;
            obj.Graphs(n).Values = y;
            obj.Graphs(n).Index = 1;
            cla(obj.Graphs(n).Axes);
            if isempty(t)
                title(obj.Graphs(n).Axes,'Select runtime signal');
                return;
            end
            obj.plotSignal(obj.Graphs(n).Axes,t,y);
            title(obj.Graphs(n).Axes, ...
                [name ' | drag cursor or use left/right arrows'], ...
                'Interpreter','none');
            obj.updateCursor(n);
        end

        function [t,y,name] = resolveSignal(obj,key)
            t = [];
            y = [];
            name = '';
            if isempty(key)
                return;
            end
            z = regexp(key,'^(Input|Output):(\d+)$','tokens','once');
            if isempty(z)
                return;
            end
            k = str2double(z{2});
            if strcmp(z{1},'Input')
                p = obj.Result.Inputs;
            else
                p = obj.Result.Outputs;
            end
            if k < 1 || k > numel(p) || isempty(p(k).Series)
                return;
            end
            name = p(k).Name;
            [t,y] = obj.seriesXY(p(k).Series);
        end

        function plotSignal(~,ax,t,y)
            n = min(numel(t),numel(y));
            t = t(1:n);
            y = y(1:n);
            if islogical(y)
                y = double(y);
            end
            regular = false;
            if n >= 2
                d = diff(t);
                m = median(d);
                regular = all(abs(d-m) <= max(1e-10,1e-8*max(abs(m),1)));
            end
            if regular
                stairs(ax,t,y,'Marker','.','LineWidth',1);
            else
                plot(ax,t,y,'Marker','.','LineStyle','-');
            end
            grid(ax,'on');
            xlabel(ax,'Time (s)');
            ylabel(ax,'Value');
            if n > 1
                xlim(ax,[t(1) t(end)]);
            end
        end

        function [t,y] = seriesXY(~,s)
            t = s.Time(:);
            d = s.Data;
            if isempty(d)
                y = [];
                return;
            end
            if isvector(d)
                n = min(numel(t),numel(d));
                y = d(1:n);
                t = t(1:n);
            else
                sz = size(d);
                if sz(1) == numel(t)
                    y = d(:,1);
                elseif sz(end) == numel(t)
                    q = reshape(d,[],sz(end));
                    y = q(1,:).';
                    t = t(1:numel(y));
                else
                    q = d(:);
                    n = min(numel(t),numel(q));
                    y = q(1:n);
                    t = t(1:n);
                end
            end
            if ~isnumeric(y) && ~islogical(y)
                y = double(y);
            end
        end

        function keyPress(obj,e)
            if obj.Busy || isempty(obj.Graphs)
                return;
            end
            switch lower(char(string(e.Key)))
                case {'rightarrow','right'}
                    obj.moveCursor(obj.ActiveGraph,1);
                case {'leftarrow','left'}
                    obj.moveCursor(obj.ActiveGraph,-1);
                case 'home'
                    obj.setCursor(obj.ActiveGraph,1);
                case 'end'
                    obj.setCursor(obj.ActiveGraph, ...
                        numel(obj.Graphs(obj.ActiveGraph).Times));
            end
        end

        function moveCursor(obj,n,delta)
            if n >= 1 && n <= numel(obj.Graphs)
                obj.setCursor(n,obj.Graphs(n).Index + delta);
            end
        end

        function setCursor(obj,n,i)
            if n < 1 || n > numel(obj.Graphs) || isempty(obj.Graphs(n).Times)
                return;
            end
            obj.Graphs(n).Index = max(1,min(numel(obj.Graphs(n).Times),round(i)));
            obj.updateCursor(n);
        end

        function updateCursor(obj,n)
            g = obj.Graphs(n);
            if isempty(g.Times) || isempty(g.Values)
                return;
            end
            i = g.Index;
            t = g.Times(i);
            v = g.Values(i);
            try
                if ~isempty(g.CursorLine) && isvalid(g.CursorLine)
                    delete(g.CursorLine);
                end
            catch
            end
            try
                if ~isempty(g.CursorText) && isvalid(g.CursorText)
                    delete(g.CursorText);
                end
            catch
            end
            g.CursorLine = xline(g.Axes,t,'--','Cursor');
            g.CursorText = text(g.Axes,t,v, ...
                sprintf('  #%d  t=%.12g  value=%s',i,t,obj.formatValue(v)), ...
                'Interpreter','none','VerticalAlignment','bottom');
            obj.Graphs(n) = g;
            obj.ActiveGraph = n;
            data = cell(numel(g.Times),2);
            for k = 1:numel(g.Times)
                data{k,1} = g.Times(k);
                data{k,2} = obj.formatValue(g.Values(k));
            end
            obj.SampleTable.Data = data;
        end

        function mouseDown(obj)
            try
                ax = ancestor(obj.UIFigure.CurrentObject,'matlab.ui.control.UIAxes');
                if isempty(ax)
                    return;
                end
                n = obj.graphForAxes(ax);
                if n == 0
                    return;
                end
                t = obj.Graphs(n).Times;
                if isempty(t)
                    return;
                end
                x = ax.CurrentPoint(1,1);
                [~,i] = min(abs(t-x));
                if abs(t(i)-x) <= max((t(end)-t(1))*0.04,1e-9)
                    obj.DragGraph = n;
                    obj.setCursor(n,i);
                end
            catch
            end
        end

        function mouseMove(obj)
            n = obj.DragGraph;
            if n == 0
                return;
            end
            try
                ax = obj.Graphs(n).Axes;
                t = obj.Graphs(n).Times;
                if isempty(t)
                    return;
                end
                x = ax.CurrentPoint(1,1);
                [~,i] = min(abs(t-x));
                obj.setCursor(n,i);
            catch
            end
        end

        function mouseUp(obj)
            obj.DragGraph = 0;
        end

        function n = graphForAxes(obj,ax)
            n = 0;
            for k = 1:numel(obj.Graphs)
                try
                    if isequal(obj.Graphs(k).Axes,ax)
                        n = k;
                        return;
                    end
                catch
                end
            end
        end

        function showDiagnostics(obj)
            try
                obj.DiagnosticsArea.Value = obj.DiagnosticsManager.asCell();
            catch
            end
        end

        function handleError(obj,ME,stage)
            obj.DiagnosticsManager.recordException(ME,stage);
            obj.status(['ERROR | ' stage ' | ' ME.message]);
            obj.showDiagnostics();
        end

        function status(obj,t)
            try
                obj.StatusLabel.Text = char(string(t));
                drawnow limitrate;
            catch
            end
        end

        function s = optionalMessage(~,m)
            if isempty(m)
                s = '';
            else
                s = [' | ' char(string(m))];
            end
        end

        function s = formatValue(~,v)
            if isempty(v)
                s = '';
            elseif isscalar(v)
                s = sprintf('%.12g',double(v));
            else
                s = mat2str(v,8);
            end
        end
    end
end
