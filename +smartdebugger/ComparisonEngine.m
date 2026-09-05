classdef ComparisonEngine
    %COMPARISONENGINE Compare aligned MIL and SIL runtime port data.
    methods
        function report = compare(~,mil,sil,absTol,relTol,alignMethod)
            if nargin < 4 || isempty(absTol), absTol=1e-6; end
            if nargin < 5 || isempty(relTol), relTol=1e-4; end
            if nargin < 6 || isempty(alignMethod), alignMethod='linear'; end
            validateattributes(absTol,{'numeric'},{'scalar','nonnegative','finite'});
            validateattributes(relTol,{'numeric'},{'scalar','nonnegative','finite'});

            rows = cell(0,8);
            overall = 'PASS';
            firstFail = struct('Direction','','Port',0,'Time',NaN,'Signal','');
            plotPayload = struct('Time',[],'MIL',[],'SIL',[],'Error',[],'Signal','');

            directions = {'Input','Output'};
            for d = 1:numel(directions)
                direction = directions{d};
                milPorts = localPorts(mil,direction);
                silPorts = localPorts(sil,direction);
                n = max(numel(milPorts),numel(silPorts));
                for k = 1:n
                    if k > numel(milPorts)
                        rows(end+1,:) = {direction,k,'-',localName(silPorts(k)), ...
                            'UNMAPPED',NaN,NaN,'-'}; %#ok<AGROW>
                        overall='FAIL'; continue;
                    end
                    if k > numel(silPorts)
                        rows(end+1,:) = {direction,k,localName(milPorts(k)),'-', ...
                            'UNMAPPED',NaN,NaN,'-'}; %#ok<AGROW>
                        overall='FAIL'; continue;
                    end
                    mp = milPorts(k); sp = silPorts(k);
                    [t,a,b,status] = localAligned(mp,sp,alignMethod);
                    if ~strcmp(status,'OK')
                        rows(end+1,:) = {direction,k,localName(mp),localName(sp), ...
                            status,NaN,NaN,'-'}; %#ok<AGROW>
                        overall='FAIL'; continue;
                    end
                    try
                        [status,maxAbs,maxRel,firstIndex] = localMetrics(a,b,t,absTol,relTol);
                    catch ME
                        status='COMPARE_ERROR'; maxAbs=NaN; maxRel=NaN; firstIndex=[];
                        rows(end+1,:) = {direction,k,localName(mp),localName(sp), ...
                            status,maxAbs,maxRel,'-'}; %#ok<AGROW>
                        overall='FAIL';
                        continue;
                    end
                    if isempty(firstIndex)
                        firstText='-';
                    else
                        firstText=num2str(t(firstIndex));
                        if isempty(firstFail.Signal)
                            firstFail.Direction=direction;
                            firstFail.Port=k;
                            firstFail.Time=t(firstIndex);
                            firstFail.Signal=localName(mp);
                            plotPayload.Time=t;
                            plotPayload.MIL=a;
                            plotPayload.SIL=b;
                            plotPayload.Error=a-b;
                            plotPayload.Signal=localName(mp);
                        end
                    end
                    rows(end+1,:) = {direction,k,localName(mp),localName(sp), ...
                        status,maxAbs,maxRel,firstText}; %#ok<AGROW>
                    if strcmp(status,'FAIL'), overall='FAIL'; end
                end
            end

            report = struct('Status',overall,'Table',{rows}, ...
                'Time',plotPayload.Time,'MIL',plotPayload.MIL, ...
                'SIL',plotPayload.SIL,'Error',plotPayload.Error, ...
                'Signal',plotPayload.Signal,'AbsTol',absTol,'RelTol',relTol, ...
                'AlignmentMethod',alignMethod,'FirstDivergence',firstFail);
        end
    end
end

function ports = localPorts(result,direction)
ports = struct([]);
if ~isstruct(result), return; end
if strcmp(direction,'Input') && isfield(result,'Inputs')
    ports = result.Inputs;
elseif strcmp(direction,'Output') && isfield(result,'Outputs')
    ports = result.Outputs;
end
end

function name = localName(port)
name = '-';
try
    if ~isempty(port.Name), name=char(port.Name); end
catch
end
end

function [t,a,b,status] = localAligned(mp,sp,method)
t=[]; a=[]; b=[]; status='NO_DATA';
try
    if isempty(mp.Series) || isempty(sp.Series)
        return;
    end
    ta=mp.Series.Time; da=mp.Series.Data;
    tb=sp.Series.Time; db=sp.Series.Data;
    [t,a,b]=smartdebugger.TimeAlignmentEngine.align(ta,da,tb,db,method);
    if isempty(t), status='NO_OVERLAP'; return; end
    if ~isequal(size(a),size(b)), status='SIZE_MISMATCH'; return; end
    if ~(isnumeric(a) || islogical(a)) || ~(isnumeric(b) || islogical(b))
        status='UNSUPPORTED_DATA'; return;
    end
    status='OK';
catch
    status='ALIGN_ERROR';
end
end

function [status,maxAbs,maxRel,firstIndex] = localMetrics(a,b,t,absTol,relTol)
a=double(a); b=double(b);
if any(~isfinite(a(:))) || any(~isfinite(b(:)))
    % NaN/Inf require exact semantic comparison rather than numerical tolerance.
    equal = (a==b) | (isnan(a)&isnan(b));
    bad = ~equal;
    err = abs(a-b);
    err(~isfinite(err))=Inf;
else
    err=abs(a-b);
    ref=abs(a);
    tol=absTol + relTol.*ref;
    bad=err>tol;
end
maxAbs=max(err(:));
ref=max(abs(a(:)),eps);
maxRel=max(err(:)./ref);
firstIndex=find(any(reshape(bad,size(bad,1),[]),2),1,'first');
if isempty(firstIndex)
    status='PASS';
else
    status='FAIL';
end
end
