function results=runSmartDebuggerTests()
%RUNSMARTDEBUGGERTESTS Run repository unit tests.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(root);
suite=testsuite(fullfile(root,'tests'));
results=runtests(suite);
disp(results);
end
