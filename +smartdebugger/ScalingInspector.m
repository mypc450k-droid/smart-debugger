classdef ScalingInspector
    methods (Static)
        function info=inspect(value)
            info=struct('Class',class(value),'WordLength','','FractionLength','','Slope','','Bias','','Raw',value,'Physical',value,'Message','');
            try
                if isa(value,'fi')
                    info.WordLength=num2str(value.WordLength);
                    info.FractionLength=num2str(value.FractionLength);
                    info.Slope=num2str(value.Slope);
                    info.Bias=num2str(value.Bias);
                    info.Raw=storedInteger(value);
                    info.Physical=double(value);
                else
                    info.Message='No fi object supplied; no fixed-point scaling metadata was inferred.';
                end
            catch ME
                info.Message=ME.message;
            end
        end
    end
end
