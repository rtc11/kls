module kls::dap::lifecycle;

import std::collections::object;
import kls::dap::types;

// Handle DAP initialize request
// Returns capabilities object for response body
fn Object* handle_initialize(Object* args) {
	DapCapabilities caps = types::default_capabilities();

	Object* body = object::new_obj(tmem);
	body.set("supportsConfigurationDoneRequest", caps.supports_configuration_done_request);
	body.set("supportsFunctionBreakpoints", caps.supports_function_breakpoints);
	body.set("supportsConditionalBreakpoints", caps.supports_conditional_breakpoints);
	body.set("supportsEvaluateForHovers", caps.supports_evaluate_for_hovers);
	body.set("supportsExceptionInfoRequest", caps.supports_exception_info_request);
	body.set("supportsSetVariable", caps.supports_set_variable);
	body.set("supportsTerminateRequest", caps.supports_terminate_request);
	body.set("supportsSingleThreadExecutionRequests", caps.supports_single_thread_execution_requests);

	return body;
}

// Handle DAP disconnect request
// Note: actual disconnect logic (JDWP close, process kill) is in server.c3 dispatch
fn Object* handle_disconnect(Object* args) {
	return object::new_obj(tmem);  // empty body = success
}

// Handle DAP terminate request
// Note: actual terminate logic (JDWP exit_vm, process kill) is in server.c3 dispatch
fn Object* handle_terminate(Object* args) {
	return object::new_obj(tmem);  // empty body = success
}
