module kls::dap::attach;

import kls::log;
import kls::dap::jdwp::transport;
import std::collections::object;

faultdef ATTACH_FAILED, MISSING_HOST_PORT;

struct AttachConfig {
	String host;
	int port;
}

// Parse attach arguments from DAP attach request
fn AttachConfig parse_attach_args(Object* args) {
	AttachConfig config;
	if (args == null) return config;

	config.host = args.get_string("host") ?? "";
	if (config.host.len == 0) {
		config.host = args.get_string("hostName") ?? "127.0.0.1";
	}
	config.port = (int)(args.get_int("port") ?? 5005);
	return config;
}

// Attach to existing JDWP agent
fn JdwpConnection? attach_and_connect(AttachConfig* config) {
	if (config.port == 0) {
		return MISSING_HOST_PORT~;
	}

	log::info("[dap] Attaching to %s:%d...", config.host, config.port);
	return transport::connect(config.host, config.port);
}
