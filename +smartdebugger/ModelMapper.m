classdef ModelMapper
    %MODELMAPPER Map logical MIL blocks to SIL implementation blocks.
    methods (Static)
        function [mapped,confidence,method,candidates]=mapBlock(milPath,silModel)
            mapped=''; confidence='NONE'; method='NONE'; candidates={};
            milPath=char(string(milPath)); silModel=char(string(silModel));
            if isempty(milPath)||isempty(silModel), return; end
            try
                [~,silRoot,~]=fileparts(silModel);
                if isempty(silRoot), silRoot=silModel; end
                [milRoot,relative]=localRelativePath(milPath);
                if strcmpi(milRoot,silRoot)
                    candidate=milPath;
                    if localBlockExists(candidate), mapped=candidate; confidence='EXACT'; method='IDENTICAL_PATH'; candidates={candidate}; return; end
                end
                if isempty(relative), relative=get_param(milPath,'Name'); end
                candidate=[silRoot '/' relative];
                if localBlockExists(candidate)
                    mapped=candidate; confidence='EXACT'; method='RELATIVE_PATH'; candidates={candidate}; return;
                end
                nm=get_param(milPath,'Name'); candidates=find_system(silRoot,'Type','Block','Name',nm);
                if numel(candidates)==1
                    mapped=candidates{1}; confidence='HIGH'; method='UNIQUE_NAME';
                elseif numel(candidates)>1
                    confidence='AMBIGUOUS'; method='NAME';
                end
            catch
                % Automatic mapping is advisory and never masks a simulation error.
            end
        end
    end
end

function [root,relative]=localRelativePath(path)
parts=regexp(path,'/','split'); root=parts{1};
if numel(parts)>1, relative=strjoin(parts(2:end),'/'); else, relative=''; end
end

function tf=localBlockExists(path)
tf=false; try, get_param(path,'Handle'); tf=true; catch, end
end
