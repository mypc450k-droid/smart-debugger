classdef CompatibilityManager
    %COMPATIBILITYMANAGER Detect installed MATLAB/Simulink capabilities.
    methods
        function s=snapshot(~)
            s=struct('MATLAB',version,'Simulink','','Stateflow','', ...
                'SimulinkCoder',false,'StateflowAvailable',false,'TargetLinkAvailable',false);
            try
                s.Simulink=simulinkRelease.Release;
            catch
                try, s.Simulink=version('simulink'); catch, end
            end
            try
                s.Stateflow=version('stateflow');
                s.StateflowAvailable=true;
            catch
            end
            try
                s.SimulinkCoder=logical(license('test','Simulink_Coder'));
            catch
            end
            s.TargetLinkAvailable=smartdebugger.CompatibilityManager.hasTargetLink();
        end
    end

    methods (Static)
        function tf=hasSimulink()
            tf=exist('simulink','file')==2 || exist('sim','file')==2 || exist('bdroot','file')==2;
        end
        function tf=hasStateflow()
            tf=exist('sfroot','file')==2;
        end
        function tf=hasTargetLink()
            tf=false;
            try
                tf=~isempty(which('targetlink')) || ~isempty(which('tl_system')) || ...
                    ~isempty(which('tlSimulink'));
            catch
            end
        end
    end
end
