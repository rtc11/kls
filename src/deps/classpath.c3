module kls::deps::classpath;

import std::io;
import std::io::file;
import std::io::path;
import kls::log;
import std::os::env;
import std::os::process;
import std::thread;
import kls::lsp::progress;

// ── Build system detection ─────────────────────────────────────────

enum BuildSystem : int {
	NONE,
	GRADLE,
	MAVEN,
}

// ── Dependency JAR entry ───────────────────────────────────────────

struct DependencyJar {
	String path;             // heap-copied full path to the JAR
	String source_jar_path;  // heap-copied path to -sources.jar (empty if not found)
	String group_id;         // heap-copied (empty if unknown)
	String artifact_id;      // heap-copied (empty if unknown)
	String version;          // heap-copied (empty if unknown)
}

// ── Gradle module ──────────────────────────────────────────────────

const usz MAX_MODULE_SRC_ROOTS = 8;
const usz MAX_MODULE_DEPS = 16;
const usz MAX_MODULES = 32;

struct GradleModule {
	String name;                               // heap-copied, e.g. ":core", ":app"
	String dir;                                // heap-copied, absolute path to module dir
	String[MAX_MODULE_SRC_ROOTS] src_roots;    // heap-copied source root paths
	usz src_root_count;
	String[MAX_MODULE_DEPS] dep_modules;       // heap-copied dependency module names
	usz dep_module_count;
	usz jar_start;                             // index into Classpath.jars
	usz jar_count;                             // number of JARs belonging to this module
}

// ── Classpath ──────────────────────────────────────────────────────

struct Classpath {
	BuildSystem build_system;
	DependencyJar[256] jars;
	usz jar_count;
	bool resolved;
	GradleModule[MAX_MODULES] modules;
	usz module_count;
}

fn void Classpath.init(Classpath* self) {
	self.build_system = NONE;
	self.jar_count = 0;
	self.resolved = false;
	self.module_count = 0;
}

fn void Classpath.free(Classpath* self) {
	for (usz i = 0; i < self.jar_count; i++) {
		DependencyJar* jar = &self.jars[i];
		if (jar.path.len > 0) mem::free(jar.path.ptr);
		if (jar.source_jar_path.len > 0) mem::free(jar.source_jar_path.ptr);
		if (jar.group_id.len > 0) mem::free(jar.group_id.ptr);
		if (jar.artifact_id.len > 0) mem::free(jar.artifact_id.ptr);
		if (jar.version.len > 0) mem::free(jar.version.ptr);
	}
	self.jar_count = 0;
	for (usz i = 0; i < self.module_count; i++) {
		GradleModule* m = &self.modules[i];
		if (m.name.len > 0) mem::free(m.name.ptr);
		if (m.dir.len > 0) mem::free(m.dir.ptr);
		for (usz j = 0; j < m.src_root_count; j++) {
			if (m.src_roots[j].len > 0) mem::free(m.src_roots[j].ptr);
		}
		for (usz j = 0; j < m.dep_module_count; j++) {
			if (m.dep_modules[j].len > 0) mem::free(m.dep_modules[j].ptr);
		}
	}
	self.module_count = 0;
	self.resolved = false;
}

/**
 * Find a module by name. Returns null if not found.
 */
fn GradleModule* Classpath.find_module(Classpath* self, String name) {
	for (usz i = 0; i < self.module_count; i++) {
		if (self.modules[i].name == name) return &self.modules[i];
	}
	return null;
}

/**
 * Find which module a file path belongs to, by matching against
 * module source roots. Returns null if no module matches.
 */
fn GradleModule* Classpath.find_module_for_path(Classpath* self, String file_path) {
	for (usz i = 0; i < self.module_count; i++) {
		GradleModule* m = &self.modules[i];
		for (usz j = 0; j < m.src_root_count; j++) {
			if (m.src_roots[j].len > 0 && file_path.starts_with(m.src_roots[j])) {
				return m;
			}
		}
	}
	return null;
}

/**
 * Check if module `from` depends on module `target` (directly or transitively).
 * Uses a simple iterative BFS to avoid stack overflow on deep chains.
 */
fn bool Classpath.module_depends_on(Classpath* self, String from, String target) {
	if (from == target) return true;
	if (self.module_count == 0) return true; // no modules = single project, everything visible

	// BFS through dependency graph
	String[MAX_MODULES] queue;
	bool[MAX_MODULES] visited;
	usz q_head = 0;
	usz q_tail = 0;

	// Initialize visited
	for (usz i = 0; i < MAX_MODULES; i++) visited[i] = false;

	// Enqueue starting module's direct deps
	GradleModule* from_mod = self.find_module(from);
	if (from_mod == null) return true; // unknown module, be permissive
	for (usz i = 0; i < from_mod.dep_module_count; i++) {
		if (from_mod.dep_modules[i] == target) return true;
		if (q_tail < MAX_MODULES) {
			queue[q_tail] = from_mod.dep_modules[i];
			q_tail++;
		}
	}

	while (q_head < q_tail) {
		String current = queue[q_head];
		q_head++;

		// Find index for visited tracking
		usz mod_idx = MAX_MODULES;
		for (usz i = 0; i < self.module_count; i++) {
			if (self.modules[i].name == current) { mod_idx = i; break; }
		}
		if (mod_idx >= MAX_MODULES || visited[mod_idx]) continue;
		visited[mod_idx] = true;

		GradleModule* m = &self.modules[mod_idx];
		for (usz i = 0; i < m.dep_module_count; i++) {
			if (m.dep_modules[i] == target) return true;
			if (q_tail < MAX_MODULES) {
				queue[q_tail] = m.dep_modules[i];
				q_tail++;
			}
		}
	}

	return false;
}

// ── Build system detection ─────────────────────────────────────────

/**
 * Detect the build system used by the project at workspace_path.
 * Checks for Gradle files first (more common for Kotlin), then Maven.
 */
fn BuildSystem detect_build_system(String workspace_path) {
	if (workspace_path.len == 0) return NONE;

	@pool() {
		DString ds;
		ds.tinit();

		// Check for Gradle (Kotlin DSL first, then Groovy)
		ds.appendf("%s/build.gradle.kts", workspace_path);
		if (file::is_file(ds.str_view())) return GRADLE;

		ds.clear();
		ds.appendf("%s/build.gradle", workspace_path);
		if (file::is_file(ds.str_view())) return GRADLE;

		// Check for Gradle settings files (multi-module projects may only
		// have settings.gradle.kts at the root, not build.gradle.kts)
		ds.clear();
		ds.appendf("%s/settings.gradle.kts", workspace_path);
		if (file::is_file(ds.str_view())) return GRADLE;

		ds.clear();
		ds.appendf("%s/settings.gradle", workspace_path);
		if (file::is_file(ds.str_view())) return GRADLE;

		// Check for Maven
		ds.clear();
		ds.appendf("%s/pom.xml", workspace_path);
		if (file::is_file(ds.str_view())) return MAVEN;
	};

	return NONE;
}

// ── Main classpath resolution ──────────────────────────────────────

// Active progress token for reporting Gradle progress to LSP.
String active_progress_token = "kls-indexing";

/**
 * Detect the build system and resolve the full classpath.
 * This may run external processes (gradle/mvn) and can be slow.
 * progress_token is the LSP progress token to use for reporting.
 */
fn void resolve_classpath(Classpath* cp, String workspace_path, String progress_token = "kls-indexing") {
	active_progress_token = progress_token;
	cp.build_system = detect_build_system(workspace_path);

	log::info("[kls] Build system: %s", build_system_name(cp.build_system));

	switch (cp.build_system) {
		case GRADLE:
			resolve_gradle(cp, workspace_path);
		case MAVEN:
			resolve_maven(cp, workspace_path);
		case NONE:
			log::info("[kls] No build system detected, using stdlib only");
	}

	cp.resolved = true;
	log::info("[kls] Classpath resolved: %d JARs", (int)cp.jar_count);
}

fn String build_system_name(BuildSystem bs) {
	switch (bs) {
		case GRADLE: return "Gradle";
		case MAVEN:  return "Maven";
		case NONE:   return "None";
	}
}

// ── Gradle classpath resolution ────────────────────────────────────

/**
 * Resolve classpath from a Gradle project.
 * Runs the Gradle wrapper (or system gradle) with an init script
 * that prints the compileClasspath configuration.
 */
fn void resolve_gradle(Classpath* cp, String workspace_path) {
	// Try gradlew first, fall back to system gradle
	@pool() {
		DString gradlew;
		gradlew.tinit();
		gradlew.appendf("%s/gradlew", workspace_path);

		String gradle_cmd;
		if (file::is_file(gradlew.str_view())) {
			gradle_cmd = gradlew.str_view();
		} else {
			gradle_cmd = "gradle";
		}

		// Write a temporary init script
		String init_script = write_gradle_init_script();
		if (init_script.len == 0) {
			log::err("[kls] Failed to create Gradle init script");
			return;
		}
		defer {
			if (init_script.len > 0) mem::free(init_script.ptr);
		}

		// Change to workspace directory, run gradle, restore
		Path old_cwd;
		if (try cwd = path::tcwd()) {
			old_cwd = cwd;
		} else {
			log::err("[kls] Failed to get current directory");
			return;
		}

		if (catch excuse = path::chdir(workspace_path)) {
			log::err("[kls] Failed to chdir to workspace: %s", excuse);
			return;
		}

		String output = run_gradle_classpath(gradle_cmd, init_script, false);

		// If the first attempt failed or produced no output, retry with
		// --no-configuration-cache. This handles projects that enable the
		// Gradle configuration cache, which forbids Project access at
		// task execution time.
		if (output.len == 0 || !has_kls_output(output)) {
			log::info("[kls] Retrying with --no-configuration-cache");
			output = run_gradle_classpath(gradle_cmd, init_script, true);
		}

		// Restore working directory
		path::chdir(old_cwd)!!;

		// Parse output: lines starting with "KLS_JAR:" contain JAR paths
		parse_gradle_output(cp, output);
	};
}

/**
 * Run the Gradle klsClasspath task and capture stdout, streaming stderr
 * for progress reporting.
 * If no_config_cache is true, adds --no-configuration-cache flag.
 * Returns the captured output string (in temp memory).
 */
fn String run_gradle_classpath(String gradle_cmd, String init_script, bool no_config_cache) {
	String[] cmd;
	if (no_config_cache) {
		log::debug("[kls] Running: %s -I %s klsClasspath -q --no-configuration-cache", gradle_cmd, init_script);
		cmd = { gradle_cmd, "-I", init_script, "klsClasspath", "-q", "--no-configuration-cache" };
	} else {
		log::debug("[kls] Running: %s -I %s klsClasspath -q", gradle_cmd, init_script);
		cmd = { gradle_cmd, "-I", init_script, "klsClasspath", "-q" };
	}

	String result = run_gradle_streaming(cmd);
	if (result.len > 0) return result;

	// If the preferred command failed, try the system gradle fallback
	if (gradle_cmd != "gradle") {
		log::info("[kls] Gradle command failed, trying with 'gradle' fallback");
		if (no_config_cache) {
			cmd = { "gradle", "-I", init_script, "klsClasspath", "-q", "--no-configuration-cache" };
		} else {
			cmd = { "gradle", "-I", init_script, "klsClasspath", "-q" };
		}
		result = run_gradle_streaming(cmd);
		if (result.len > 0) return result;
		log::err("[kls] Gradle fallback also failed");
	}
	return "";
}

/**
 * Spawn a Gradle process and stream its output. Reads stderr for progress
 * messages (sent to LSP progress bar) and accumulates stdout for KLS_ lines.
 * Returns the captured stdout (in temp memory).
 */
fn String run_gradle_streaming(String[] cmd) {
	Process proc;
	if (try p = process::spawn(cmd, SpawnOptions.ASYNC_OUTPUT | SpawnOptions.INHERIT_ENV)) {
		proc = p;
	} else {
		return "";
	}
	defer (void)proc.destroy();

	// Accumulate stdout into a buffer
	char[65536] stdout_buf;
	usz stdout_len = 0;

	// Stderr read buffer for progress extraction
	char[4096] stderr_buf;
	// Line accumulation buffer for stderr (Gradle lines can be partial)
	char[512] stderr_line_buf;
	usz stderr_line_len = 0;

	while (true) {
		bool running = proc.is_running() ?? false;

		// Read any available stderr (progress messages)
		while (true) {
			sz n = proc.read_stderr(&stderr_buf, stderr_buf.len) ?? 0;
			if (n <= 0) break;
			// Process stderr bytes, extracting lines for progress
			for (usz i = 0; i < (usz)n; i++) {
				char c = stderr_buf[i];
				if (c == '\n' || c == '\r') {
					if (stderr_line_len > 0) {
						String line = (String)stderr_line_buf[:stderr_line_len];
						report_gradle_progress(line);
						stderr_line_len = 0;
					}
				} else if (stderr_line_len < stderr_line_buf.len) {
					stderr_line_buf[stderr_line_len] = c;
					stderr_line_len++;
				}
			}
		}

		// Read any available stdout (KLS_ output)
		while (stdout_len < stdout_buf.len) {
			sz n = proc.read_stdout(&stdout_buf[stdout_len], stdout_buf.len - stdout_len) ?? 0;
			if (n <= 0) break;
			stdout_len += (usz)n;
		}

		if (!running) break;
		thread::sleep_ms(100);
	}

	// Final drain of stdout after process exit
	while (stdout_len < stdout_buf.len) {
		sz n = proc.read_stdout(&stdout_buf[stdout_len], stdout_buf.len - stdout_len) ?? 0;
		if (n <= 0) break;
		stdout_len += (usz)n;
	}

	// Final drain of stderr
	while (true) {
		sz n = proc.read_stderr(&stderr_buf, stderr_buf.len) ?? 0;
		if (n <= 0) break;
		for (usz i = 0; i < (usz)n; i++) {
			char c = stderr_buf[i];
			if (c == '\n' || c == '\r') {
				if (stderr_line_len > 0) {
					String line = (String)stderr_line_buf[:stderr_line_len];
					report_gradle_progress(line);
					stderr_line_len = 0;
				}
			} else if (stderr_line_len < stderr_line_buf.len) {
				stderr_line_buf[stderr_line_len] = c;
				stderr_line_len++;
			}
		}
	}

	if (stdout_len == 0) return "";
	return (String)stdout_buf[:stdout_len];
}

/**
 * Extract a meaningful progress message from a Gradle stderr line
 * and send it to the LSP progress bar.
 */
fn void report_gradle_progress(String line) {
	if (line.len == 0) return;

	// Log all Gradle stderr to KLS log
	log::debug("[kls] gradle: %s", line);

	// Extract meaningful messages for the progress bar
	String message = "";

	if (line.starts_with("> Task ")) {
		// "> Task :app:klsClasspath" -> "Task :app:klsClasspath"
		message = line[2..];
	} else if (line.starts_with("Downloading ")) {
		// "Downloading https://..." -> show it
		message = line;
	} else if (line.starts_with("> ")) {
		// Generic Gradle status line
		message = line[2..];
	} else if (line.starts_with("BUILD SUCCESSFUL") || line.starts_with("BUILD FAILED")) {
		message = line;
	}

	if (message.len > 0) {
		// Truncate long messages for the progress bar
		if (message.len > 80) {
			message = message[:80];
		}
		progress::report(active_progress_token, message, 20);
	}
}

/**
 * Check if Gradle output contains any KLS_ lines (i.e., actual output from our task).
 */
fn bool has_kls_output(String output) {
	usz i = 0;
	while (i + 4 < output.len) {
		if (output[i] == 'K' && output[i+1] == 'L' && output[i+2] == 'S' && output[i+3] == '_') {
			return true;
		}
		i++;
	}
	return false;
}

/**
 * Write a temporary Gradle init script that prints the classpath.
 * Returns the heap-copied path to the script, or empty string on failure.
 * Caller must free the returned path.
 */
fn String write_gradle_init_script() {
	// Get temp directory
	DString path_ds;
	path_ds.tinit();

	if (try tmpdir = env::tget_var("TMPDIR")) {
		path_ds.appendf("%s/kls-gradle-init.gradle", tmpdir);
	} else {
		path_ds.appendf("/tmp/kls-gradle-init.gradle");
	}

	String script_path = path_ds.str_view();

	String script_content =
`allprojects {
    afterEvaluate {
        def modulePath = project.path
        def moduleDir = project.projectDir.absolutePath
        def srcDirs = []
        if (project.hasProperty("sourceSets")) {
            project.sourceSets.each { ss ->
                ss.allSource.srcDirs.each { dir ->
                    if (dir.exists()) srcDirs << dir.absolutePath
                }
            }
        }
        if (project.hasProperty("android")) {
            try {
                project.android.sourceSets.each { ss ->
                    ss.kotlin.srcDirs.each { dir ->
                        if (dir.exists()) srcDirs << dir.absolutePath
                    }
                    ss.java.srcDirs.each { dir ->
                        if (dir.exists()) srcDirs << dir.absolutePath
                    }
                }
            } catch (Exception e) {}
        }
        if (srcDirs.isEmpty()) {
            ["src/main/kotlin", "src/main/java", "src/test/kotlin", "src/test/java"].each {
                def d = new File(project.projectDir, it)
                if (d.exists()) srcDirs << d.absolutePath
            }
        }
        srcDirs = srcDirs.unique()
        def projectDeps = []
        ["implementation", "api", "compileOnly"].each { configName ->
            configurations.findByName(configName)?.dependencies?.each { dep ->
                if (dep instanceof org.gradle.api.artifacts.ProjectDependency) {
                    try {
                        def p = dep.path
                        if (p != null) { projectDeps << p; return }
                    } catch (Exception e) {}
                    try {
                        projectDeps << dep.dependencyProject.path
                    } catch (Exception e) {
                        projectDeps << ":" + dep.name
                    }
                }
            }
        }
        def jarFiles = []
        def cpConfig = configurations.findByName("compileClasspath")
        if (cpConfig != null && cpConfig.isCanBeResolved()) {
            try {
                jarFiles = cpConfig.resolve().collect { it.absolutePath }
            } catch (Exception e) {}
        }

        task klsClasspath {
            doLast {
                println "KLS_MODULE:" + modulePath + "|" + moduleDir
                srcDirs.each { println "KLS_SRC:" + it }
                projectDeps.unique().each { println "KLS_DEP:" + it }
                jarFiles.each { println "KLS_JAR:" + it }
            }
        }
    }
}
`;

	if (catch excuse = write_string_to_file(script_path, script_content)) {
		log::err("[kls] Failed to write init script: %s", excuse);
		return "";
	}

	return script_path.copy(mem);
}

/**
 * Parse Gradle output for KLS_MODULE:, KLS_SRC:, KLS_DEP:, and KLS_JAR: lines.
 *
 * Output format per subproject:
 *   KLS_MODULE:<gradle-path>|<absolute-dir>
 *   KLS_SRC:<absolute-source-root>
 *   KLS_DEP:<gradle-path-of-dependency>
 *   KLS_JAR:<absolute-jar-path>
 *
 * Lines for a module appear consecutively: MODULE first, then SRC/DEP/JAR lines
 * until the next MODULE line or end of output.
 */
fn void parse_gradle_output(Classpath* cp, String output) {
	if (output.len == 0) return;

	// Index of the current module being populated (-1 = none yet)
	sz cur_mod = -1;

	usz pos = 0;
	while (pos < output.len) {
		// Find end of current line
		usz line_end = pos;
		while (line_end < output.len && output[line_end] != '\n') {
			line_end++;
		}

		// #9: Guard against empty lines (line_end == pos) to prevent usz underflow
		String line = line_end > pos ? output[pos..line_end - 1] : "";
		if (line.len > 0 && line[line.len - 1] == '\r') {
			line = line[..line.len - 2];
		}

		if (line.starts_with("KLS_MODULE:")) {
			String rest = line["KLS_MODULE:".len..];
			// Split on '|' -> name|dir
			if (try pipe = find_substring(rest, "|")) {
				String mod_name = rest[:pipe];
				String mod_dir = rest[pipe + 1..];
				if (cp.module_count < MAX_MODULES && mod_name.len > 0) {
					cur_mod = (sz)cp.module_count;
					GradleModule* m = &cp.modules[cp.module_count];
					m.name = mod_name.copy(mem);
					m.dir = mod_dir.copy(mem);
					m.src_root_count = 0;
					m.dep_module_count = 0;
					m.jar_start = cp.jar_count;
					m.jar_count = 0;
					cp.module_count++;
				}
			}
		} else if (line.starts_with("KLS_SRC:") && cur_mod >= 0) {
			String src_path = line["KLS_SRC:".len..];
			GradleModule* m = &cp.modules[(usz)cur_mod];
			if (src_path.len > 0 && m.src_root_count < MAX_MODULE_SRC_ROOTS) {
				m.src_roots[m.src_root_count] = src_path.copy(mem);
				m.src_root_count++;
			}
		} else if (line.starts_with("KLS_DEP:") && cur_mod >= 0) {
			String dep_name = line["KLS_DEP:".len..];
			GradleModule* m = &cp.modules[(usz)cur_mod];
			if (dep_name.len > 0 && m.dep_module_count < MAX_MODULE_DEPS) {
				m.dep_modules[m.dep_module_count] = dep_name.copy(mem);
				m.dep_module_count++;
			}
		} else if (line.starts_with("KLS_JAR:")) {
			String jar_path = line["KLS_JAR:".len..];
			if (jar_path.len > 0 && cp.jar_count < 256) {
				if (add_jar(cp, jar_path)) {
					// Track this JAR as belonging to the current module
					if (cur_mod >= 0) {
						cp.modules[(usz)cur_mod].jar_count++;
					}
				}
			}
		}

		pos = line_end + 1;
	}

	if (cp.module_count > 0) {
		log::info("[kls] Discovered %d Gradle modules", (int)cp.module_count);
		for (usz i = 0; i < cp.module_count; i++) {
			GradleModule* m = &cp.modules[i];
			log::debug("[kls]   %s: %d src roots, %d deps, %d JARs",
				m.name, (int)m.src_root_count, (int)m.dep_module_count, (int)m.jar_count);
		}
	}
}

// ── Maven classpath resolution ─────────────────────────────────────

/**
 * Resolve classpath from a Maven project.
 * Runs mvn dependency:build-classpath to get the list of JARs.
 */
fn void resolve_maven(Classpath* cp, String workspace_path) {
	@pool() {
		log::debug("[kls] Running: mvn dependency:build-classpath -q");

		// Change to workspace directory
		Path old_cwd;
		if (try cwd = path::tcwd()) {
			old_cwd = cwd;
		} else {
			log::err("[kls] Failed to get current directory");
			return;
		}

		if (catch excuse = path::chdir(workspace_path)) {
			log::err("[kls] Failed to chdir to workspace: %s", excuse);
			return;
		}

		char[65536] buf;
		String output = "";
		if (try out = process::run_capture_stdout(&buf,
				{ "mvn", "dependency:build-classpath",
				  "-Dmdep.includeScope=compile",
				  "-Dmdep.outputFile=/dev/stdout", "-q" },
				SpawnOptions.INHERIT_ENV)) {
			output = out;
		} else {
			log::err("[kls] Maven command failed");
		}

		// Restore working directory
		path::chdir(old_cwd)!!;

		// Parse output: colon-separated JAR paths
		parse_maven_output(cp, output);
	};
}

/**
 * Parse Maven build-classpath output (colon-separated JAR paths).
 */
fn void parse_maven_output(Classpath* cp, String output) {
	if (output.len == 0) return;

	// Maven outputs the classpath on the last non-empty line.
	// Find it by scanning backwards.
	String classpath_line = "";
	usz pos = 0;
	while (pos < output.len) {
		usz line_end = pos;
		while (line_end < output.len && output[line_end] != '\n') {
			line_end++;
		}
		// #9: Guard against empty lines (line_end == pos) to prevent usz underflow
		String line = line_end > pos ? output[pos..line_end - 1] : "";
		if (line.len > 0 && line[line.len - 1] == '\r') {
			line = line[..line.len - 2];
		}
		// Skip empty lines and lines that look like Maven logging
		if (line.len > 0 && !line.starts_with("[")) {
			classpath_line = line;
		}
		pos = line_end + 1;
	}

	if (classpath_line.len == 0) return;

	// Split on ':' (path separator on Unix) or ';' (Windows)
	pos = 0;
	while (pos < classpath_line.len && cp.jar_count < 256) {
		usz sep = pos;
		while (sep < classpath_line.len && classpath_line[sep] != ':' && classpath_line[sep] != ';') {
			sep++;
		}

		String jar_path = sep > pos ? classpath_line[pos..sep - 1] : "";
		if (jar_path.len > 0 && jar_path.ends_with(".jar")) {
			add_jar(cp, jar_path);
		}

		pos = sep + 1;
	}
}

// ── JAR addition helper ────────────────────────────────────────────

/**
 * Add a JAR to the classpath. Derives source JAR path and
 * optionally extracts group/artifact/version from the path.
 */
fn bool add_jar(Classpath* cp, String jar_path) {
	if (cp.jar_count >= 256) return false;

	// Deduplicate: skip if we already have this JAR path
	for (usz i = 0; i < cp.jar_count; i++) {
		if (cp.jars[i].path == jar_path) return false;
	}

	// Derive source JAR path: replace .jar with -sources.jar
	DString src_ds;
	src_ds.tinit();
	if (jar_path.ends_with(".jar")) {
		String base = jar_path[..jar_path.len - 5];
		src_ds.appendf("%s-sources.jar", base);
	}

	String source_path = src_ds.str_view();
	bool has_source = source_path.len > 0 && file::is_file(source_path);

	// Extract group/artifact/version from Gradle cache path
	// Pattern: .gradle/caches/modules-2/files-2.1/<group>/<artifact>/<version>/<hash>/<file>.jar
	String group = "";
	String artifact = "";
	String version = "";
	extract_gav_from_path(jar_path, &group, &artifact, &version);

	DependencyJar* jar = &cp.jars[cp.jar_count];
	jar.path = jar_path.copy(mem);
	jar.source_jar_path = has_source ? source_path.copy(mem) : "";
	jar.group_id = group.len > 0 ? group.copy(mem) : "";
	jar.artifact_id = artifact.len > 0 ? artifact.copy(mem) : "";
	jar.version = version.len > 0 ? version.copy(mem) : "";

	cp.jar_count++;

	log::debug("[kls]   JAR: %s%s", jar_path, has_source ? " (sources available)" : "");
	return true;
}

/**
 * Try to extract group, artifact, and version from a Gradle or Maven cache path.
 *
 * Gradle pattern:
 *   ~/.gradle/caches/modules-2/files-2.1/<group>/<artifact>/<version>/<hash>/<file>.jar
 *
 * Maven pattern:
 *   ~/.m2/repository/<group-path>/<artifact>/<version>/<file>.jar
 */
fn void extract_gav_from_path(String jar_path, String* group, String* artifact, String* version) {
	// Try Gradle cache pattern
	if (try idx = find_substring(jar_path, "files-2.1/")) {
		String after = jar_path[idx + "files-2.1/".len..];
		// Split on '/' to get group/artifact/version/hash/file
		String[5] parts;
		usz part_count = split_path_parts(after, &parts, 5);
		if (part_count >= 3) {
			*group = parts[0];
			*artifact = parts[1];
			*version = parts[2];
			return;
		}
	}

	// Try Maven repository pattern
	if (try idx = find_substring(jar_path, ".m2/repository/")) {
		String after = jar_path[idx + ".m2/repository/".len..];
		// Find the filename to work backwards
		String[16] parts;
		usz part_count = split_path_parts(after, &parts, 16);
		if (part_count >= 3) {
			// Last part is filename, second-to-last is version,
			// third-to-last is artifact, rest is group (joined with '.')
			*version = parts[part_count - 2];
			*artifact = parts[part_count - 3];
			// Group is everything before artifact, joined with '.'
			if (part_count > 3) {
				DString ds;
				ds.tinit();
				for (usz i = 0; i < part_count - 3; i++) {
					if (i > 0) ds.appendf(".");
					ds.appendf("%s", parts[i]);
				}
				*group = ds.str_view();
			}
			return;
		}
	}
}

// ── String helpers ─────────────────────────────────────────────────

faultdef RESOLVE_ERROR;

/**
 * Find the first occurrence of `needle` in `haystack`.
 * Returns the byte offset, or a fault if not found.
 */
fn usz? find_substring(String haystack, String needle) {
	if (needle.len == 0 || needle.len > haystack.len) return RESOLVE_ERROR~;

	for (usz i = 0; i <= haystack.len - needle.len; i++) {
		if (haystack[i:needle.len] == needle) {
			return i;
		}
	}
	return RESOLVE_ERROR~;
}

/**
 * Split a path string on '/' into parts.
 * Writes into `out_buf` and returns the count.
 */
fn usz split_path_parts(String path, String[] out_buf, usz max_parts) {
	usz count = 0;
	usz pos = 0;

	while (pos < path.len && count < max_parts) {
		usz sep = pos;
		while (sep < path.len && path[sep] != '/') {
			sep++;
		}

		if (sep > pos) {
			out_buf[count] = path[pos..sep - 1];
			count++;
		}

		pos = sep + 1;
	}

	return count;
}

/**
 * Write content to a file. Simple wrapper around file operations.
 */
fn void? write_string_to_file(String path, String content) {
	File f = file::open(path, "wb")!;
	f.write(content)!;
	f.close()!;
}
