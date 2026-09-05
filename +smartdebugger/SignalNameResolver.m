classdef SignalNameResolver
    methods (Static)
        function name=resolve(line,portIndex,direction)
            name='';
            try, name=get_param(line,'Name'); catch, end
            if isempty(name)
                name=sprintf('%s %d',direction,portIndex);
            end
        end
        function names=forPorts(block,direction)
            ph=get_param(block,'PortHandles');
            if strcmpi(direction,'Input'), h=ph.Inport; d='Input'; else, h=ph.Outport; d='Output'; end
            names=cell(1,numel(h));
            for k=1:numel(h)
                line=get_param(h(k),'Line');
                if isempty(line) || isequal(line,-1), names{k}=sprintf('%s %d',d,k); else, names{k}=smartdebugger.SignalNameResolver.resolve(line,k,d); end
            end
        end
    end
end
