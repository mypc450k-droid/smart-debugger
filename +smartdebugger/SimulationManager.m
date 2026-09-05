classdef SimulationManager < handle
    %SIMULATIONMANAGER Runs simulations and captures selected block ports.
    properties (SetAccess=private)
        Diagnostics
    end
    methods
        function obj=SimulationManager(diag), obj.Diagnostics=diag; end
        function result=runMIL(obj,model,block,stopTime), result=obj.run(model,block,stopTime,'MIL'); end
        function result=runSIL(obj,model,block,stopTime), result=obj.run(model,block,stopTime,'SIL'); end
    end
    methods (Access=private)
        function result=run(obj,model,block,stopTime,mode)
            result=struct('Mode',mode,'Model',model,'Block',block,'Time',[], 'Inputs',[], 'Outputs',[]);
            tx=smartdebugger.TransactionManager(); cleanup=onCleanup(@()tx.restore()); %#ok<NASGU>
            try
                load_system(model);
                set_param(model,'SimulationCommand','update');
                inNames=obj.instrumentPorts(block,'Inport',tx); outNames=obj.instrumentPorts(block,'Outport',tx);
                oldSL=get_param(model,'SignalLogging'); tx.record(model,'SignalLogging',oldSL); set_param(model,'SignalLogging','on');
                oldNameMode=get_param(model,'SignalLoggingNameMode'); tx.record(model,'SignalLoggingNameMode',oldNameMode); set_param(model,'SignalLoggingNameMode','UserSpecified');
                simOut=sim(model,'StopTime',stopTime,'ReturnWorkspaceOutputs','on');
                logs=[];
                try, logs=simOut.get('logsout'); catch, end
                if isempty(logs), try, logs=simOut.logsout; catch, end, end
                result.Inputs=obj.readLogged(logs,inNames); result.Outputs=obj.readLogged(logs,outNames);
                [result.Time,result]=obj.populateTime(result); result.SimulationOutput=simOut;
            catch ME
                obj.Diagnostics.recordException(ME,[mode ' simulation']); rethrow(ME);
            end
        end
        function names=instrumentPorts(~,block,direction,tx)
            names={}; ph=get_param(block,'PortHandles');
            if strcmp(direction,'Inport'), hs=ph.Inport; else, hs=ph.Outport; end
            for k=1:numel(hs)
                line=get_param(hs(k),'Line');
                if isempty(line) || isequal(line,-1), names{end+1}=''; continue; end %#ok<AGROW>
                tx.record(line,'DataLogging',get_param(line,'DataLogging')); tx.record(line,'DataLoggingNameMode',get_param(line,'DataLoggingNameMode')); tx.record(line,'DataLoggingName',get_param(line,'DataLoggingName'));
                nm=get_param(line,'Name'); if isempty(nm), nm=sprintf('SmartDebugger_%s_%d',lower(direction),k); end
                nm=matlab.lang.makeValidName(nm);
                set_param(line,'DataLoggingNameMode','Custom'); set_param(line,'DataLoggingName',nm); set_param(line,'DataLogging','on');
                names{end+1}=nm; %#ok<AGROW>
            end
        end
        function ports=readLogged(obj,logs,names)
            ports=repmat(struct('Port',0,'Name','','Value',[],'DataType','','Dimension','','SampleTime','','Series',[]),0,1);
            for k=1:numel(names)
                p=struct('Port',k,'Name',names{k},'Value',[],'DataType','','Dimension','','SampleTime','','Series',[]);
                if isempty(names{k}), ports(end+1)=p; continue; end %#ok<AGROW>
                try
                    el=logs.getElement(names{k}); ts=el.Values; p.Series=ts; p.Name=names{k};
                    if isprop(ts,'Data'), p.Value=ts.Data(end,:,:,:); p.DataType=class(ts.Data); p.Dimension=mat2str(size(ts.Data)); end
                    if isprop(ts,'Time') && ~isempty(ts.Time), p.SampleTime='logged'; end
                catch ME, obj.Diagnostics.recordException(ME,['Read logged signal ' names{k}]); end
                ports(end+1)=p; %#ok<AGROW>
            end
        end
        function [t,result]=populateTime(~,result)
            t=[]; allPorts=[result.Inputs result.Outputs];
            for k=1:numel(allPorts)
                s=allPorts(k).Series;
                try, if ~isempty(s) && isprop(s,'Time'), t=s.Time; break; end, catch, end
            end
            result.Time=t;
        end
    end
end
