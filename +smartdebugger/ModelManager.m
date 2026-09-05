classdef ModelManager < handle
    properties (SetAccess=private)
        Model = ''
        Diagnostics
    end
    methods
        function obj=ModelManager(diag)
            obj.Diagnostics=diag;
        end
        function loadModel(obj,model)
            model=char(model);
            if isempty(model), error('SmartDebugger:EmptyModel','Model is empty.'); end
            [~,name,ext]=fileparts(model);
            if isempty(ext), name= model; else, name=[name ext]; end
            try
                if exist(model,'file')==2 || bdIsLoaded(erase(name,{'.slx','.mdl'}))
                    load_system(model);
                else
                    error('SmartDebugger:ModelNotFound','Model file not found: %s',model);
                end
                [~,n,~]=fileparts(model); obj.Model=n;
            catch ME
                obj.Diagnostics.recordException(ME,'Load model'); rethrow(ME);
            end
        end
        function path=currentSimulinkSelection(obj)
            path='';
            try
                if isempty(obj.Model), return; end
                sel=get_param(obj.Model,'CurrentSystem'); %#ok<NASGU>
                h=gcs;
                if isempty(h), return; end
                b=find_system(h,'SearchDepth',1,'Selected','on');
                if isempty(b)
                    try
                        b=get_param(obj.Model,'SelectedBlocks');
                    catch
                        b={};
                    end
                end
                if ~isempty(b), path=char(b{1}); end
            catch ME
                obj.Diagnostics.recordException(ME,'Read selection');
            end
        end
        function info=inspectBlock(obj,path)
            info=[];
            try
                if isempty(path), return; end
                if ~bdIsLoaded(bdroot(path)), load_system(bdroot(path)); end
                get_param(path,'Handle');
                info.Path=path;
                info.Name=get_param(path,'Name');
                info.BlockType=get_param(path,'BlockType');
                info.Parent=get_param(path,'Parent');
                info.LibraryLink=get_param(path,'ReferenceBlock');
                info.MaskType=get_param(path,'MaskType');
                info.Inputs=obj.portInfo(path,'Inport');
                info.Outputs=obj.portInfo(path,'Outport');
            catch ME
                obj.Diagnostics.recordException(ME,'Inspect block');
            end
        end
        function ports=portInfo(obj,path,direction) %#ok<INUSD>
            ports=repmat(struct('Port',0,'Name','','Value','','DataType','','Dimension','','SampleTime',''),0,1);
            try
                ph=get_param(path,'PortHandles');
                if strcmp(direction,'Inport'), hs=ph.Inport; else, hs=ph.Outport; end
                for k=1:numel(hs)
                    p=struct('Port',k,'Name','','Value','','DataType','','Dimension','','SampleTime','');
                    try
                        line=get_param(hs(k),'Line');
                        if line~=-1
                            nm=get_param(line,'Name');
                            if isempty(nm), nm=sprintf('%s %d',direction,k); end
                        else
                            nm=sprintf('%s %d',direction,k);
                        end
                    catch
                        nm=sprintf('%s %d',direction,k);
                    end
                    p.Name=nm;
                    try
                        dt=get_param(hs(k),'CompiledPortDataType'); if isempty(dt), dt=''; end
                    catch, dt=''; end
                    try
                        dim=get_param(hs(k),'CompiledPortDimensions');
                        if isnumeric(dim), dim=mat2str(dim); end
                    catch, dim=''; end
                    try
                        st=get_param(hs(k),'CompiledPortSampleTime');
                        if isnumeric(st), st=mat2str(st); end
                    catch, st=''; end
                    p.DataType=char(dt); p.Dimension=char(dim); p.SampleTime=char(st);
                    ports(end+1)=p; %#ok<AGROW>
                end
            catch ME
                obj.Diagnostics.recordException(ME,'Port inspection');
            end
        end
    end
end
