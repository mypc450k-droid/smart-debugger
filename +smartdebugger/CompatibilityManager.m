classdef CompatibilityManager
    methods
        function s=snapshot(~)
            s=struct('MATLAB',version,'Simulink','','Stateflow','','SimulinkCoder',false,'StateflowAvailable',false);
            try, s.Simulink=simulinkRelease.Release; catch, try, s.Simulink=version('simulink'); catch, end, end
            try, s.Stateflow=version('stateflow'); s.StateflowAvailable=true; catch, end
            try, s.SimulinkCoder=license('test','Simulink_Coder'); catch, end
        end
        function tf=hasSimulink(~)
            tf=exist('simulink','file')==2 || exist('sim','file')==2;
        end
        function tf=hasStateflow(~)
            tf=exist('sfroot','file')==2;
        end
        function tf=hasTargetLink(~)
            tf=exist('targetlink','file')==2 || ~isempty(which('tl_system')); 
        end
    end
end
