module kls::dap::jdwp::ids;

import std::collections;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::transport;

// Maps between JDWP long IDs and DAP integer IDs.
// DAP uses int IDs for threads, frames, variables references.
// JDWP uses 8-byte IDs for everything.

struct IdManager {
	// JDWP long -> DAP int mappings
	HashMap{long, int} thread_to_dap;
	HashMap{int, long} dap_to_thread;
	int next_thread_id;

	// Frame IDs: compound key = thread_id + frame_index -> DAP frame id
	HashMap{int, FrameRef} dap_to_frame;
	int next_frame_id;

	// Variables references: DAP int -> (thread, frame, scope type)
	HashMap{int, VarRef} dap_to_var;
	int next_var_ref;

	// ID sizes from VM
	IdSizes id_sizes;
}

struct FrameRef {
	long thread_id;
	long frame_id;
	long class_id;
	long method_id;
	long location;
}

enum ScopeKind : char {
	LOCALS,
	ARGUMENTS,
	THIS_OBJECT,
	STATIC_FIELDS,
}

struct VarRef {
	long thread_id;
	long frame_id;
	ScopeKind scope;
	long object_id;   // for expanding object fields (0 = use scope)
	long class_id;    // for variable table lookup
	long method_id;   // for variable table lookup
	long location;    // bytecode index for variable scope filtering
}

fn void IdManager.init(IdManager* self) {
	self.thread_to_dap.init(mem);
	self.dap_to_thread.init(mem);
	self.next_thread_id = 1;

	self.dap_to_frame.init(mem);
	self.next_frame_id = 1;

	self.dap_to_var.init(mem);
	self.next_var_ref = 1;

	self.id_sizes = protocol::default_id_sizes();
}

// ── Thread ID mapping ──────────────────────────────────────────────

fn int IdManager.get_or_create_thread_id(IdManager* self, long jdwp_thread_id) {
	if (try dap_id = self.thread_to_dap.get(jdwp_thread_id)) {
		return dap_id;
	}
	int dap_id = self.next_thread_id;
	self.next_thread_id++;
	self.thread_to_dap.set(jdwp_thread_id, dap_id);
	self.dap_to_thread.set(dap_id, jdwp_thread_id);
	return dap_id;
}

fn long? IdManager.get_jdwp_thread_id(IdManager* self, int dap_thread_id) {
	return self.dap_to_thread.get(dap_thread_id);
}

// ── Frame ID mapping ───────────────────────────────────────────────

fn int IdManager.register_frame(IdManager* self, FrameRef ref) {
	int dap_id = self.next_frame_id;
	self.next_frame_id++;
	self.dap_to_frame.set(dap_id, ref);
	return dap_id;
}

fn FrameRef? IdManager.get_frame(IdManager* self, int dap_frame_id) {
	return self.dap_to_frame.get(dap_frame_id);
}

// ── Variable reference mapping ─────────────────────────────────────

fn int IdManager.register_var_ref(IdManager* self, VarRef ref) {
	int dap_id = self.next_var_ref;
	self.next_var_ref++;
	self.dap_to_var.set(dap_id, ref);
	return dap_id;
}

fn VarRef? IdManager.get_var_ref(IdManager* self, int dap_var_ref) {
	return self.dap_to_var.get(dap_var_ref);
}

// ── Reset per-stop mappings ────────────────────────────────────────
// Call on each continue/step to clear stale frame/var refs

fn void IdManager.clear_transient(IdManager* self) {
	// Keep thread mappings, clear frame + var refs
	self.dap_to_frame.clear();
	self.next_frame_id = 1;
	self.dap_to_var.clear();
	self.next_var_ref = 1;
}
