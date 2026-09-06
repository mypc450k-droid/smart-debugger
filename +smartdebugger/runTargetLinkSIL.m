function result=runTargetLinkSIL(model,subsystem,stopTime,varargin)
%RUNTARGETLINKSIL Run TargetLink SIL and extract TargetLink Data Server data.
% Default behavior reuses the existing TargetLink generated/host code.
% Optional 4th argument 'regenerate' requests code generation/build.
if nargin<1 || isempty(model), error('SmartDebugger:TargetLinkModelRequired','TargetLink model/frame is required.'); end
if nargin<2 || isempty(subsystem), error('SmartDebugger:TargetLinkSubsystemRequired','TargetLink block/subsystem path is required.'); end
if nargin<3 || isempty(stopTime), stopTime='auto'; end
regenerate=false;
if nargin>=4 && ~isempty(varargin{1}), regenerate=strcmpi(char(string(varargin{1})),'regenerate'); end
mdl=localModelName(model);
if ~bdIsLoaded(mdl), load_system(mdl); end
open_system(mdl);
requested=char(string(subsystem));
[resolved,info]=localResolveTargetLinkSubsystem(mdl,requested);
if isempty(resolved), error('SmartDebugger:TargetLinkSILMappingFailed','%s',info.Message); end
manager=smartdebugger.TargetLinkSILManager();
result=manager.run(model,resolved,stopTime,regenerate);
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
fprintf('Code generation    : %s\n',result.CodeGenerationMode);
fprintf('Data source        : %s\n',result.DataSource);
fprintf('Data access        : %s\n',result.DataAccessMethod);
fprintf('Signal count       : %d\n',result.SignalCount);
fprintf('Message            : %s\n',result.Message);
if strcmpi(result.Status,'ERROR'), error('SmartDebugger:TargetLinkSILFailed','TargetLink SIL failed: %s',result.Message); end
end

function [resolved,info]=localResolveTargetLinkSubsystem(model,requested)
resolved='';
info=struct('Requested',requested,'Resolved','','Method','NONE','Confidence','NONE','Candidates',{{}},'Message','');
% TargetLink Data Server is the strongest model-independent source because it
% records the software-unit path actually used by TargetLink simulations.
if ~isempty(which('tlds'))
    try
        sims=feval('tlds',0,'get','simulations');
        paths=localTLDSCandidates(sims,model,requested);
        if ~isempty(paths)
            resolved=localLeaf(paths{1});
            info.Resolved=resolved; info.Method='TLDS_SUBSYSTEM_METADATA'; info.Confidence='VERY_HIGH'; info.Candidates=paths;
            info.Message=['Resolved TargetLink software unit from TargetLink Data Server metadata: ' resolved];
            return
        end
    catch
    end
end
% If the requested input is already a local TargetLink software-unit name,
% preserve it. This supports direct use without relying on hierarchy parsing.
if ~contains(requested,'/')
    resolved=requested; info.Resolved=resolved; info.Method='LOCAL_NAME'; info.Confidence='HIGH';
    info.Message='Using supplied local TargetLink subsystem name.'; return
end
% Read-only object discovery. Do not infer a software unit merely because an
% ordinary Simulink subsystem contains TargetLink blocks.
for p=localAncestorPaths(requested)
    p=p{1};
    if strcmpi(p,model), continue; end
    try
        h=get_param(p,'Handle');
        if ~isempty(which('tl_get'))
            d=feval('tl_get',h,'BlockDataStruct');
            if isstruct(d) && ~isempty(fieldnames(d))
                resolved=get_param(p,'Name'); info.Resolved=resolved; info.Method='TL_GET_ANCESTOR'; info.Confidence='HIGH'; info.Candidates={p};
                info.Message=['Resolved TargetLink object ancestor: ' resolved]; return
            end
        end
    catch
    end
end
% Final explicit subsystem fallback, never hidden as high confidence.
try
    h=get_param(requested,'Handle');
    if strcmpi(get_param(h,'BlockType'),'SubSystem')
        resolved=get_param(h,'Name'); info.Resolved=resolved; info.Method='SUBSYSTEM_NAME'; info.Confidence='MEDIUM'; info.Candidates={requested};
        info.Message='Using selected subsystem as last-resort TargetLink identifier.'; return
    end
catch
end
info.Message=['Could not determine the TargetLink software unit owning selected target: ' requested];
end

function candidates=localTLDSCandidates(sims,model,requested)
candidates={};
if iscell(sims), sims=[sims{:}]; end
if ~isstruct(sims), return; end
for i=1:numel(sims)
    s=sims(i);
    if ~isfield(s,'TLSubSystems') || isempty(s.TLSubSystems), continue; end
    if isfield(s,'system') && ~isempty(s.system) && ~strcmpi(char(string(s.system)),model), continue; end
    tls=s.TLSubSystems;
    if ~isstruct(tls), continue; end
    for j=1:numel(tls)
        if ~isfield(tls(j),'name') || isempty(tls(j).name), continue; end
        p=char(string(tls(j).name));
        if ~strcmpi(p,model) && (strcmpi(p,requested) || startsWith([requested '/'],[p '/']))
            candidates{end+1}=p; %#ok<AGROW>
        end
    end
end
if isempty(candidates), return; end
[candidates,~]=unique(candidates,'stable');
[~,ix]=sort(cellfun(@(x)numel(regexp(x,'/','split')),candidates),'descend');
candidates=candidates(ix);
end

function paths=localAncestorPaths(path)
parts=regexp(char(string(path)),'/','split'); paths={};
for k=numel(parts):-1:1
    if k==1, paths{end+1}=parts{1}; else, paths{end+1}=strjoin(parts(1:k),'/'); end %#ok<AGROW>
end
end

function n=localLeaf(path)
p=regexp(char(string(path)),'/','split'); n=p{end};
end

function name=localModelName(model)
[~,name,ext]=fileparts(char(string(model)));
if isempty(ext), name=char(string(model)); end
end
