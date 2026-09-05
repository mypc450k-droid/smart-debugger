classdef RootCauseAnalyzer
    methods (Static)
        function finding=firstDivergence(report)
            finding=struct('Status','UNKNOWN','Signal','','Time',NaN,'Message','No divergence data available.');
            if isempty(report) || ~isfield(report,'Table') || isempty(report.Table), return; end
            for k=1:size(report.Table,1)
                if strcmp(report.Table{k,2},'FAIL')
                    finding.Status='LIKELY'; finding.Signal=report.Table{k,1};
                    if ~strcmp(report.Table{k,5},'-'), finding.Time=str2double(report.Table{k,5}); end
                    finding.Message=sprintf('First observed failing compared signal: %s. This is evidence of divergence, not proof of root cause.',finding.Signal);
                    return
                end
            end
            finding.Status='CONFIRMED'; finding.Message='No compared output exceeded the configured tolerance.';
        end
    end
end
