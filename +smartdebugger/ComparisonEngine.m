classdef ComparisonEngine
    methods
        function report=compare(~,mil,sil,absTol,relTol)
            if nargin<4 || isempty(absTol), absTol=1e-6; end
            if nargin<5 || isempty(relTol), relTol=1e-4; end
            names={}; milPorts=mil.Outputs; silPorts=sil.Outputs;
            for k=1:numel(milPorts), names{end+1}=milPorts(k).Name; end %#ok<AGROW>
            rows=cell(0,5); firstSeries=[]; firstT=[]; firstErr=[]; overall='PASS';
            for k=1:numel(names)
                name=names{k}; mi=find(strcmp({milPorts.Name},name),1); si=find(strcmp({silPorts.Name},name),1);
                if isempty(mi) || isempty(si)
                    rows(end+1,:)={name,'UNMAPPED',NaN,NaN,'-'}; overall='FAIL'; continue
                end
                [t,a,b]=objSeries(milPorts(mi).Series,silPorts(si).Series);
                if isempty(t)
                    rows(end+1,:)={name,'NO_DATA',NaN,NaN,'-'}; overall='FAIL'; continue
                end
                a=double(a); b=double(b);
                if ~isequal(size(a),size(b))
                    rows(end+1,:)={name,'SIZE_MISMATCH',NaN,NaN,'-'}; overall='FAIL'; continue
                end
                e=a-b; ae=abs(e); tol=absTol+relTol.*abs(a); pass=ae<=tol;
                maxAbs=max(ae(:)); denom=max(abs(a(:)),eps); maxRel=max(ae(:)./denom(:));
                idx=find(~pass(:),1,'first');
                if isempty(idx), status='PASS'; fm='-'; else, status='FAIL'; overall='FAIL'; [ii,~]=ind2sub(size(pass),idx); fm=num2str(t(ii)); end
                rows(end+1,:)={name,status,maxAbs,maxRel,fm};
                if isempty(firstSeries), firstT=t; firstSeries={a,b}; firstErr=e; end
            end
            report=struct('Status',overall,'Table',{rows},'Time',firstT,'MIL',[],'SIL',[],'Error',[],'AbsTol',absTol,'RelTol',relTol);
            if ~isempty(firstSeries), report.MIL=firstSeries{1}; report.SIL=firstSeries{2}; report.Error=firstErr; end
        end
    end
end
function [t,a,b]=objSeries(sa,sb)
    t=[]; a=[]; b=[];
    try
        ta=sa.Time; da=sa.Data; tb=sb.Time; db=sb.Data;
        [t,a,b]=smartdebugger.TimeAlignmentEngine.align(ta,da,tb,db,'linear');
    catch
    end
end
