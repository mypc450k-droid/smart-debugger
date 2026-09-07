classdef SILDebuggerWindow < handle
    %SILDEBUGGERWINDOW Dedicated SIL presentation around the existing app.
    % The established SmartDebuggerApp SIL execution path is reused as-is.

    properties (SetAccess=private)
        App
        UIFigure
    end
    methods
        function obj=SILDebuggerWindow(varargin)
            obj.App=smartdebugger.SmartDebuggerApp();
            obj.UIFigure=obj.App.UIFigure;
            obj.UIFigure.Name='Smart Debugger | SIL Debugger';
            obj.UIFigure.Position=[80 60 1550 920];
            obj.hideModelPickersAndSelectSIL();
            obj.autoDetectModel();
            if ~isempty(varargin), obj.configure(varargin{:}); end
        end
        function configure(obj,varargin)
            p=inputParser; addParameter(p,'Model','',@(x)ischar(x)||isstring(x)); parse(p,varargin{:});
            m=char(string(p.Results.Model)); if ~isempty(strtrim(m)), obj.setModel(m); end
        end
        function setModel(obj,model)
            try
                obj.App.setMILModel(char(string(model)));
                obj.App.setSILModel(char(string(model)));
                obj.selectSILMode();
            catch ME
                warning('SmartDebugger:SILModelDetection','SIL model detection failed: %s',ME.message);
            end
        end
        function close(obj)
            try, if ~isempty(obj.App), obj.App.closeApp(); end, catch, end
        end
    end
    methods (Access=private)
        function hideModelPickersAndSelectSIL(obj)
            b=findobj(obj.UIFigure,'Type','uibutton');
            for k=1:numel(b)
                try
                    t=char(string(b(k).Text));
                    if strcmpi(t,'Open MIL')||strcmpi(t,'Open SIL'), b(k).Visible='off'; end
                catch, end
            end
            f=findobj(obj.UIFigure,'Type','uieditfield');
            for k=1:numel(f)
                try
                    ph=lower(char(string(f(k).Placeholder)));
                    if contains(ph,'mil model')||contains(ph,'sil model'), f(k).Visible='off'; end
                catch, end
            end
            obj.selectSILMode();
        end
        function selectSILMode(obj)
            d=findobj(obj.UIFigure,'Type','uidropdown');
            for k=1:numel(d)
                try
                    items=cellstr(d(k).Items);
                    if any(strcmpi(items,'MIL'))&&any(strcmpi(items,'SIL'))
                        d(k).Value='SIL';
                        cb=d(k).ValueChangedFcn;
                        if ~isempty(cb), try, feval(cb,d(k),[]); catch, end, end
                        d(k).Visible='off';
                    end
                catch, end
            end
        end
        function autoDetectModel(obj)
            m=obj.detectOpenModel(); if ~isempty(m), obj.setModel(m); end
        end
        function m=detectOpenModel(~)
            m='';
            try, s=get_param(0,'CurrentSystem'); if ~isempty(s), m=bdroot(s); end, catch, end
            if isempty(m), try, s=gcs; if ~isempty(s), m=bdroot(s); end, catch, end, end
            if isempty(m), try, r=find_system(0,'SearchDepth',0,'Type','block_diagram'); if ~isempty(r), m=char(string(r{1})); end, catch, end, end
            if ~isempty(m), try, if ~bdIsLoaded(m), m=''; end, catch, end, end
        end
    end
end
