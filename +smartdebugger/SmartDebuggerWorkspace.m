classdef SmartDebuggerWorkspace < handle
    %SMARTDEBUGGERWORKSPACE Owns the dedicated MIL and SIL windows.
    properties (SetAccess=private)
        MIL
        SIL
    end
    methods
        function obj=SmartDebuggerWorkspace(varargin)
            p=inputParser; addParameter(p,'Model','',@(x)ischar(x)||isstring(x)); parse(p,varargin{:});
            model=char(string(p.Results.Model));
            if isempty(strtrim(model)), model=smartdebugger.SmartDebuggerWorkspace.detectOpenModel(); end
            if isempty(strtrim(model))
                obj.MIL=smartdebugger.MILDebuggerWindow();
                obj.SIL=smartdebugger.SILDebuggerWindow();
            else
                obj.MIL=smartdebugger.MILDebuggerWindow('Model',model);
                obj.SIL=smartdebugger.SILDebuggerWindow('Model',model);
            end
        end
        function close(obj)
            try, if ~isempty(obj.MIL), obj.MIL.close(); end, catch, end
            try, if ~isempty(obj.SIL), obj.SIL.close(); end, catch, end
        end
    end
    methods (Static, Access=private)
        function m=detectOpenModel()
            m='';
            try, s=get_param(0,'CurrentSystem'); if ~isempty(s), m=bdroot(s); end, catch, end
            if isempty(m), try, s=gcs; if ~isempty(s), m=bdroot(s); end, catch, end, end
            if isempty(m), try, r=find_system(0,'SearchDepth',0,'Type','block_diagram'); if ~isempty(r), m=char(string(r{1})); end, catch, end, end
            if ~isempty(m), try, if ~bdIsLoaded(m), m=''; end, catch, end, end
        end
    end
end
