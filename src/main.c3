module kls;

import kls::server;
import std::io;

fn void main() {
	io::eprintfn("[kls] Kotlin Language Server starting...");
	Server s;
	s.init();
	s.run();
}
