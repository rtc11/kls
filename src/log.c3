module kls::log;

import std::io;

enum LogLevel : int {
	DEBUG,
	INFO,
	WARN,
	ERROR,
}

LogLevel current_level = DEBUG;

fn void set_level(LogLevel level) {
	current_level = level;
}

macro void debug(format, ...) {
	if (current_level <= DEBUG) {
		io::eprintfn(format, $vasplat);
	}
}

macro void info(format, ...) {
	if (current_level <= INFO) {
		io::eprintfn(format, $vasplat);
	}
}

macro void warn(format, ...) {
	if (current_level <= WARN) {
		io::eprintfn(format, $vasplat);
	}
}

macro void err(format, ...) {
	if (current_level <= ERROR) {
		io::eprintfn(format, $vasplat);
	}
}
