classdef TestComparisonEngine < matlab.unittest.TestCase
    methods (Test)
        function passWithinTolerance(testCase)
            mil=fixture([1 2 3]);
            sil=fixture([1 2 3]);
            r=smartdebugger.ComparisonEngine().compare(mil,sil,1e-6,1e-6);
            testCase.verifyEqual(r.Status,'PASS');
            testCase.verifyEqual(r.Table{1,5},'PASS');
            testCase.verifyEqual(r.Table{2,5},'PASS');
        end

        function failOutsideTolerance(testCase)
            mil=fixture([1 2 3]);
            sil=fixture([1 2.1 3]);
            r=smartdebugger.ComparisonEngine().compare(mil,sil,1e-6,1e-6);
            testCase.verifyEqual(r.Status,'FAIL');
            % Input and output rows are both generated. Output is row 2.
            testCase.verifyEqual(r.Table{2,5},'FAIL');
            testCase.verifyEqual(r.FirstDivergence.Port,1);
            testCase.verifyEqual(r.FirstDivergence.Time,1);
        end

        function compareInputAndOutputIndependently(testCase)
            mil=fixture([10 20 30]);
            sil=fixture([10 20 30]);
            sil.Inputs.Value=999;
            sil.Inputs.Series.Data=sil.Inputs.Series.Data+1;
            r=smartdebugger.ComparisonEngine().compare(mil,sil,1e-9,1e-9);
            testCase.verifyEqual(r.Status,'FAIL');
            testCase.verifyEqual(r.Table{1,1},'Input');
            testCase.verifyEqual(r.Table{1,5},'FAIL');
            testCase.verifyEqual(r.Table{2,1},'Output');
            testCase.verifyEqual(r.Table{2,5},'PASS');
        end

        function nearestAlignment(testCase)
            mil=fixture([1 2 3]);
            sil=fixture([1 2 3]);
            sil.Inputs.Series.Time=[0;2;4];
            sil.Inputs.Series.Data=[1;3;5];
            sil.Outputs.Series.Time=[0;2;4];
            sil.Outputs.Series.Data=[1;3;5];
            r=smartdebugger.ComparisonEngine().compare(mil,sil,1e-9,1e-9,'nearest');
            testCase.verifyEqual(r.Status,'FAIL');
            testCase.verifyEqual(r.AlignmentMethod,'nearest');
        end
    end
end

function r=fixture(data)
t=timeseries(data(:),(0:numel(data)-1)');
p=struct('Port',1,'Name','Y','LogName','', ...
    'Value',data(end),'DataType','double','Dimension',mat2str(size(data)), ...
    'SampleTime','0.01','Series',t,'LineHandle',-1,'SignalHandle',-1);
r=struct('Mode','MIL','Model','fixture','Block','fixture/Block', ...
    'Time',t.Time,'Inputs',p,'Outputs',p,'Status','PASS');
end
