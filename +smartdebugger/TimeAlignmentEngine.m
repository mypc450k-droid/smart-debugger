classdef TimeAlignmentEngine
    methods (Static)
        function [t,a,b]=align(aTime,aData,bTime,bData,method)
            if nargin<5 || isempty(method), method='linear'; end
            aTime=aTime(:); bTime=bTime(:);
            if isempty(aTime) || isempty(bTime), t=[]; a=[]; b=[]; return; end
            t=unique([aTime;bTime]);
            lo=max(aTime(1),bTime(1)); hi=min(aTime(end),bTime(end));
            t=t(t>=lo & t<=hi);
            if isempty(t), a=[]; b=[]; return; end
            switch lower(method)
                case 'nearest'
                    a=interp1(aTime,aData,t,'nearest','extrap'); b=interp1(bTime,bData,t,'nearest','extrap');
                case 'zoh'
                    a=interp1(aTime,aData,t,'previous','extrap'); b=interp1(bTime,bData,t,'previous','extrap');
                otherwise
                    a=interp1(aTime,aData,t,'linear','extrap'); b=interp1(bTime,bData,t,'linear','extrap');
            end
        end
    end
end
