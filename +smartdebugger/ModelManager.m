classdef ModelManager < handle
    %MODELMANAGER Safe Simulink model loading and non-invasive block inspection.
    % IMPORTANT: inspection never compiles/updates the model. Compilation is
    % allowed only inside an explicit simulation run.
    properties (SetAccess=private)
        Model = ''
        Diagnostics
    end
    methods
        function obj = ModelManager(diag)
            obj.Diagnostics = diag;
        end
        function loadModel(obj,model)
            model=char(string(model));
            if isempty(strtrim(model)), error('SmartDebugger:EmptyModel','MIL model is empty.'); end
            [~,root,ext]=fileparts(model); if isempty(root), root=model; end
            try
                if bdIsLoaded(root), obj.Model=root; return; end
                if isempty(ext)
                    if exist([root '.slx'],'file')==2 || exist([root '.mdl'],'file')==2
                        load_system(root);
                    else
                        error('SmartDebugger:ModelNotFound','Model not found: %s',model);
                    end
                elseif exist(model,'file')==2
                    load_system(model);
                else
                    error('SmartDebugger:ModelNotFound','Model file not found: %s',model);
                end
                obj.Model=root;
            catch ME
                obj.Diagnostics.recordException(ME,'Load model'); rethrow(ME);
            end
        end
        function path=currentSimulinkSelection(obj)
            path='';
            try
                try, selected=get_param(0,'SelectedBlocks'); path=obj.firstSelection(selected); catch, end
                if isempty(path)
                    try, candidate=gcb; if ischar(candidate)&&~isempty(candidate), get_param(candidate,'Handle'); path=candidate; end; catch, end
                end
                if ~isempty(path), try, obj.Model=bdroot(path); catch, end; end
            catch ME
                obj.Diagnostics.recordException(ME,'Read selection');
            end
        end
        function info=inspectBlock(obj,path)
            info=[]; path=char(string(path));
            if isempty(strtrim(path)), return; end
            try
                get_param(path,'Handle'); root=bdroot(path);
                if ~bdIsLoaded(root), load_system(root); end
                obj.Model=root;
                info.Path=path; info.Name=get_param(path,'Name'); info.BlockType=get_param(path,'BlockType');
                info.Parent=get_param(path,'Parent'); info.LibraryLink=obj.safeGet(path,'ReferenceBlock',''); info.MaskType=obj.safeGet(path,'MaskType','');
                info.LinkStatus=obj.safeGet(path,'LinkStatus','');
                info.Inputs=obj.portInfo(path,'Inport'); info.Outputs=obj.portInfo(path,'Outport');
                info.IsStateflow=false; info.StateflowInfo=[];
                try
                    if smartdebugger.StateflowAdapter.isAvailable()
                        sfInfo=smartdebugger.StateflowAdapter.inspect(path);
                        if isfield(sfInfo,'Supported')&&sfInfo.Supported, info.IsStateflow=true; info.StateflowInfo=sfInfo; end
                    end
                catch
                end
            catch ME
                obj.Diagnostics.recordException(ME,'Inspect block');
            end
        end
        function ports=portInfo(obj,path,direction) %#ok<INUSD>
            % Keep the inspected-port schema identical to the runtime-port
            % schema used by SmartDebuggerApp. This prevents a later
            % subscripted structure assignment from changing the field set
            % after the struct array has been created.
            e=struct('Port',0,'Name','','LogName','','Value',[],'DataType','','Dimension','', ...
                'SampleTime','','Series',[],'LineHandle',-1,'SignalHandle',-1,'LoggingHandle',[]);
            ports=repmat(e,0,1);
            ph=get_param(path,'PortHandles');
            if strcmpi(direction,'Inport'), hs=ph.Inport; label='Input'; else, hs=ph.Outport; label='Output'; end
            for k=1:numel(hs)
                p=e; p.Port=k; p.Name=sprintf('%s %d',label,k); p.SignalHandle=hs(k);
                try, p.LineHandle=get_param(hs(k),'Line'); catch, p.LineHandle=-1; end
                if p.LineHandle~=-1
                    try, p.Name=smartdebugger.SignalNameResolver.resolve(p.LineHandle,k,label); catch, end
                end
                % Never compile here. Read compiled attributes only if the
                % model is already compiled by an external operation.
                try
                    dt=get_param(path,'CompiledPortDataTypes');
                    if isstruct(dt)
                        f=label; if isfield(dt,f), p.DataType=char(dt.(f){k}); end
                    end
                catch, end
                try
                    dm=get_param(path,'CompiledPortDimensions');
                    if isstruct(dm)
                        f=label; if isfield(dm,f), p.Dimension=mat2str(dm.(f)(k,:)); end
                    end
                catch, end
                try
                    st=get_param(path,'CompiledPortSampleTimes');
                    if isstruct(st)
                        f=label; if isfield(st,f), p.SampleTime=mat2str(st.(f)(k,:)); end
                    end
                catch, end
                ports(end+1,1)=p; %#ok<AGROW>
            end
        end
    end
    methods (Access=private)
        function v=safeGet(~,path,param,default)
            try, v=get_param(path,param); if isempty(v), v=default; end; catch, v=default; end
        end
        function path=firstSelection(~,selected)
            path='';
            if ischar(selected), if ~isempty(selected), path=selected; end
            elseif isstring(selected), if ~isempty(selected), path=char(selected(1)); end
            elseif iscell(selected), if ~isempty(selected)&&ischar(selected{1}), path=selected{1}; end
            end
        end
    end
end