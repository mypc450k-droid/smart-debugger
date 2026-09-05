classdef TestComparisonEngine < matlab.unittest.TestCase
    methods (Test)
        function passWithinTolerance(testCase)
            mil=fixture([1 2 3]); sil=fixture([1 2 3]);
            r=smartdebugger.ComparisonEngine().compare(mil,sil,1e-6,1e-6);
            testCase.verifyEqual(r.Status,'PASS');
        end
        function failOutsideTolerance(testCase)
            mil=fixture([1 2 3]); sil=fixture([1 2.1 3]);
            r=smartdebugger.ComparisonEngine().compare(mil,sil,1e-6,1e-6);
            testCase.verifyEqual(r.Status,'FAIL');
            testCase.verifyEqual(r.Table{1,2},'FAIL');
        end
    end
end
function r=fixture(data)
t=timeseries(data(:),(0:numel(data)-1)');
p=struct('Port',1,'Name','Y','Value',data(end),'DataType','double','Dimension',mat2str(size(data)),'SampleTime','0.01','Series',t);
r=struct('Mode','MIL','Model','fixture','Block','fixture/Block','Time',t.Time,'Inputs',p,'Outputs',p);
end
