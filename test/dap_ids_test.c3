module kls::test::dap_ids_test;

import kls::dap::jdwp::ids;

// ── IdManager init ─────────────────────────────────────────────────

fn void init_starts_at_one() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	assert(mgr.next_thread_id == 1, "expected next_thread_id=1, got %d", mgr.next_thread_id);
	assert(mgr.next_frame_id == 1, "expected next_frame_id=1, got %d", mgr.next_frame_id);
	assert(mgr.next_var_ref == 1, "expected next_var_ref=1, got %d", mgr.next_var_ref);
}

// ── Thread ID mapping ──────────────────────────────────────────────

fn void thread_id_creates_new_mapping() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	int dap1 = mgr.get_or_create_thread_id(100);
	assert(dap1 == 1, "expected dap_id=1, got %d", dap1);

	int dap2 = mgr.get_or_create_thread_id(200);
	assert(dap2 == 2, "expected dap_id=2, got %d", dap2);
}

fn void thread_id_returns_same_on_repeat() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	int dap1 = mgr.get_or_create_thread_id(100);
	int dap2 = mgr.get_or_create_thread_id(100);
	assert(dap1 == dap2, "expected same dap_id, got %d and %d", dap1, dap2);
}

fn void thread_id_roundtrip() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	int dap_id = mgr.get_or_create_thread_id(42);
	long jdwp_id = mgr.get_jdwp_thread_id(dap_id)!!;
	assert(jdwp_id == 42, "expected jdwp_id=42, got %d", (int)jdwp_id);
}

fn void thread_id_unknown_returns_fault() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	if (catch mgr.get_jdwp_thread_id(999)) {
		return;  // expected
	}
	assert(false, "expected fault for unknown dap thread id");
}

// ── Frame ID mapping ───────────────────────────────────────────────

fn void frame_id_roundtrip() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	FrameRef ref = { .thread_id = 1, .frame_id = 10, .class_id = 20, .method_id = 30, .location = 40 };
	int dap_id = mgr.register_frame(ref);
	assert(dap_id == 1, "expected frame dap_id=1, got %d", dap_id);

	FrameRef got = mgr.get_frame(dap_id)!!;
	assert(got.thread_id == 1);
	assert(got.frame_id == 10);
	assert(got.class_id == 20);
	assert(got.method_id == 30);
	assert(got.location == 40);
}

fn void frame_id_sequential() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	FrameRef ref1 = { .thread_id = 1, .frame_id = 10 };
	FrameRef ref2 = { .thread_id = 1, .frame_id = 20 };
	int id1 = mgr.register_frame(ref1);
	int id2 = mgr.register_frame(ref2);
	assert(id1 == 1);
	assert(id2 == 2);
}

// ── Variable reference mapping ─────────────────────────────────────

fn void var_ref_roundtrip() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	VarRef ref = { .thread_id = 1, .frame_id = 2, .scope = ScopeKind.LOCALS, .object_id = 0 };
	int dap_id = mgr.register_var_ref(ref);
	assert(dap_id == 1);

	VarRef got = mgr.get_var_ref(dap_id)!!;
	assert(got.thread_id == 1);
	assert(got.frame_id == 2);
	assert(got.scope == ScopeKind.LOCALS);
}

// ── clear_transient ────────────────────────────────────────────────

fn void clear_transient_keeps_threads() @test {
	IdManager mgr;
	mgr.init();
	defer {
		mgr.thread_to_dap.free();
		mgr.dap_to_thread.free();
		mgr.dap_to_frame.free();
		mgr.dap_to_var.free();
	}

	// Create thread + frame + var mappings
	int tid = mgr.get_or_create_thread_id(100);
	FrameRef fref = { .thread_id = 100, .frame_id = 10 };
	int fid = mgr.register_frame(fref);
	VarRef vref = { .thread_id = 100, .frame_id = 10, .scope = ScopeKind.LOCALS };
	int vid = mgr.register_var_ref(vref);

	mgr.clear_transient();

	// Thread still there
	long jdwp = mgr.get_jdwp_thread_id(tid)!!;
	assert(jdwp == 100, "thread mapping should survive clear_transient");

	// Frame gone
	if (catch mgr.get_frame(fid)) {
		// expected
	} else {
		assert(false, "frame should be cleared");
	}

	// Var gone
	if (catch mgr.get_var_ref(vid)) {
		// expected
	} else {
		assert(false, "var ref should be cleared");
	}

	// IDs reset
	assert(mgr.next_frame_id == 1, "frame id should reset");
	assert(mgr.next_var_ref == 1, "var ref should reset");
}
