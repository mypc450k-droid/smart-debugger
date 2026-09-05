classdef ModelMapper
    %MODELMAPPER Map logical MIL blocks to SIL implementation blocks.
    methods (Static)
        function [mapped,confidence,method,candidates] = mapBlock(milPath,silModel)
            mapped = '';
            confidence = 'NONE';
            method = 'NONE';
            candidates = {};
            milPath = char(string(milPath));
            silModel = char(string(silModel));
            if isempty(milPath) || isempty(silModel)
                return;
            end
            try
                [milRoot,relative] = localRelativePath(milPath);
                if strcmpi(milRoot,silModel)
                    candidate = milPath;
                    if localBlockExists(candidate)
                        mapped = candidate;
                        confidence = 'EXACT';
                        method = 'IDENTICAL_PATH';
                        candidates = {candidate};
                        return;
                    end
                end

                % Best case: same hierarchy below a differently named top model.
                candidate = strrep(relative,'/','/');
                if isempty(candidate)
                    candidate = get_param(milPath,'Name');
                end
                candidate = [silModel '/' candidate];
                if localBlockExists(candidate)
                    mapped = candidate;
                    confidence = 'EXACT';
                    method = 'RELATIVE_PATH';
                    candidates = {candidate};
                    return;
                end

                % Second strategy: unique block-name match.
                nm = get_param(milPath,'Name');
                candidates = find_system(silModel,'Type','Block','Name',nm);
                if numel(candidates) == 1
                    mapped = candidates{1};
                    confidence = 'HIGH';
                    method = 'UNIQUE_NAME';
                elseif numel(candidates) > 1
                    confidence = 'AMBIGUOUS';
                    method = 'NAME';
                end
            catch
                % Mapping is advisory. Never fail a simulation solely because
                % automatic mapping could not be established.
            end
        end
    end
end

function [root,relative] = localRelativePath(path)
parts = regexp(path,'/','split');
root = parts{1};
if numel(parts) > 1
    relative = strjoin(parts(2:end),'/');
else
    relative = '';
end
end

function tf = localBlockExists(path)
tf = false;
try
    get_param(path,'Handle');
    tf = true;
catch
end
end
