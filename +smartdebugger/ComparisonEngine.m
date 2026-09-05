classdef ComparisonEngine
    %COMPARISONENGINE Compare aligned MIL and SIL runtime port data.
    methods
        function report = compare(~,mil,sil,absTol,relTol,alignMethod)
            if nargin < 4 || isempty(absTol), absTol = 1e-6; end
            if nargin < 5 || isempty(relTol), relTol = 1e-4; end
            if nargin < 6 || isempty(alignMethod), alignMethod = 'linear'; end
            validateattributes(absTol,{'numeric'},{'scalar','nonnegative','finite'});
            validateattributes(relTol,{'numeric'},{'scalar','nonnegative','finite'});
            rows = cell(0,8);
            overall = 'PASS';
            firstFail = struct('Direction','','Port',0,'Time',NaN,'Signal','');
            plotPayload = struct('Time',[],'MIL',[],'SIL',[],'Error',[],'Signal','');
            directions = {'Input','Output'};
            for d = 1:numel(directions)
                direction = directions{d};
                milPorts = ComparisonEngine.getPorts(mil,direction);
                silPorts = ComparisonEngine.getPorts(sil,direction);
                n = max(numel(milPorts),numel(silPorts));
                for k = 1:n
                    if k > numel(milPorts)
                        rows(end+1,:) = {direction,k,'-',ComparisonEngine.getName(silPorts(k)),'UNMAPPED',NaN,NaN,'-'}; %#ok<AGROW>
                        overall = 'FAIL';
                        continue;
                    end
                    if k > numel(silPorts)
                        rows(end+1,:) = {direction,k,ComparisonEngine.getName(milPorts(k)),'-','UNMAPPED',NaN,NaN,'-'}; %#ok<AGROW>
                        overall = 'FAIL';
                        continue;
                    end
                    mp = milPorts(k);
                    sp = silPorts(k);
                    [t,a,b,status] = ComparisonEngine.aligned(mp,sp,alignMethod);
                    if ~strcmp(status,'OK')
                        rows(end+1,:) = {direction,k,ComparisonEngine.getName(mp),ComparisonEngine.getName(sp),status,NaN,NaN,'-'}; %#ok<AGROW>
                        overall = 'FAIL';
                        continue;
                    end
                    try
                        [status,maxAbs,maxRel,firstIndex] = ComparisonEngine.metrics(a,b,t,absTol,relTol);
                    catch
                        status = 'COMPARE_ERROR';
                        maxAbs = NaN;
                        maxRel = NaN;
                        firstIndex = [];
                    end
                    if isempty(firstIndex)
                        firstText = '-';
                    else
                        firstText = num2str(t(firstIndex));
                        if isempty(firstFail.Signal)
                            firstFail.Direction = direction;
                            firstFail.Port = k;
                            firstFail.Time = t(firstIndex);
                            firstFail.Signal = ComparisonEngine.getName(mp);
                            plotPayload.Time = t;
                            plotPayload.MIL = a;
                            plotPayload.SIL = b;
                            plotPayload.Error = ComparisonEngine.error(a,b);
                            plotPayload.Signal = ComparisonEngine.getName(mp);
                        end
                    end
                    rows(end+1,:) = {direction,k,ComparisonEngine.getName(mp),ComparisonEngine.getName(sp),status,maxAbs,maxRel,firstText}; %#ok<AGROW>
                    if strcmp(status,'FAIL') || strcmp(status,'COMPARE_ERROR'), overall = 'FAIL'; end
                end
            end
            report = struct('Status',overall,'Table',{rows},'Time',plotPayload.Time, ...
                'MIL',plotPayload.MIL,'SIL',plotPayload.SIL,'Error',plotPayload.Error, ...
                'Signal',plotPayload.Signal,'AbsTol',absTol,'RelTol',relTol, ...
                'AlignmentMethod',alignMethod,'FirstDivergence',firstFail);
        end
    end

    methods (Static, Access=private)
        function ports = getPorts(result,direction)
            ports = struct([]);
            if ~isstruct(result), return; end
            if strcmp(direction,'Input') && isfield(result,'Inputs')
                ports = result.Inputs;
            elseif strcmp(direction,'Output') && isfield(result,'Outputs')
                ports = result.Outputs;
            end
        end

        function name = getName(port)
            name = '-';
            try
                if ~isempty(port.Name), name = char(port.Name); end
            catch
            end
        end

        function [t,a,b,status] = aligned(mp,sp,method)
            t = []; a = []; b = []; status = 'NO_DATA';
            try
                if isempty(mp.Series) || isempty(sp.Series), return; end
                [t,a,b] = smartdebugger.TimeAlignmentEngine.align(mp.Series.Time,mp.Series.Data, ...
                    sp.Series.Time,sp.Series.Data,method);
                if isempty(t), status = 'NO_OVERLAP'; return; end
                if ~isequal(size(a),size(b)), status = 'SIZE_MISMATCH'; return; end
                if ~(isnumeric(a) || islogical(a)) || ~(isnumeric(b) || islogical(b))
                    status = 'UNSUPPORTED_DATA';
                    return;
                end
                status = 'OK';
            catch
                status = 'ALIGN_ERROR';
            end
        end

        function [status,maxAbs,maxRel,firstIndex] = metrics(a,b,t,absTol,relTol) %#ok<INUSD>
            a = double(a);
            b = double(b);
            finiteBoth = isfinite(a) & isfinite(b);
            equalSpecial = ((a == b) & ~finiteBoth) | (isnan(a) & isnan(b));
            err = zeros(size(a));
            bad = false(size(a));
            if any(finiteBoth(:))
                ef = abs(a(finiteBoth)-b(finiteBoth));
                ref = abs(a(finiteBoth));
                tol = absTol + relTol .* ref;
                err(finiteBoth) = ef;
                bad(finiteBoth) = ef > tol;
            end
            special = ~finiteBoth;
            if any(special(:))
                bad(special) = ~equalSpecial(special);
                err(special) = Inf;
                err(equalSpecial) = 0;
            end
            maxAbs = max(err(:));
            ref = abs(a);
            finiteRef = isfinite(ref) & ref > eps;
            rel = zeros(size(err));
            rel(finiteRef) = err(finiteRef) ./ ref(finiteRef);
            rel(~finiteRef & err > 0) = Inf;
            maxRel = max(rel(:));
            firstIndex = find(any(reshape(bad,size(bad,1),[]),2),1,'first');
            if isempty(firstIndex), status = 'PASS'; else, status = 'FAIL'; end
        end

        function e = error(a,b)
            e = double(a) - double(b);
            e(~isfinite(e)) = Inf;
        end
    end
end
