module kls;

import kls::server;
import kls::dap::server;
import kls::log;
import std::io;

fn void main(String[] args) {
	bool dap_mode = false;
	foreach (arg : args) {
		if (arg == "--dap") {
			dap_mode = true;
		}
		if (arg == "--debug") {
			log::set_level(log::LogLevel.DEBUG);
		}
	}

	if (dap_mode) {
		log::info("[kls] Debug Adapter starting...");
		DapServer* ds = mem::new(DapServer);
		ds.init();
		ds.run();
	} else {
		log::info("[kls] Kotlin Language Server starting...");
		Server s;
		s.init();
		s.run();
	}
}
