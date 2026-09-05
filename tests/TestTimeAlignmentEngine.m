classdef TestTimeAlignmentEngine < matlab.unittest.TestCase
    methods (Test)
        function alignsDifferentRates(testCase)
            ta=(0:0.1:1)';
            tb=(0:0.2:1)';
            da=ta.^2;
            db=tb.^2;
            [t,a,b]=smartdebugger.TimeAlignmentEngine.align(ta,da,tb,db,'linear');
            testCase.verifyEqual(t,unique([ta;tb]));
            testCase.verifySize(a,size(t));
            testCase.verifySize(b,size(t));
            testCase.verifyEqual(a(1),b(1));
        end

        function nearestHandlesLogical(testCase)
            ta=(0:1:2)'; tb=(0:0.5:2)';
            da=logical([0;1;0]); db=logical([0;0;1;1;0]);
            [t,a,b]=smartdebugger.TimeAlignmentEngine.align(ta,da,tb,db,'nearest');
            testCase.verifySize(a,size(t));
            testCase.verifySize(b,size(t));
            testCase.verifyClass(a,'logical');
        end
    end
end
