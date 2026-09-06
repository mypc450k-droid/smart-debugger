function result=runTargetLinkSIL(model,subsystem,stopTime)
%RUNTARGETLINKSIL Run TargetLink production-code SIL and extract Data Server data.
if nargin<1 || isempty(model), error('SmartDebugger:TargetLinkModelRequired','TargetLink model/frame is required.'); end
if nargin<2 || isempty(subsystem), error('SmartDebugger:TargetLinkSubsystemRequired','TargetLink subsystem/block path or name is required.'); end
if nargin<3, stopTime='auto'; end
mdl=localModelName(model);
if ~bdIsLoaded(mdl), load_system(mdl); end
open_system(mdl);
requested=char(string(subsystem));
[resolved,info]=localResolveTargetLinkSubsystem(mdl,requested);
if isempty(resolved), error('SmartDebugger:TargetLinkSILMappingFailed','%s',info.Message); end
manager=smartdebugger.TargetLinkSILManager();
result=manager.run(model,resolved,stopTime);
result.Subsystem=requested;
result.ResolvedSubsystem=resolved;
result.MappingMethod=info.Method;
result.MappingConfidence=info.Confidence;
result.MappingCandidates=info.Candidates;
fprintf('\n=== Smart Debugger TargetLink SIL ===\n');
fprintf('Status             : %s\n',result.Status);
fprintf('Model              : %s\n',result.Model);
fprintf('Requested target   : %s\n',result.Subsystem);
fprintf('Resolved TL target : %s\n',result.ResolvedSubsystem);
fprintf('Resolution         : %s / %s\n',result.MappingMethod,result.MappingConfidence);
fprintf('Data source        : %s\n',result.DataSource);
fprintf('Data access        : %s\n',result.DataAccessMethod);
fprintf('Signal count       : %d\n',result.SignalCount);
fprintf('Message            : %s\n',result.Message);
if ~isempty(result.RuntimeSignals)
    fprintf('\nRuntime signals:\n');
    for k=1:numel(result.RuntimeSignals)
        r=result.RuntimeSignals(k);
        fprintf('  %3d  %-55s  samples=%d  type=%s\n',k,r.Name,numel(r.Time),r.DataType);
    end
end
if strcmpi(result.Status,'ERROR')
    error('SmartDebugger:TargetLinkSILFailed','TargetLink SIL failed: %s',result.Message);
end
end

function [resolved,info]=localResolveTargetLinkSubsystem(model,requested)
resolved='';
info=struct('Requested',requested,'Resolved','','Method','NONE','Confidence','NONE','Candidates',{{}},'Message','');
if isempty(which('tl_get_blocks'))
    info.Message='tl_get_blocks is unavailable; Smart Debugger will not guess the TargetLink subsystem.';
    return
end
requested=char(string(requested));
model=char(string(model));
if ~contains(requested,'/')
    resolved=requested;
    info.Resolved=resolved;
    info.Method='USER_OR_NAME';
    info.Confidence='HIGH';
    info.Message='Using the supplied local TargetLink subsystem name.';
    return
end
paths=localAncestorPaths(requested);
info.Candidates=paths;
% Deepest-first. Never accept the model root. A candidate must be a real
% Simulink SubSystem containing genuine TargetLink blocks.
for k=1:numel(paths)
    p=paths{k};
    if strcmpi(p,model), continue; end
    try
        h=get_param(p,'Handle');
        if ~strcmpi(get_param(h,'BlockType'),'SubSystem'), continue; end
        [hTL,~]=feval('tl_get_blocks',h,'TargetLink');
        if isempty(hTL), continue; end
        nm=get_param(h,'Name');
        if isempty(nm), continue; end
        resolved=char(string(nm));
        info.Resolved=resolved;
        info.Method='TL_GET_BLOCKS_ANCESTOR';
        info.Confidence='HIGH';
        info.Message=['Resolved deepest validated TargetLink subsystem: ' resolved];
        return
    catch
    end
end
% Fallback for releases where direct subtree enumeration behaves differently.
try
    hmdl=get_param(model,'Handle');
    [hlist,~]=feval('tl_get_blocks',hmdl,'AllInclSubsystems');
    valid={};
    for k=1:numel(hlist)
        h=hlist(k);
        try
            full=getfullname(h);
            if strcmpi(full,model), continue; end
            if ~localIsAncestor(full,requested), continue; end
            if ~strcmpi(get_param(h,'BlockType'),'SubSystem'), continue; end
            [hTL,~]=feval('tl_get_blocks',h,'TargetLink');
            if isempty(hTL), continue; end
            valid{end+1}=full; %#ok<AGROW>
        catch
        end
    end
    if ~isempty(valid)
        [~,ix]=max(cellfun(@numel,valid));
        chosen=valid{ix};
        resolved=char(string(get_param(chosen,'Name')));
        info.Resolved=resolved;
        info.Method='TL_GET_BLOCKS_DEEPEST';
        info.Confidence='HIGH';
        info.Candidates=[info.Candidates valid];
        info.Message=['Resolved deepest TargetLink-containing subsystem: ' resolved];
        return
    end
catch ME
    info.Message=['TargetLink subsystem discovery failed: ' ME.message];
end
info.Message=['Could not resolve a validated TargetLink subsystem from: ' requested];
end

function paths=localAncestorPaths(path)
parts=regexp(char(string(path)),'/','split');
paths={};
for k=numel(parts):-1:1
    if k==1, p=parts{1}; else, p=strjoin(parts(1:k),'/'); end
    paths{end+1}=p; %#ok<AGROW>
end
end

function tf=localIsAncestor(candidate,requested)
candidate=char(string(candidate));
requested=char(string(requested));
tf=strcmpi(candidate,requested) || startsWith([requested '/'],[candidate '/']);
end

function name=localModelName(model)
[~,name,ext]=fileparts(char(string(model)));
if isempty(ext), name=char(string(model)); end
end
