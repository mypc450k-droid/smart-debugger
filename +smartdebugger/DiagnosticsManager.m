classdef DiagnosticsManager < handle
    %DIAGNOSTICSMANAGER Central diagnostic log for the Smart Debugger.
    properties (Access=private)
        Entries = struct('Time',{},'Severity',{},'Stage',{},'Message',{},'Identifier',{},'Stack',{})
    end
    methods
        function record(obj,severity,stage,message,identifier,stackText)
            if nargin<5, identifier=''; end
            if nargin<6, stackText=''; end
            obj.Entries(end+1)=struct('Time',datetime('now'), ...
                'Severity',char(severity),'Stage',char(stage), ...
                'Message',char(message),'Identifier',char(identifier), ...
                'Stack',char(stackText));
        end
        function recordException(obj,ME,stage)
            stackText='';
            try
                if ~isempty(ME.stack)
                    s=ME.stack(1);
                    stackText=sprintf('%s:%d',s.name,s.line);
                    if numel(ME.stack)>1
                        s2=ME.stack(2);
                        stackText=[stackText ' <- ' s2.name ':' num2str(s2.line)];
                    end
                end
            catch
            end
            obj.record('ERROR',stage,ME.message,ME.identifier,stackText);
        end
        function c=asCell(obj)
            if isempty(obj.Entries), c={'No diagnostics.'}; return; end
            c=cell(numel(obj.Entries),1);
            for k=1:numel(obj.Entries)
                e=obj.Entries(k);
                if isempty(e.Stack)
                    c{k}=sprintf('[%s] %s | %s | %s',e.Severity,e.Stage,e.Message,e.Identifier);
                else
                    c{k}=sprintf('[%s] %s | %s | %s | at %s',e.Severity,e.Stage,e.Message,e.Identifier,e.Stack);
                end
            end
        end
        function entries=getAll(obj), entries=obj.Entries; end
        function clear(obj)
            obj.Entries=struct('Time',{},'Severity',{},'Stage',{},'Message',{},'Identifier',{},'Stack',{});
        end
    end
end
