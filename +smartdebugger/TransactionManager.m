classdef TransactionManager < handle
    %TRANSACTIONMANAGER Tracks model parameter changes and restores them.
    properties (Access=private)
        Changes = struct('Object',{},'Parameter',{},'Value',{});
        Active = true
    end
    methods
        function record(obj,object,param,value)
            obj.Changes(end+1)=struct('Object',object,'Parameter',param,'Value',value);
        end
        function restore(obj)
            if ~obj.Active, return; end
            for k=numel(obj.Changes):-1:1
                c=obj.Changes(k);
                try
                    set_param(c.Object,c.Parameter,c.Value);
                catch
                end
            end
            obj.Active=false;
        end
        function delete(obj), obj.restore(); end
    end
end
