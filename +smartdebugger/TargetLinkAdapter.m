classdef TargetLinkAdapter < handle
    %TARGETLINKADAPTER TargetLink compatibility/capability boundary.
    %
    % Capability-driven TargetLink integration. No TargetLink release number
    % is hard-coded. MIL code is not touched by this adapter.

    methods (Static)
        function tf=isAvailable()
            c=smartdebugger.TargetLinkAdapter.discoverCapabilities();
            tf=c.TargetLinkDetected;
        end

        function info=inspect(block)
            c=smartdebugger.TargetLinkAdapter.discoverCapabilities();
            info=struct('Available',c.TargetLinkDetected,'Block',char(string(block)), ...
                'Capabilities',c,'Message','');
            if ~c.TargetLinkDetected
                info.Message='TargetLink was not detected. TargetLink-native SIL is unavailable.';
            else
                info.Message=sprintf('TargetLink detected. Native SIL=%d, host build=%d, simulation=%d, Data Server logging=%d.', ...
                    c.NativeSIL,c.BuildHost,c.Sim,c.AccessLogData);
            end
        end

        function c=discoverCapabilities()
            names={'tl_sim','tl_access_logdata','tl_set_sim_mode','tl_build_host', ...
                'tl_compile_host','tl_generate_code','tl_get','tl_set','tlds','tl_get_blocks'};
            c=struct();
            for k=1:numel(names)
                c.(localField(names{k}))=~isempty(which(names{k}));
            end
            c.TargetLinkDetected=any([c.tl_sim c.tl_access_logdata c.tl_set_sim_mode ...
                c.tl_build_host c.tl_compile_host c.tl_generate_code c.tl_get c.tl_set c.tlds]);
            c.NativeSIL=c.tl_sim && (c.tl_set_sim_mode || c.tl_build_host || c.tl_compile_host);
            c.Sim=c.tl_sim;
            c.AccessLogData=c.tl_access_logdata;
            c.TLDS=c.tlds;
            c.SetSimMode=c.tl_set_sim_mode;
            c.BuildHost=c.tl_build_host;
            c.CompileHost=c.tl_compile_host;
            c.GenerateCode=c.tl_generate_code;
            c.TLGet=c.tl_get;
            c.TLSet=c.tl_set;
            c.TLGetBlocks=c.tl_get_blocks;
            c.Version=localVersion();
            c.CheckedAt=datestr(now,31);
        end

        function report=inspectEnvironment()
            c=smartdebugger.TargetLinkAdapter.discoverCapabilities();
            report=struct('TargetLinkDetected',c.TargetLinkDetected, ...
                'Version',c.Version,'Capabilities',c,'Message','');
            if c.TargetLinkDetected
                report.Message='TargetLink API capability scan completed without invoking any TargetLink operation.';
            else
                report.Message='No TargetLink MATLAB API entry point was detected.';
            end
        end

        function [resolved,info]=resolveSubsystem(model,requested)
            % Resolve a TargetLink subsystem to the identifier expected by the
            % TargetLink automation API. TargetLink accepts a subsystem name,
            % while Data Server and Simulink commonly expose a full hierarchy.
            model=char(string(model));
            requested=char(string(requested));
            resolved='';
            info=struct('Requested',requested,'Resolved','', ...
                'Method','NONE','Confidence','NONE','Candidates',{{}},'Message','');

            if isempty(strtrim(requested))
                info.Message='No TargetLink subsystem was supplied.';
                return
            end

            mdl=localModelName(model);
            if ~bdIsLoaded(mdl)
                try, load_system(mdl); catch, end
            end

            % If the caller already supplied a simple TargetLink subsystem name,
            % keep it. Do not require the subsystem to be a Simulink block path.
            if ~contains(requested,'/') && ~contains(requested,'\\')
                resolved=requested;
                info.Resolved=resolved;
                info.Method='USER_OR_NAME';
                info.Confidence='HIGH';
                info.Message='Using the supplied TargetLink subsystem name.';
                return
            end

            % Walk from the selected/deep path upward. The nearest ancestor for
            % which tl_get accepts BlockDataStruct is the strongest TargetLink
            % object-level match and yields its local block name.
            candidates=localAncestorPaths(requested);
            info.Candidates=candidates;
            for k=1:numel(candidates)
                p=candidates{k};
                try
                    h=get_param(p,'Handle');
                catch
                    continue
                end
                if localIsTargetLinkObject(h)
                    try
                        nm=get_param(p,'Name');
                    catch
                        nm='';
                    end
                    if ~isempty(nm)
                        resolved=char(string(nm));
                        info.Resolved=resolved;
                        info.Method='TL_GET_ANCESTOR_NAME';
                        info.Confidence='HIGH';
                        info.Message=['Resolved full Simulink path to TargetLink subsystem name: ' resolved];
                        return
                    end
                end
            end

            % A second, read-only discovery pass uses the installed TargetLink
            % block enumerator. This is important for releases where tl_get does
            % not expose BlockDataStruct on the software-unit subsystem itself.
            if ~isempty(which('tl_get_blocks'))
                try
                    hmdl=get_param(mdl,'Handle');
                    [hlist,types]=feval('tl_get_blocks',hmdl,'AllInclSubsystems');
                    for k=1:numel(hlist)
                        try
                            full=getfullname(hlist(k));
                        catch
                            continue
                        end
                        if localPathIsAncestorOrEqual(full,requested)
                            try, nm=get_param(hlist(k),'Name'); catch, nm=''; end
                            if ~isempty(nm) && localLooksLikeTLType(types,k)
                                resolved=char(string(nm));
                                info.Resolved=resolved;
                                info.Method='TL_GET_BLOCKS_ANCESTOR';
                                info.Confidence='HIGH';
                                info.Message=['Resolved TargetLink hierarchy using tl_get_blocks: ' resolved];
                                return
                            end
                        end
                    end
                catch ME
                    info.Message=['tl_get_blocks discovery failed: ' ME.message];
                end
            end

            % Last-resort path handling: if the requested block exists, use its
            % local name only when it is itself a subsystem. This keeps the API
            % call compatible with TargetLink's name-based TlSubsystems option.
            try
                h=get_param(requested,'Handle');
                bt=get_param(h,'BlockType');
                if strcmpi(bt,'SubSystem')
                    nm=get_param(h,'Name');
                    resolved=char(string(nm));
                    info.Resolved=resolved;
                    info.Method='SUBSYSTEM_NAME';
                    info.Confidence='MEDIUM';
                    info.Message='Using the selected Simulink subsystem name as TargetLink TlSubsystems identifier.';
                    return
                end
            catch
            end

            info.Message='Could not resolve a TargetLink subsystem name from the supplied path. Select the TargetLink software-unit subsystem or enter its local TargetLink subsystem name.';
        end

        function setSimulationMode(model,subsystem,mode)
            if isempty(which('tl_set_sim_mode')), return; end
            model=localModelName(model);
            feval('tl_set_sim_mode','Model',model,'TlSubsystems',subsystem,'SimMode',mode);
        end

        function generateCode(model,subsystem)
            if isempty(which('tl_generate_code'))
                return
            end
            model=localModelName(model);
            feval('tl_generate_code','Model',model,'TlSubsystems',subsystem);
        end

        function buildHost(model,subsystem)
            model=localModelName(model);
            if ~isempty(which('tl_build_host'))
                feval('tl_build_host','Model',model,'TlSubsystems',subsystem);
            elseif ~isempty(which('tl_compile_host'))
                feval('tl_compile_host','Model',model,'TlSubsystems',subsystem);
            else
                error('SmartDebugger:TargetLinkHostBuildUnavailable', ...
                    'No TargetLink host-build API is available.');
            end
        end

        function compileHost(model,subsystem)
            if isempty(which('tl_compile_host'))
                error('SmartDebugger:TargetLinkHostCompileUnavailable', ...
                    'TargetLink tl_compile_host is not available.');
            end
            model=localModelName(model);
            feval('tl_compile_host','Model',model,'TlSubsystems',subsystem);
        end

        function message=simulate(model,subsystem)
            if isempty(which('tl_sim'))
                error('SmartDebugger:TargetLinkSimulationUnavailable', ...
                    'TargetLink tl_sim is not available.');
            end
            model=localModelName(model);
            % tl_sim is an action-style TargetLink command in supported releases
            % and must not be called with an output argument.
            feval('tl_sim','Model',model,'TlSubsystems',subsystem);
            message='TargetLink SIL simulation completed.';
        end

        function [data,ok,message,method]=accessLogData(model,subsystem)
            %#ok<INUSD>
            data=[]; ok=false; message=''; method='';
            if isempty(which('tl_access_logdata')) && isempty(which('tlds'))
                message='No TargetLink Data Server access function is available.';
                return
            end

            if ~isempty(which('tlds'))
                try
                    simulations=feval('tlds',0,'get','simulations');
                    if isempty(simulations)
                        message='TargetLink Data Server contains no stored simulations.';
                        return
                    end
                    label=localLatestSimulationLabel(simulations);
                    if isempty(label)
                        message='TargetLink returned simulations, but no simulation label could be resolved.';
                        return
                    end
                    tmp=[tempname '.mat'];
                    cleanup=onCleanup(@() localDelete(tmp)); %#ok<NASGU>
                    feval('tlds',label,'save',tmp);
                    loaded=load(tmp);
                    data=localExtractSavedPayload(loaded);
                    if isempty(data)
                        message='TargetLink saved the simulation, but no usable logging payload was found.';
                        return
                    end
                    ok=true;
                    method='TLDS_READ_SAVE';
                    message=sprintf('Read latest TargetLink simulation "%s" from the TargetLink Data Server.',label);
                    return
                catch ME
                    message=['TargetLink TLDS extraction failed: ' ME.message];
                end
            end

            if ~isempty(which('tl_access_logdata'))
                if isempty(message)
                    message='tl_access_logdata is installed, but its release-specific action signature is not invoked by Smart Debugger.';
                else
                    message=[message ' tl_access_logdata is also installed, but its release-specific action signature was not guessed.'];
                end
            end
        end
    end
end

function f=localField(name)
f=matlab.lang.makeValidName(name);
end

function v=localVersion()
v='unknown';
try
    x=ver('TargetLink');
    if ~isempty(x)
        if isfield(x,'Version'), v=x.Version; end
        if isfield(x,'Release') && ~isempty(x.Release), v=[v ' ' x.Release]; end
    end
catch
end
end

function name=localModelName(model)
model=char(string(model));
[~,name,ext]=fileparts(model);
if isempty(ext), name=model; end
end

function paths=localAncestorPaths(path)
parts=regexp(char(string(path)),'/','split');
paths={};
for k=numel(parts):-1:1
    if k==1
        p=parts{1};
    else
        p=strjoin(parts(1:k),'/');
    end
    paths{end+1}=p; %#ok<AGROW>
end
end

function tf=localIsTargetLinkObject(h)
tf=false;
if isempty(which('tl_get')), return; end
try
    d=feval('tl_get',h,'BlockDataStruct');
    tf=isstruct(d) && ~isempty(fieldnames(d));
catch
    tf=false;
end
end

function tf=localPathIsAncestorOrEqual(candidate,requested)
candidate=char(string(candidate));
requested=char(string(requested));
tf=strcmp(candidate,requested) || startsWith([requested '/'],[candidate '/']);
end

function tf=localLooksLikeTLType(types,k)
tf=true;
try
    t=char(string(types{k}));
    tl=lower(t);
    tf=contains(tl,'targetlink') || contains(tl,'tl_') || contains(tl,'tlsim') || contains(tl,'subsystem');
catch
end
end

function label=localLatestSimulationLabel(simulations)
label='';
if iscell(simulations)
    if isempty(simulations), return; end
    item=simulations{end};
else
    item=simulations(end);
end
if isstruct(item)
    candidates={'label','Label','name','Name'};
    for k=1:numel(candidates)
        if isfield(item,candidates{k}) && ~isempty(item.(candidates{k}))
            label=char(string(item.(candidates{k})));
            return
        end
    end
elseif ischar(item) || isstring(item)
    label=char(string(item));
end
end

function data=localExtractSavedPayload(loaded)
data=loaded;
fields=fieldnames(loaded);
if numel(fields)==1
    candidate=loaded.(fields{1});
    if isstruct(candidate) || istable(candidate) || istimetable(candidate) || isa(candidate,'timeseries')
        data=candidate;
    end
end
end

function localDelete(file)
if exist(file,'file')==2
    try, delete(file); catch, end
end
end
