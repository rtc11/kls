module kls::dap::server;

import std::io;
import std::encoding::json;
import std::collections::object;
import std::net;
import std::os::process;
import std::thread;
import kls::log;
import kls::json_rpc;
import kls::dap::types;
import kls::dap::lifecycle;
import kls::dap::launch;
import kls::dap::attach;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;
import kls::dap::breakpoints;
import kls::dap::execution;
import kls::dap::events;
import kls::dap::threads;
import kls::dap::stacktrace;
import kls::dap::variables;
import kls::dap::evaluate;
import kls::deps::classpath;

struct DapServer {
	bool is_running;
	bool is_initialized;
	bool is_connected;       // JDWP connection active
	bool has_process;        // debuggee process owned by us
	int seq;                 // monotonic sequence number for server messages
	JdwpConnection conn;     // JDWP connection to debuggee
	Process proc;            // debuggee process (if launched)
	IdManager id_mgr;        // JDWP<->DAP ID mappings
	Classpath classpath;     // resolved project classpath
	BreakpointManager bp_mgr; // breakpoint tracking
	ExceptionBpManager exc_mgr; // exception breakpoint tracking
	String workspace_path;   // project root (heap-copied)
}

fn void DapServer.init(DapServer* self) {
	self.is_running = false;
	self.is_initialized = false;
	self.is_connected = false;
	self.has_process = false;
	self.seq = 0;
	self.id_mgr.init();
	self.bp_mgr.init();
	self.exc_mgr.init();
}

fn void DapServer.run(DapServer* self) {
	self.is_running = true;
	log::set_level(log::LogLevel.DEBUG);
	log::info("[dap] Debug adapter ready, waiting for messages on stdin...");

	while (self.is_running) {
		@pool() {
			if (self.is_connected) {
				self.poll_loop_iteration();
			} else {
				// Before connection: just read stdin (blocking)
				if (catch excuse = self.run_one_message()) {
					if (excuse == json_rpc::UNEXPECTED_EOF) {
						log::info("[dap] stdin closed, shutting down");
						self.is_running = false;
					} else {
						log::err("[dap] Error processing message: %s", excuse);
					}
				}
			}
		};
	}

	// Cleanup
	if (self.is_connected) {
		self.conn.close();
	}
	if (self.has_process) {
		(void)self.proc.destroy();
		self.has_process = false;
	}
}

// Poll stdin + JDWP socket + process output
fn void DapServer.poll_loop_iteration(DapServer* self) {
	// Build poll array: [0]=stdin, [1]=JDWP socket
	NativeSocket stdin_sock = (NativeSocket)io::stdin().fd();
	NativeSocket jdwp_sock = self.conn.socket.sock;

	Poll[2] polls;
	polls[0].socket = stdin_sock;
	polls[0].events = net::SUBSCRIBE_ANY_READ;
	polls[0].revents = (PollEvent)0;
	polls[1].socket = jdwp_sock;
	polls[1].events = net::SUBSCRIBE_ANY_READ;
	polls[1].revents = (PollEvent)0;

	// Poll with 50ms timeout (allows process output draining)
	ulong ready = net::poll_ms(polls[..], 50) ?? 0;

	// Check stdin for DAP messages
	if (ready > 0 && ((ushort)polls[0].revents & (ushort)net::SUBSCRIBE_ANY_READ) != 0) {
		if (catch excuse = self.run_one_message()) {
			if (excuse == json_rpc::UNEXPECTED_EOF) {
				log::info("[dap] stdin closed, shutting down");
				self.is_running = false;
				return;
			} else {
				log::err("[dap] Error processing message: %s", excuse);
			}
		}
	}

	// Check JDWP socket for events (also check buffered events from read_reply)
	if (self.is_connected && self.conn.has_buffered_events()) {
		log::info("[dap] Processing buffered JDWP events...");
		while (self.is_connected && self.conn.has_buffered_events()) {
			self.handle_jdwp_event();
		}
	} else if (ready > 0 && ((ushort)polls[1].revents & (ushort)net::SUBSCRIBE_ANY_READ) != 0) {
		log::info("[dap] JDWP socket readable, reading event...");
		self.handle_jdwp_event();
	}

	// Check for disconnect on JDWP socket — but only if we didn't just handle an event
	// (disconnect flag can be spurious during normal operation)
	if (ready > 0 && !self.is_connected) {
		// Already disconnected from event handling
	} else if (ready > 0 && ((ushort)polls[1].revents & (ushort)net::POLL_EVENT_DISCONNECT) != 0
		&& ((ushort)polls[1].revents & (ushort)net::SUBSCRIBE_ANY_READ) == 0) {
		// Only treat as disconnect if there's NO readable data (pure hangup)
		log::info("[dap] JDWP poll disconnect detected, revents=%d", (int)(ushort)polls[1].revents);
		log::info("[dap] JDWP connection closed by VM");
		self.is_connected = false;
		self.send_event("terminated", null);
	}

	// Drain debuggee stdout/stderr
	if (self.has_process) {
		self.drain_process_output();
	}
}

// Read and handle a JDWP event from the socket
fn void DapServer.handle_jdwp_event(DapServer* self) {
	if (try event = events::read_event(&self.conn)) {
		Object* body = object::new_obj(tmem);
		String event_name = events::event_to_dap(&event, &self.id_mgr, body);

		log::info("[dap] JDWP event: kind=%d -> DAP event=%s", (int)event.event_kind, event_name);

		if (event_name == "_class_prepare") {
			// Resolve pending breakpoints for this class
			self.handle_class_prepare(&event);
			// Resume VM — CLASS_PREPARE suspends with SP_ALL
			if (catch excuse = protocol::resume_vm(&self.conn)) {
				log::err("[dap] Failed to resume VM after class prepare: %s", excuse);
			}
		} else if (event_name.len > 0) {
			self.send_event(event_name, body);

			// On VM death, mark disconnected
			if (event.event_kind == protocol::EK_VM_DEATH) {
				self.is_connected = false;
				// Also send exited event
				Object* exit_body = object::new_obj(tmem);
				exit_body.set("exitCode", 0);
				self.send_event("exited", exit_body);
			}
		}
	} else {
		log::debug("[dap] Failed to read JDWP event");
	}
}

// Handle CLASS_PREPARE: resolve pending breakpoints, send verified events
fn void DapServer.handle_class_prepare(DapServer* self, JdwpEvent* event) {
	log::info("[dap] CLASS_PREPARE: sig=%s class_id=%d", event.class_signature, event.class_id);

	breakpoints::DapBreakpointUpdate[64] updates;
	usz update_count = 0;

	breakpoints::resolve_pending_breakpoints(
		&self.bp_mgr, &self.conn, event.class_signature,
		event.class_id, event.type_tag, updates[..], &update_count);

	// Send DAP breakpoint changed events for each verified breakpoint
	for (usz i = 0; i < update_count; i++) {
		Object* bp_body = object::new_obj(tmem);
		bp_body.set("reason", "changed");

		Object* bp_obj = object::new_obj(tmem);
		bp_obj.set("id", updates[i].dap_id);
		bp_obj.set("verified", true);
		bp_obj.set("line", updates[i].line);

		Object* src = object::new_obj(tmem);
		src.set("path", updates[i].source_path);
		bp_obj.set("source", src);

		bp_body.set("breakpoint", bp_obj);
		self.send_event("breakpoint", bp_body);
	}
}

// Drain debuggee stdout/stderr and send as DAP output events
fn void DapServer.drain_process_output(DapServer* self) {
	char[4096] out_buf;
	char[4096] err_buf;

	// Drain stdout
	sz n_out = self.proc.read_stdout(&out_buf, out_buf.len) ?? 0;
	if (n_out > 0) {
		Object* body = object::new_obj(tmem);
		body.set("category", "stdout");
		body.set("output", (String)out_buf[:(usz)n_out]);
		self.send_event("output", body);
	}

	// Drain stderr
	sz n_err = self.proc.read_stderr(&err_buf, err_buf.len) ?? 0;
	if (n_err > 0) {
		Object* body = object::new_obj(tmem);
		body.set("category", "stderr");
		body.set("output", (String)err_buf[:(usz)n_err]);
		self.send_event("output", body);
	}
}

fn void? DapServer.run_one_message(DapServer* self) {
	log::info("[dap] Waiting for message...");
	String raw = json_rpc::read_message()!;

	log::info("[dap] Received: %s", raw);

	Object* msg = json::tparse_string(raw)!;
	self.dispatch(msg);
}

fn void DapServer.dispatch(DapServer* self, Object* msg) {
	String msg_type = msg.get_string("type") ?? "unknown";

	if (msg_type != "request") {
		log::debug("[dap] Ignoring non-request message type: %s", msg_type);
		return;
	}

	int request_seq = (int)(msg.get_int("seq") ?? 0);
	String command = msg.get_string("command") ?? "";
	Object* args = msg.get("arguments") ?? null;

	log::info("[dap] Request: %s (seq=%d)", command, request_seq);

	switch (command) {
		case "initialize":
			Object* body = lifecycle::handle_initialize(args);
			self.send_response(request_seq, command, body);
			self.send_event("initialized", null);
			self.is_initialized = true;

		case "configurationDone":
			if (self.is_connected) {
				if (catch excuse = protocol::resume_vm(&self.conn)) {
					log::err("[dap] Failed to resume VM: %s", excuse);
				}
			}
			self.send_response(request_seq, command, object::new_obj(tmem));

		case "launch":
			self.handle_launch(request_seq, command, args);

		case "attach":
			self.handle_attach(request_seq, command, args);

		case "disconnect":
			bool should_terminate = true;
			if (args != null) {
				if (try val = args.get_bool("terminateDebuggee")) {
					should_terminate = val;
				}
			}
			if (self.is_connected) {
				if (should_terminate) {
					if (catch excuse = protocol::exit_vm(&self.conn, 0)) {
						log::debug("[dap] Error during VM exit on disconnect: %s", excuse);
					}
				}
				self.conn.close();
				self.is_connected = false;
			}
			if (self.has_process && should_terminate) {
				(void)self.proc.destroy();
				self.has_process = false;
			}
			self.send_response(request_seq, command, object::new_obj(tmem));
			self.is_running = false;

		case "terminate":
			if (self.is_connected) {
				if (catch excuse = protocol::exit_vm(&self.conn, 1)) {
					log::debug("[dap] Error during VM exit on terminate: %s", excuse);
				}
				self.conn.close();
				self.is_connected = false;
			}
			if (self.has_process) {
				(void)self.proc.destroy();
				self.has_process = false;
			}
			self.send_response(request_seq, command, object::new_obj(tmem));
			self.send_event("terminated", null);

		case "setBreakpoints":
			if (self.is_connected && args != null) {
				Object* body = breakpoints::handle_set_breakpoints(&self.bp_mgr, &self.conn, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_response(request_seq, command, breakpoints::build_empty_response());
			}

		case "setExceptionBreakpoints":
			if (self.is_connected && args != null) {
				Object* body = breakpoints::handle_set_exception_breakpoints(&self.exc_mgr, &self.conn, args);
				self.send_response(request_seq, command, body);
			} else {
				Object* body = object::new_obj(tmem);
				body.set("breakpoints", object::new_obj(tmem));
				self.send_response(request_seq, command, body);
			}

		case "continue":
			if (self.is_connected && args != null) {
				Object* body = execution::handle_continue(&self.conn, &self.id_mgr, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Not connected");
			}

		case "next":
			if (self.is_connected && args != null) {
				Object* body = execution::handle_next(&self.conn, &self.id_mgr, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Not connected");
			}

		case "stepIn":
			if (self.is_connected && args != null) {
				Object* body = execution::handle_step_in(&self.conn, &self.id_mgr, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Not connected");
			}

		case "stepOut":
			if (self.is_connected && args != null) {
				Object* body = execution::handle_step_out(&self.conn, &self.id_mgr, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Not connected");
			}

		case "pause":
			if (self.is_connected && args != null) {
				Object* body = execution::handle_pause(&self.conn, &self.id_mgr, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Not connected");
			}

		case "threads":
			if (self.is_connected) {
				Object* body = threads::handle_threads(&self.conn, &self.id_mgr);
				self.send_response(request_seq, command, body);
			} else {
				Object* body = object::new_obj(tmem);
				body.set("threads", object::new_obj(tmem));
				self.send_response(request_seq, command, body);
			}

		case "stackTrace":
			if (self.is_connected && args != null) {
				Object* body = stacktrace::handle_stack_trace(&self.conn, &self.id_mgr, args, self.workspace_path);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Not connected");
			}

		case "scopes":
			if (args != null) {
				Object* body = variables::handle_scopes(&self.id_mgr, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Missing args");
			}

		case "variables":
			if (self.is_connected && args != null) {
				Object* body = variables::handle_variables(&self.conn, &self.id_mgr, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Not connected");
			}

		case "evaluate":
			if (self.is_connected && args != null) {
				Object* body = evaluate::handle_evaluate(&self.conn, &self.id_mgr, args);
				self.send_response(request_seq, command, body);
			} else {
				self.send_error_response(request_seq, command, "Not connected");
			}

		default:
			self.send_error_response(request_seq, command, "Unsupported command");
	}
}

fn void DapServer.handle_launch(DapServer* self, int request_seq, String command, Object* args) {
	LaunchConfig config = launch::parse_launch_args(args);

	if (config.workspace_path.len > 0) {
		self.workspace_path = config.workspace_path.copy(mem);
	}

	LaunchResult result_val;
	bool launched = false;

	if (config.mode == LaunchMode.GRADLE_TEST) {
		log::info("[dap] Launch mode: gradle test (module=%s)", config.gradle_module);
		if (try result = launch::launch_gradle_test(&config)) {
			result_val = result;
			launched = true;
		}
	} else {
		classpath::resolve_classpath(&self.classpath, self.workspace_path, "");
		if (try result = launch::launch_and_connect(&config, &self.classpath)) {
			result_val = result;
			launched = true;
		}
	}

	if (launched) {
		self.conn = result_val.conn;
		self.proc = result_val.proc;
		self.is_connected = true;
		self.has_process = true;

		if (try sizes = protocol::query_id_sizes(&self.conn)) {
			self.id_mgr.id_sizes = sizes;
			log::info("[dap] ID sizes: field=%d method=%d obj=%d ref=%d frame=%d",
				sizes.field_id_size, sizes.method_id_size, sizes.object_id_size,
				sizes.reference_type_id_size, sizes.frame_id_size);
		}

		self.send_response(request_seq, command, object::new_obj(tmem));

		Object* proc_body = object::new_obj(tmem);
		proc_body.set("name", config.mode == LaunchMode.GRADLE_TEST ? config.gradle_module : config.main_class);
		proc_body.set("startMethod", "launch");
		self.send_event("process", proc_body);
	} else {
		String msg = config.mode == LaunchMode.GRADLE_TEST
			? "Failed to launch gradle test"
			: "Failed to launch and connect to JVM";
		self.send_error_response(request_seq, command, msg);
	}
}

fn void DapServer.handle_attach(DapServer* self, int request_seq, String command, Object* args) {
	AttachConfig config = attach::parse_attach_args(args);

	if (try conn = attach::attach_and_connect(&config)) {
		self.conn = conn;
		self.is_connected = true;

		if (try sizes = protocol::query_id_sizes(&self.conn)) {
			self.id_mgr.id_sizes = sizes;
		}

		self.send_response(request_seq, command, object::new_obj(tmem));

		Object* proc_body = object::new_obj(tmem);
		proc_body.set("startMethod", "attach");
		self.send_event("process", proc_body);
	} else {
		self.send_error_response(request_seq, command, "Failed to attach to JVM");
	}
}

// ── DAP message senders ────────────────────────────────────────────

fn void DapServer.send_response(DapServer* self, int request_seq, String command, Object* body) {
	self.seq++;
	Object* response = object::new_obj(tmem);
	response.set("seq", self.seq);
	response.set("type", "response");
	response.set("request_seq", request_seq);
	response.set("success", true);
	response.set("command", command);
	if (body != null) {
		response.set("body", body);
	}
	json_rpc::write_message(response);
}

fn void DapServer.send_error_response(DapServer* self, int request_seq, String command, String message) {
	self.seq++;
	Object* response = object::new_obj(tmem);
	response.set("seq", self.seq);
	response.set("type", "response");
	response.set("request_seq", request_seq);
	response.set("success", false);
	response.set("command", command);
	response.set("message", message);
	json_rpc::write_message(response);
}

fn void DapServer.send_event(DapServer* self, String event, Object* body) {
	self.seq++;
	Object* msg = object::new_obj(tmem);
	msg.set("seq", self.seq);
	msg.set("type", "event");
	msg.set("event", event);
	if (body != null) {
		msg.set("body", body);
	}
	json_rpc::write_message(msg);
}
