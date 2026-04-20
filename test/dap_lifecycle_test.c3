module kls::test::dap_lifecycle_test;

import std::collections::object;
import kls::dap::lifecycle;
import kls::dap::types;

// ── handle_initialize ──────────────────────────────────────────────

fn void initialize_returns_capabilities() @test {
	@pool() {
		Object* body = lifecycle::handle_initialize(null);
		assert(body != null, "expected non-null body");

		// Check known capabilities
		bool cfg_done = body.get_bool("supportsConfigurationDoneRequest") ?? false;
		assert(cfg_done == true, "expected supportsConfigurationDoneRequest = true");

		bool terminate = body.get_bool("supportsTerminateRequest") ?? false;
		assert(terminate == true, "expected supportsTerminateRequest = true");

		bool fn_bp = body.get_bool("supportsFunctionBreakpoints") ?? false;
		assert(fn_bp == false, "expected supportsFunctionBreakpoints = false");

		bool cond_bp = body.get_bool("supportsConditionalBreakpoints") ?? false;
		assert(cond_bp == false, "expected supportsConditionalBreakpoints = false");

		bool eval_hover = body.get_bool("supportsEvaluateForHovers") ?? false;
		assert(eval_hover == false, "expected supportsEvaluateForHovers = false");
	};
}

fn void initialize_with_args_returns_capabilities() @test {
	@pool() {
		Object* args = object::new_obj(tmem);
		args.set("clientID", "test-client");
		Object* body = lifecycle::handle_initialize(args);
		assert(body != null, "expected non-null body");
	};
}

// ── handle_disconnect ──────────────────────────────────────────────

fn void disconnect_returns_empty_object() @test {
	@pool() {
		Object* body = lifecycle::handle_disconnect(null);
		assert(body != null, "expected non-null body");
	};
}

// ── handle_terminate ───────────────────────────────────────────────

fn void terminate_returns_empty_object() @test {
	@pool() {
		Object* body = lifecycle::handle_terminate(null);
		assert(body != null, "expected non-null body");
	};
}

// ── default_capabilities ───────────────────────────────────────────

fn void default_capabilities_values() @test {
	DapCapabilities caps = types::default_capabilities();
	assert(caps.supports_configuration_done_request == true);
	assert(caps.supports_terminate_request == true);
	assert(caps.supports_function_breakpoints == false);
	assert(caps.supports_conditional_breakpoints == false);
	assert(caps.supports_evaluate_for_hovers == false);
	assert(caps.supports_exception_info_request == false);
	assert(caps.supports_set_variable == false);
	assert(caps.supports_single_thread_execution_requests == false);
}
