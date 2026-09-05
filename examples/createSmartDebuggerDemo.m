function model=createSmartDebuggerDemo()
%CREATESMARTDEBUGGERDEMO Create a small model for validating Smart Debugger.
%   Requires Simulink. The model has two inputs, a Gain and a Sum output.
model='smartdebugger_demo';
if bdIsLoaded(model), close_system(model,0); end
new_system(model); open_system(model);
add_block('simulink/Sources/Constant',[model '/InputA'],'Value','2');
add_block('simulink/Sources/Constant',[model '/InputB'],'Value','3');
add_block('simulink/Math Operations/Gain',[model '/Gain'],'Gain','4');
add_block('simulink/Math Operations/Sum',[model '/Sum'],'Inputs','++');
add_block('simulink/Sinks/Out1',[model '/Output']);
set_param([model '/InputA'],'Position',[30 40 80 70]);
set_param([model '/InputB'],'Position',[30 130 80 160]);
set_param([model '/Gain'],'Position',[130 40 210 70]);
set_param([model '/Sum'],'Position',[260 75 300 125]);
set_param([model '/Output'],'Position',[360 85 410 115]);
add_line(model,'InputA/1','Gain/1');
add_line(model,'Gain/1','Sum/1');
add_line(model,'InputB/1','Sum/2');
add_line(model,'Sum/1','Output/1');
save_system(model);
end
