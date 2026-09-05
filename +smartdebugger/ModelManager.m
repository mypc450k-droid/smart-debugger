classdef ModelManager < handle
    %MODELMANAGER Safe Simulink model loading, selection and block inspection.
    properties (SetAccess=private)
        Model = ''
        Diagnostics
    end
    methods
        function obj = ModelManager(diag)
            obj.Diagnostics = diag;
        end

        function loadModel(obj, model)
            model = char(string(model));
            if isempty(strtrim(model))
                error('SmartDebugger:EmptyModel','MIL model is empty.');
            end
            try
                [~, root, ext] = fileparts(model);
                if isempty(ext)
                    if ~bdIsLoaded(root)
                        if exist([root '.slx'],'file') || exist([root '.mdl'],'file')
                            load_system(root);
                        else
                            error('SmartDebugger:ModelNotFound','Model not found: %s',model);
                        end
                    end
                elseif exist(model,'file') == 2
                    load_system(model);
                else
                    error('SmartDebugger:ModelNotFound','Model file not found: %s',model);
                end
                obj.Model = root;
            catch ME
                obj.Diagnostics.recordException(ME,'Load model');
                rethrow(ME);
            end
        end

        function path = currentSimulinkSelection(obj)
            path = '';
            try
                if isempty(obj.Model) || ~bdIsLoaded(obj.Model)
                    return;
                end
                % SelectedBlocks is available at the Simulink root and is more
                % reliable than assuming gcs() is the selected subsystem.
                selected = find_system(obj.Model,'FindAll','on', ...
                    'Type','Block','Selected','on');
                if ~isempty(selected)
                    path = getfullname(selected(1));
                    return;
                end
                % Some releases expose the selected block through the root.
                try
                    selected = get_param(0,'SelectedBlocks');
                    if ischar(selected) && ~isempty(selected)
                        path = selected;
                    elseif iscell(selected) && ~isempty(selected)
                        path = char(selected{1});
                    end
                catch
                end
            catch ME
                obj.Diagnostics.recordException(ME,'Read selection');
            end
        end

        function info = inspectBlock(obj, path)
            info = [];
            path = char(string(path));
            if isempty(strtrim(path))
                return;
            end
            try
                root = bdroot(path);
                if ~bdIsLoaded(root)
                    load_system(root);
                end
                get_param(path,'Handle');
                set_param(root,'SimulationCommand','update');

                info.Path = path;
                info.Name = get_param(path,'Name');
                info.BlockType = get_param(path,'BlockType');
                info.Parent = get_param(path,'Parent');
                info.LibraryLink = get_param(path,'ReferenceBlock');
                info.MaskType = get_param(path,'MaskType');
                try, info.LinkStatus = get_param(path,'LinkStatus'); catch, info.LinkStatus=''; end
                try, info.Mask = get_param(path,'Mask'); catch, info.Mask=[]; end
                info.Inputs = obj.portInfo(path,'Inport');
                info.Outputs = obj.portInfo(path,'Outport');
            catch ME
                obj.Diagnostics.recordException(ME,'Inspect block');
            end
        end

        function ports = portInfo(obj,path,direction) %#ok<INUSD>
            emptyPort = struct('Port',0,'Name','','Value',[],'DataType','', ...
                'Dimension','','SampleTime','','SignalHandle',-1,'LineHandle',-1);
            ports = repmat(emptyPort,0,1);
            try
                ph = get_param(path,'PortHandles');
                if strcmpi(direction,'Inport')
                    hs = ph.Inport;
                    displayDirection = 'Input';
                else
                    hs = ph.Outport;
                    displayDirection = 'Output';
                end

                % Compiled attributes require a compiled diagram. Compile only
                % for metadata inspection and always terminate compilation.
                root = bdroot(path);
                compiled = false;
                try
                    feval(root,[],[],[],'compile');
                    compiled = true;
                catch
                    set_param(root,'SimulationCommand','update');
                end
                cleanup = onCleanup(@()localTerminate(root,compiled)); %#ok<NASGU>

                dt = []; dims = []; sts = [];
                try, dt = get_param(path,'CompiledPortDataTypes'); catch, end
                try, dims = get_param(path,'CompiledPortDimensions'); catch, end
                try, sts = get_param(path,'CompiledPortSampleTimes'); catch, end

                for k = 1:numel(hs)
                    p = emptyPort;
                    p.Port = k;
                    p.Name = sprintf('%s %d',displayDirection,k);
                    p.SignalHandle = hs(k);
                    try, p.LineHandle = get_param(hs(k),'Line'); catch, end
                    if p.LineHandle ~= -1
                        p.Name = smartdebugger.SignalNameResolver.resolve( ...
                            p.LineHandle,k,displayDirection);
                    end
                    try
                        if strcmpi(direction,'Inport') && isstruct(dt) && isfield(dt,'Inport')
                            p.DataType = char(dt.Inport{k});
                        elseif strcmpi(direction,'Outport') && isstruct(dt) && isfield(dt,'Outport')
                            p.DataType = char(dt.Outport{k});
                        end
                    catch
                    end
                    try
                        if strcmpi(direction,'Inport') && isstruct(dims) && isfield(dims,'Inport')
                            p.Dimension = mat2str(dims.Inport(k,:));
                        elseif strcmpi(direction,'Outport') && isstruct(dims) && isfield(dims,'Outport')
                            p.Dimension = mat2str(dims.Outport(k,:));
                        end
                    catch
                    end
                    try
                        if strcmpi(direction,'Inport') && isstruct(sts) && isfield(sts,'Inport')
                            p.SampleTime = mat2str(sts.Inport(k,:));
                        elseif strcmpi(direction,'Outport') && isstruct(sts) && isfield(sts,'Outport')
                            p.SampleTime = mat2str(sts.Outport(k,:));
                        end
                    catch
                    end
                    ports(end+1) = p; %#ok<AGROW>
                end
            catch ME
                obj.Diagnostics.recordException(ME,'Port inspection');
            end
        end
    end
end

function localTerminate(root,compiled)
if compiled
    try
        feval(root,[],[],[],'term');
    catch
    end
end
end
