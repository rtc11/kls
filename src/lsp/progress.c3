module kls::lsp::progress;

import std::io;
import std::collections::object;
import kls::json_rpc;
import kls::log;

// Whether the client supports window/workDoneProgress.
// Set during initialize from client capabilities.
bool client_supports_progress = false;

/**
 * Set whether the client supports work done progress.
 * Called during initialize with the extracted client capability.
 */
fn void set_client_support(bool supported) {
	client_supports_progress = supported;
}

/**
 * Create a progress token with the client via window/workDoneProgress/create.
 * Sends the request without blocking for the response. The response will
 * arrive later and be silently ignored by the main dispatch loop (messages
 * without a "method" field are discarded).
 * No-op if the client does not support progress.
 */
fn void create(String token) {
	if (!client_supports_progress) return;

	Object* params = object::new_obj(tmem);
	params.set("token", token);

	json_rpc::send_request("window/workDoneProgress/create", params);
	log::debug("[kls] Sent workDoneProgress/create (token=%s)", token);
}

/**
 * Send $/progress begin notification.
 */
fn void begin(String token, String title, int percentage) {
	if (!client_supports_progress) return;

	Object* value = object::new_obj(tmem);
	value.set("kind", "begin");
	value.set("title", title);
	value.set("cancellable", false);
	if (percentage >= 0) {
		value.set("percentage", percentage);
	}

	Object* params = object::new_obj(tmem);
	params.set("token", token);
	params.set("value", value);

	json_rpc::send_notification("$/progress", params);
}

/**
 * Send $/progress report notification.
 */
fn void report(String token, String message, int percentage) {
	if (!client_supports_progress) return;

	Object* value = object::new_obj(tmem);
	value.set("kind", "report");
	if (message.len > 0) {
		value.set("message", message);
	}
	if (percentage >= 0) {
		value.set("percentage", percentage);
	}

	Object* params = object::new_obj(tmem);
	params.set("token", token);
	params.set("value", value);

	json_rpc::send_notification("$/progress", params);
}

/**
 * Send $/progress end notification.
 */
fn void end(String token, String message) {
	if (!client_supports_progress) return;

	Object* value = object::new_obj(tmem);
	value.set("kind", "end");
	if (message.len > 0) {
		value.set("message", message);
	}

	Object* params = object::new_obj(tmem);
	params.set("token", token);
	params.set("value", value);

	json_rpc::send_notification("$/progress", params);
}
