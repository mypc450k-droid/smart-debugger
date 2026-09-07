function app = SmartDebugger(varargin)
%SMARTDEBUGGER Launch the dedicated MIL and SIL Smart Debugger windows.
%   app = SmartDebugger launches two independent full-size windows:
%       app.MIL : enhanced MIL debugger
%       app.SIL : existing SIL debugger presentation/controller
%
%   The currently open Simulink model is detected automatically. An explicit
%   Model name can still be supplied for scripted launch.

    app = smartdebugger.SmartDebuggerWorkspace(varargin{:});
    if nargout == 0
        clear app
    end
end
