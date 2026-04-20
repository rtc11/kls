module kls::dap::types;

// DAP message types for Debug Adapter Protocol

enum DapEventType : int {
	INITIALIZED,
	STOPPED,
	CONTINUED,
	EXITED,
	TERMINATED,
	THREAD,
	OUTPUT,
	BREAKPOINT,
	MODULE,
	PROCESS,
}

enum StoppedReason : int (String name) {
	STEP        { "step" },
	BREAKPOINT  { "breakpoint" },
	EXCEPTION   { "exception" },
	PAUSE       { "pause" },
	ENTRY       { "entry" },
	GOTO        { "goto" },
	DATA_BREAKPOINT { "data breakpoint" },
}

enum OutputCategory : int (String name) {
	CONSOLE  { "console" },
	STDOUT   { "stdout" },
	STDERR   { "stderr" },
	TELEMETRY { "telemetry" },
}

enum ThreadReason : int (String name) {
	STARTED { "started" },
	EXITED  { "exited" },
}

// Breakpoint as tracked by DAP server
struct DapBreakpoint {
	int id;
	bool verified;
	String source_path;
	int line;
	String message;       // optional error/info message
}

// Source reference for DAP
struct DapSource {
	String name;
	String path;
	int source_reference;  // 0 = file on disk
}

// Stack frame for DAP
struct DapStackFrame {
	int id;
	String name;
	DapSource source;
	int line;
	int column;
	int end_line;
	int end_column;
}

// Scope for variable inspection
struct DapScope {
	String name;
	int variables_reference;
	bool expensive;
}

// Variable for inspection
struct DapVariable {
	String name;
	String value;
	String type_name;
	int variables_reference;  // >0 = has children
	int named_variables;
	int indexed_variables;
}

// Thread info
struct DapThread {
	int id;
	String name;
}

// DAP Capabilities returned in initialize response
struct DapCapabilities {
	bool supports_configuration_done_request;
	bool supports_function_breakpoints;
	bool supports_conditional_breakpoints;
	bool supports_evaluate_for_hovers;
	bool supports_exception_info_request;
	bool supports_set_variable;
	bool supports_terminate_request;
	bool supports_single_thread_execution_requests;
}

fn DapCapabilities default_capabilities() {
	return {
		.supports_configuration_done_request = true,
		.supports_function_breakpoints = true,
		.supports_conditional_breakpoints = true,
		.supports_evaluate_for_hovers = true,
		.supports_exception_info_request = false,
		.supports_set_variable = false,
		.supports_terminate_request = true,
		.supports_single_thread_execution_requests = false,
	};
}
