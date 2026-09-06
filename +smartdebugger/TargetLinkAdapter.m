classdef TargetLinkAdapter < handle
    %TARGETLINKADAPTER TargetLink compatibility/capability boundary.
    %
    % No TargetLink release number is hard-coded. The adapter discovers the
    % APIs exposed by the installed TargetLink release and only uses APIs that
    % are actually present. This keeps TargetLink 24.1p2 as a supported
    % baseline while allowing newer releases to evolve independently.

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
            persistent cache
            if isempty(cache)
                names={'tl_sim','tl_access_logdata','tl_set_sim_mode','tl_build_host', ...
                    'tl_compile_host','tl_generate_code','tl_get','tl_set'};
                c=struct();
                for k=1:numel(names)
                    c.(localField(names{k}))=~isempty(which(names{k}));
                end
                c.TargetLinkDetected=any(struct2array(c));
                c.NativeSIL=c.tl_sim && (c.tl_set_sim_mode || c.tl_build_host || c.tl_compile_host);
                c.Sim=c.tl_sim;
                c.AccessLogData=c.tl_access_logdata;
                c.SetSimMode=c.tl_set_sim_mode;
                c.BuildHost=c.tl_build_host;
                c.CompileHost=c.tl_compile_host;
                c.GenerateCode=c.tl_generate_code;
                c.TLGet=c.tl_get;
                c.TLSet=c.tl_set;
                c.Version=localVersion();
                c.CheckedAt=datestr(now,31);
                cache=c;
            end
            c=cache;
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
            if isempty(which('tl_set_sim_mode'))
                return
            end
            feval('tl_set_sim_mode','Model',model,'TlSubsystems',subsystem,'SimMode',mode);
        end

        function buildHost(model,subsystem)
            if ~isempty(which('tl_build_host'))
                feval('tl_build_host','Model',model,'TlSubsystems',subsystem);
            elseif ~isempty(which('tl_compile_host'))
                feval('tl_compile_host','Model',model,'TlSubsystems',subsystem);
            else
                error('SmartDebugger:TargetLinkHostBuildUnavailable','No TargetLink host-build API is available.');
            end
        end

        function message=simulate(model,subsystem)
            if isempty(which('tl_sim'))
                error('SmartDebugger:TargetLinkSimulationUnavailable','TargetLink tl_sim is not available.');
            end
            % The Model/TlSubsystems name-value form is the documented
            % TargetLink automation pattern. If a future release changes it,
            % the adapter will fail here with the native TargetLink message,
            % rather than silently running the wrong engine.
            out=feval('tl_sim','Model',model,'TlSubsystems',subsystem);
            message='TargetLink SIL simulation completed.';
            if ischar(out) || isstring(out)
                message=char(string(out));
            end
        end

        function [data,ok,message]=accessLogData(model,subsystem)
            data=[]; ok=false; message=''; %#ok<INUSD>
            if isempty(which('tl_access_logdata'))
                message='tl_access_logdata is not installed.';
                return
            end
            % Deliberately do not guess a private command/action signature.
            % The API is release-specific in its Data Server access syntax.
            % The manager exposes this boundary so the exact installed API can
            % be wired in later without changing MIL or the UI.
            message=['TargetLink Data Server API detected, but its action signature is intentionally not guessed. ' ...
                'Native SIL execution is available; automatic internal-log extraction remains gated until the installed API contract is verified.'];
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
