classdef DiagnosticsManager < handle
    properties (Access=private)
        Entries = struct('Time',{},'Severity',{},'Stage',{},'Message',{},'Identifier',{})
    end
    methods
        function record(obj,severity,stage,message,identifier)
            if nargin<5, identifier=''; end
            obj.Entries(end+1)=struct('Time',datetime('now'),'Severity',char(severity),'Stage',char(stage),'Message',char(message),'Identifier',char(identifier));
        end
        function recordException(obj,ME,stage)
            obj.record('ERROR',stage,ME.message,ME.identifier);
        end
        function c=asCell(obj)
            if isempty(obj.Entries), c={'No diagnostics.'}; return; end
            c=cell(numel(obj.Entries),1);
            for k=1:numel(obj.Entries)
                e=obj.Entries(k); c{k}=sprintf('[%s] %s | %s | %s',e.Severity,e.Stage,e.Message,e.Identifier);
            end
        end
        function entries=getAll(obj), entries=obj.Entries; end
        function clear(obj), obj.Entries=struct('Time',{},'Severity',{},'Stage',{},'Message',{},'Identifier',{}); end
    end
end
