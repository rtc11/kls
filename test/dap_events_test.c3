module kls::test::dap_events_test;

import std::collections::object;
import kls::dap::events;
import kls::dap::jdwp::ids;
import kls::dap::jdwp::protocol;

// ── event_to_dap ───────────────────────────────────────────────────

fn void breakpoint_event_to_stopped() @test {
	@pool() {
		IdManager mgr;
		mgr.init();
		defer {
			mgr.thread_to_dap.free();
			mgr.dap_to_thread.free();
			mgr.dap_to_frame.free();
			mgr.dap_to_var.free();
		}

		JdwpEvent event;
		event.event_kind = protocol::EK_BREAKPOINT;
		event.thread_id = 42;

		Object* body = object::new_obj(tmem);
		String name = events::event_to_dap(&event, &mgr, body);
		assert(name == "stopped", "expected 'stopped', got: %s", name);

		String reason = body.get_string("reason") ?? "";
		assert(reason == "breakpoint", "expected reason=breakpoint, got: %s", reason);

		int tid = (int)(body.get_int("threadId") ?? 0);
		assert(tid == 1, "expected threadId=1, got %d", tid);
	};
}

fn void step_event_to_stopped() @test {
	@pool() {
		IdManager mgr;
		mgr.init();
		defer {
			mgr.thread_to_dap.free();
			mgr.dap_to_thread.free();
			mgr.dap_to_frame.free();
			mgr.dap_to_var.free();
		}

		JdwpEvent event;
		event.event_kind = protocol::EK_SINGLE_STEP;
		event.thread_id = 10;

		Object* body = object::new_obj(tmem);
		String name = events::event_to_dap(&event, &mgr, body);
		assert(name == "stopped");

		String reason = body.get_string("reason") ?? "";
		assert(reason == "step", "expected reason=step, got: %s", reason);
	};
}

fn void thread_start_event() @test {
	@pool() {
		IdManager mgr;
		mgr.init();
		defer {
			mgr.thread_to_dap.free();
			mgr.dap_to_thread.free();
			mgr.dap_to_frame.free();
			mgr.dap_to_var.free();
		}

		JdwpEvent event;
		event.event_kind = protocol::EK_THREAD_START;
		event.thread_id = 5;

		Object* body = object::new_obj(tmem);
		String name = events::event_to_dap(&event, &mgr, body);
		assert(name == "thread", "expected 'thread', got: %s", name);

		String reason = body.get_string("reason") ?? "";
		assert(reason == "started", "got: %s", reason);
	};
}

fn void thread_death_event() @test {
	@pool() {
		IdManager mgr;
		mgr.init();
		defer {
			mgr.thread_to_dap.free();
			mgr.dap_to_thread.free();
			mgr.dap_to_frame.free();
			mgr.dap_to_var.free();
		}

		JdwpEvent event;
		event.event_kind = protocol::EK_THREAD_DEATH;
		event.thread_id = 5;

		Object* body = object::new_obj(tmem);
		String name = events::event_to_dap(&event, &mgr, body);
		assert(name == "thread");

		String reason = body.get_string("reason") ?? "";
		assert(reason == "exited", "got: %s", reason);
	};
}

fn void vm_death_event() @test {
	@pool() {
		IdManager mgr;
		mgr.init();
		defer {
			mgr.thread_to_dap.free();
			mgr.dap_to_thread.free();
			mgr.dap_to_frame.free();
			mgr.dap_to_var.free();
		}

		JdwpEvent event;
		event.event_kind = protocol::EK_VM_DEATH;

		Object* body = object::new_obj(tmem);
		String name = events::event_to_dap(&event, &mgr, body);
		assert(name == "terminated", "expected 'terminated', got: %s", name);
	};
}

fn void class_prepare_event_internal() @test {
	@pool() {
		IdManager mgr;
		mgr.init();
		defer {
			mgr.thread_to_dap.free();
			mgr.dap_to_thread.free();
			mgr.dap_to_frame.free();
			mgr.dap_to_var.free();
		}

		JdwpEvent event;
		event.event_kind = protocol::EK_CLASS_PREPARE;
		event.thread_id = 1;

		Object* body = object::new_obj(tmem);
		String name = events::event_to_dap(&event, &mgr, body);
		assert(name == "_class_prepare", "expected internal event, got: %s", name);
	};
}

fn void vm_start_event() @test {
	@pool() {
		IdManager mgr;
		mgr.init();
		defer {
			mgr.thread_to_dap.free();
			mgr.dap_to_thread.free();
			mgr.dap_to_frame.free();
			mgr.dap_to_var.free();
		}

		JdwpEvent event;
		event.event_kind = protocol::EK_VM_START;
		event.thread_id = 1;

		Object* body = object::new_obj(tmem);
		String name = events::event_to_dap(&event, &mgr, body);
		assert(name == "thread", "expected 'thread', got: %s", name);

		String reason = body.get_string("reason") ?? "";
		assert(reason == "started", "got: %s", reason);
	};
}

fn void unknown_event_returns_empty() @test {
	@pool() {
		IdManager mgr;
		mgr.init();
		defer {
			mgr.thread_to_dap.free();
			mgr.dap_to_thread.free();
			mgr.dap_to_frame.free();
			mgr.dap_to_var.free();
		}

		JdwpEvent event;
		event.event_kind = 255;  // unknown

		Object* body = object::new_obj(tmem);
		String name = events::event_to_dap(&event, &mgr, body);
		assert(name == "", "expected empty for unknown event, got: %s", name);
	};
}
