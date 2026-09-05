classdef ModelManager < handle
    properties (SetAccess=private)
        Model = ''
        Diagnostics
    end
    methods
        function obj=ModelManager(diag), obj.Diagnostics=diag; end
        function loadModel(obj,model)
            model=char(model);
            if isempty(model), error('SmartDebugger:EmptyModel','Model is empty.'); end
            try
                [~,n,ext]=fileparts(model); root=n;
                if isempty(ext) && ~bdIsLoaded(root), load_system(root); elseif exist(model,'file')==2, load_system(model); elseif ~bdIsLoaded(root), error('SmartDebugger:ModelNotFound','Model file not found: %s',model); end
                obj.Model=root;
            catch ME
                obj.Diagnostics.recordException(ME,'Load model'); rethrow(ME);
            end
        end
        function path=currentSimulinkSelection(obj)
            path='';
            try
                if isempty(obj.Model), return; end
                b=get_param(0,'SelectedBlocks');
                if ischar(b) && ~isempty(b), path=b; elseif iscell(b) && ~isempty(b), path=char(b{1}); end
                if isempty(path)
                    cb=get_param(0,'CurrentBlock');
                    if ischar(cb), path=cb; end
                end
            catch ME
                obj.Diagnostics.recordException(ME,'Read selection');
            end
        end
        function info=inspectBlock(obj,path)
            info=[];
            try
                if isempty(path), return; end
                root=bdroot(path); if ~bdIsLoaded(root), load_system(root); end
                get_param(path,'Handle');
                set_param(root,'SimulationCommand','update');
                info.Path=path; info.Name=get_param(path,'Name'); info.BlockType=get_param(path,'BlockType');
                info.Parent=get_param(path,'Parent'); info.LibraryLink=get_param(path,'ReferenceBlock'); info.MaskType=get_param(path,'MaskType');
                info.Inputs=obj.portInfo(path,'Inport'); info.Outputs=obj.portInfo(path,'Outport');
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
                    line=get_param(hs(k),'Line');
                    if isempty(line) || isequal(line,-1), p.Name=sprintf('%s %d',direction,k); else, p.Name=smartdebugger.SignalNameResolver.resolve(line,k,direction); end
                    try
                        if strcmp(direction,'Inport'), d=get_param(path,'CompiledPortDataTypes'); dim=get_param(path,'CompiledPortDimensions'); st=get_param(path,'CompiledPortSampleTimes');
                        else, d=get_param(path,'CompiledPortDataTypes'); dim=get_param(path,'CompiledPortDimensions'); st=get_param(path,'CompiledPortSampleTimes'); end
                        idx=k;
                        if strcmp(direction,'Inport') && isfield(d,'Inport'), p.DataType=char(d.Inport{idx}); p.Dimension=mat2str(dim.Inport(idx,:)); p.SampleTime=mat2str(st.Inport(idx,:));
                        elseif strcmp(direction,'Outport') && isfield(d,'Outport'), p.DataType=char(d.Outport{idx}); p.Dimension=mat2str(dim.Outport(idx,:)); p.SampleTime=mat2str(st.Outport(idx,:)); end
                    catch
                        % Compiled metadata is release-dependent; leave fields blank rather than guess.
                    end
                    ports(end+1)=p; %#ok<AGROW>
                end
            catch ME
                obj.Diagnostics.recordException(ME,'Port inspection');
            end
        end
    end
end
