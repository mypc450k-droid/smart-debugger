classdef StateflowAdapter
    %STATEFLOWADAPTER Read-only Stateflow metadata boundary.
    methods (Static)
        function tf=isAvailable()
            tf=exist('sfroot','file')==2;
        end

        function info=inspect(path)
            info=struct('Supported',false,'Path',char(path),'Name','','Type','', ...
                'ActionLanguage','','StateMachineType','','Message','');
            if ~smartdebugger.StateflowAdapter.isAvailable()
                info.Message='Stateflow is not available in this MATLAB installation.';
                return;
            end
            try
                rt=sfroot;
                path=char(path);
                % The documented chart lookup uses the Stateflow API Path filter.
                chart=find(rt,'-isa','Stateflow.Chart',Path=path);
                if isempty(chart)
                    % Try common chart-like Stateflow objects without modifying them.
                    candidates={ ...
                        'Stateflow.StateTransitionTableChart', ...
                        'Stateflow.TruthTableChart', ...
                        'Stateflow.EMChart'};
                    for k=1:numel(candidates)
                        try
                            chart=find(rt,'-isa',candidates{k},Path=path);
                            if ~isempty(chart), break; end
                        catch
                        end
                    end
                end
                if isempty(chart)
                    info.Message='No Stateflow object was found at the selected path.';
                    return;
                end
                chart=chart(1);
                info.Supported=true;
                if isprop(chart,'Name'), info.Name=char(chart.Name); end
                info.Type=class(chart);
                if isprop(chart,'ActionLanguage'), info.ActionLanguage=char(chart.ActionLanguage); end
                if isprop(chart,'StateMachineType'), info.StateMachineType=char(chart.StateMachineType); end
                info.Message='Stateflow metadata available through the documented API.';
            catch ME
                info.Message=ME.message;
            end
        end
    end
end
