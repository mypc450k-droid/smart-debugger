classdef TimeAlignmentEngine
    %TIMEALIGNMENTENGINE Align two time series on their common interval.
    methods (Static)
        function [t,a,b]=align(aTime,aData,bTime,bData,method)
            if nargin<5||isempty(method), method='linear'; end
            aTime=aTime(:); bTime=bTime(:);
            if isempty(aTime)||isempty(bTime)||isempty(aData)||isempty(bData), t=[]; a=[]; b=[]; return; end
            [aTime,ia]=unique(aTime,'stable'); [bTime,ib]=unique(bTime,'stable');
            aData=localSelectFirstDimension(aData,ia); bData=localSelectFirstDimension(bData,ib);
            lo=max(aTime(1),bTime(1)); hi=min(aTime(end),bTime(end));
            if hi<lo, t=[]; a=[]; b=[]; return; end
            t=unique([aTime(aTime>=lo & aTime<=hi); bTime(bTime>=lo & bTime<=hi)]);
            if isempty(t), a=[]; b=[]; return; end
            a=[]; b=[];
            if numel(aTime)==1, a=localRepeat(aData,numel(t)); end
            if numel(bTime)==1, b=localRepeat(bData,numel(t)); end
            if isempty(a), a=localInterp(aTime,aData,t,method); end
            if isempty(b), b=localInterp(bTime,bData,t,method); end
        end
    end
end

function out=localInterp(t,data,newT,method)
originalClass=class(data);
if ~isnumeric(data)&&~islogical(data), error('SmartDebugger:NonNumericSeries','Only numeric/logical time-series can be interpolated.'); end
if islogical(data)||isinteger(data), method='nearest'; end
n=size(data,1); tail=size(data); tail=tail(2:end);
if isreal(data)&&ismatrix(data)
    switch lower(method)
        case 'nearest', out=interp1(t,data,newT,'nearest','extrap');
        case {'zoh','previous'}, out=interp1(t,data,newT,'previous','extrap');
        otherwise, out=interp1(t,data,newT,'linear','extrap');
    end
else
    flat=reshape(data,n,[]);
    switch lower(method)
        case 'nearest', y=interp1(t,flat,newT,'nearest','extrap');
        case {'zoh','previous'}, y=interp1(t,flat,newT,'previous','extrap');
        otherwise, y=interp1(t,flat,newT,'linear','extrap');
    end
    out=reshape(y,[numel(newT),tail]);
end
if islogical(data)
    out=logical(out);
elseif isinteger(data)
    out=cast(out,originalClass);
end
end

function data=localSelectFirstDimension(data,index)
if numel(index)==size(data,1), return; end
subs=repmat({':'},1,ndims(data)); subs{1}=index; data=data(subs{:});
end

function out=localRepeat(data,n)
out=repmat(data,[n,ones(1,max(0,ndims(data)-1))]);
end
