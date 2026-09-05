classdef StateflowAdapter
    methods (Static)
        function tf=isAvailable(), tf=exist('sfroot','file')==2; end
        function info=inspect(path)
            info=struct('Supported',false,'Path',path,'Name','','Type','','Message','');
            if ~smartdebugger.StateflowAdapter.isAvailable()
                info.Message='Stateflow is not available in this MATLAB installation.'; return
            end
            try
                rt=sfroot;
                obj=rt.find('-isa','Stateflow.Object','Path',char(path));
                if isempty(obj)
                    info.Message='Stateflow object not found.'; return
                end
                if numel(obj)>1, obj=obj(1); end
                info.Supported=true; info.Name=char(obj.Name); info.Type=class(obj);
            catch ME
                info.Message=ME.message;
            end
        end
    end
end
