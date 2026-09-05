function app = SmartDebugger(varargin)
%SMARTDEBUGGER Launch the Smart Debugger application.
%   app = SmartDebugger launches the programmatic uifigure application.
%   MATLAB and Simulink are required for model operations.

    app = smartdebugger.SmartDebuggerApp(varargin{:});
    if nargout == 0
        clear app
    end
end
