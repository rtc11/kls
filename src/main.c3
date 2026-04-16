module kls;

import kls::server;
import std::io;

fn void main() {
	log::info("[kls] Kotlin Language Server starting...");
	Server s;
	s.init();
	s.run();
}
