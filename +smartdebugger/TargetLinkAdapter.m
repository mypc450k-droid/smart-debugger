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
                'tl_compile_host','tl_generate_code','tl_get','tl_set','tlds'};
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

        function setSimulationMode(model,subsystem,mode)
            if isempty(which('tl_set_sim_mode')), return; end
            feval('tl_set_sim_mode','Model',model,'TlSubsystems',subsystem,'SimMode',mode);
        end

        function generateCode(model,subsystem)
            if isempty(which('tl_generate_code'))
                return
            end
            % TargetLink automation uses property/value arguments. Keep the
            % call isolated so a future TargetLink signature can be adapted here.
            feval('tl_generate_code','Model',model,'TlSubsystems',subsystem);
        end

        function buildHost(model,subsystem)
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
            feval('tl_compile_host','Model',model,'TlSubsystems',subsystem);
        end

        function message=simulate(model,subsystem)
            if isempty(which('tl_sim'))
                error('SmartDebugger:TargetLinkSimulationUnavailable', ...
                    'TargetLink tl_sim is not available.');
            end
            out=feval('tl_sim','Model',model,'TlSubsystems',subsystem);
            message='TargetLink SIL simulation completed.';
            if ischar(out) || isstring(out)
                message=char(string(out));
            end
        end

        function [data,ok,message,method]=accessLogData(model,subsystem)
            % Read the latest TargetLink Data Server simulation.
            %
            % dSPACE documents tl_access_logdata as the M-API for Data Server
            % access. Its exact action signature is release-specific and is not
            % exposed by the public material available to this project, so we do
            % not invent one. If the installed release exposes the TLDS MATLAB
            % bridge, its documented read/save sequence is used as a safe,
            % read-only extraction fallback.
            data=[]; ok=false; message=''; method=''; %#ok<INUSD>
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
