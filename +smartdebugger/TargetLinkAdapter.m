classdef TargetLinkAdapter
    %TARGETLINKADAPTER Optional boundary for project-specific TargetLink APIs.
    methods (Static)
        function tf=isAvailable()
            tf=~isempty(which('tl_system')) || ~isempty(which('targetlink'));
        end
        function info=inspect(block)
            info=struct('Available',smartdebugger.TargetLinkAdapter.isAvailable(),'Block',block,'Message','');
            if ~info.Available
                info.Message='TargetLink APIs were not detected. Generic Simulink SIL capture remains available.';
            else
                info.Message=['TargetLink detected. Project/release-specific integration is isolated in this adapter. ' ...
                    'No private TargetLink API is assumed.'];
            end
        end
    end
end
