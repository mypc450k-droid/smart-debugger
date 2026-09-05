classdef ModelMapper
    methods (Static)
        function [mapped,confidence,method]=mapBlock(milPath,silModel)
            mapped=''; confidence='LOW'; method='NONE';
            if isempty(milPath) || isempty(silModel), return; end
            candidates={};
            try
                [~,nm]=fileparts(milPath);
                candidates=find_system(silModel,'Type','Block','Name',nm);
            catch
            end
            if numel(candidates)==1
                mapped=candidates{1}; confidence='HIGH'; method='NAME';
            elseif numel(candidates)>1
                % Never silently choose an ambiguous mapping.
                confidence='AMBIGUOUS'; method='NAME';
            end
        end
    end
end
