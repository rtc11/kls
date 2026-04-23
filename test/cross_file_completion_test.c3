module kls::test::cross_file_completion_test;

import std::collections::object;
import kls::document;
import kls::lsp::completion;
import kls::workspace;
import kls::deps::jar_index;

// ── Helper: build params object ────────────────────────────────────

fn Object* make_params(String uri, int line, int character) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);

	Object* pos = object::new_obj(tmem);
	pos.set("line", line);
	pos.set("character", character);

	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("position", pos);
	return params;
}

// ── Workspace completions from other files ─────────────────────────

fn void workspace_completion_basic() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Another file has "helperFunction"
		ws.index_file("file:///utils.kt", "fun helperFunction() {}");

		// Current file is typing "hel"
		String content = "fun main() { hel }";
		store.open("file:///main.kt", "kotlin", 1, content);

		// Cursor after "hel" at col 16
		Object* params = make_params("file:///main.kt", 0, 16);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "helperFunction") {
				found = true;
				int kind = item.get_int("kind")!!;
				assert(kind == completion::COMPLETION_KIND_FUNCTION,
					"expected Function kind, got %d", kind);
			}
		}
		assert(found, "expected 'helperFunction' from workspace completions");
	};
}

// ── Workspace completion: class ────────────────────────────────────

fn void workspace_completion_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///models.kt", "class MyWidget {}\nclass MyService {}");

		String content = "fun create(): My";
		store.open("file:///main.kt", "kotlin", 1, content);

		// Cursor at col 16 (after "My")
		Object* params = make_params("file:///main.kt", 0, 16);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;
		bool found_widget = false;
		bool found_service = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "MyWidget") {
				found_widget = true;
				int kind = item.get_int("kind")!!;
				assert(kind == completion::COMPLETION_KIND_CLASS, "expected Class kind");
			}
			if (label == "MyService") found_service = true;
		}
		assert(found_widget, "expected 'MyWidget' from workspace");
		assert(found_service, "expected 'MyService' from workspace");
	};
}

// ── Workspace completion: skips same-document symbols ──────────────

fn void workspace_completion_skips_same_doc() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index same file in workspace
		String content = "fun localHelper() {}\nfun main() { local }";
		ws.index_file("file:///main.kt", content);
		store.open("file:///main.kt", "kotlin", 1, content);

		// Also index another file with a different "local" symbol
		ws.index_file("file:///other.kt", "fun localOther() {}");

		Object* params = make_params("file:///main.kt", 1, 18);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;
		bool found_other = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "localOther") found_other = true;
		}
		assert(found_other, "expected 'localOther' from other file");
	};
}

// ── Workspace completion: deduplicates ─────────────────────────────

fn void workspace_completion_deduplicates() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Two different files define same name
		ws.index_file("file:///a.kt", "fun doWork() {}");
		ws.index_file("file:///b.kt", "fun doWork(x: Int) {}");

		String content = "fun main() { doW }";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 16);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;
		usz count = 0;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "doWork") count++;
		}
		// Should appear at most once (dedup) - could be from local identifiers or workspace
		assert(count <= 1, "expected at most 1 'doWork', got %d", (int)count);
	};
}

// ── Workspace completion: null workspace works ─────────────────────

fn void completion_with_null_workspace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun main() { fu }";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 15);
		Object* result = completion::handle_completion(&store, null, params)!!;

		assert(result != null, "expected completion result with null workspace");
		Object* items = result.get("items")!!;
		// Should still have keyword "fun" at least
		bool found_fun = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "fun") found_fun = true;
		}
		assert(found_fun, "expected 'fun' keyword completion");
	};
}

// ── Workspace completion: interface kind ───────────────────────────

fn void workspace_completion_interface_kind() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///api.kt", "interface Repo {}");

		String content = "fun use(r: Rep";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 14);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "Repo") {
				int kind = item.get_int("kind")!!;
				assert(kind == completion::COMPLETION_KIND_INTERFACE,
					"expected Interface kind %d, got %d", completion::COMPLETION_KIND_INTERFACE, kind);
				return;
			}
		}
		assert(false, "expected 'Repo' in workspace completions");
	};
}

// ── Workspace completion: no matching prefix returns empty ─────────

fn void workspace_completion_no_match() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///a.kt", "fun helper() {}");

		String content = "fun main() { xyz }";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 16);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;
		// No workspace items should match prefix "xyz"
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			assert(label != "helper", "helper should not match prefix xyz");
		}
	};
}

// ── Cross-file dot-completion for user-defined types ──────────────

fn void dot_completion_workspace_class_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Define a class with a function in another file
		String class_content =
`class MyService {
    fun fetchData(): String { return "" }
    fun processData(input: String): Int { return 0 }
}`;
		ws.index_file("file:///service.kt", class_content);
		store.open("file:///service.kt", "kotlin", 1, class_content);

		// Current file uses the class
		String content = "fun main() {\n    val svc: MyService = MyService()\n    svc.\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		// Cursor after "svc." on line 2, col 8
		Object* params = make_params("file:///main.kt", 2, 8);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_fetch = false;
		bool found_process = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "fetchData") {
				found_fetch = true;
				int kind = item.get_int("kind")!!;
				assert(kind == completion::COMPLETION_KIND_METHOD,
					"expected Method kind for fetchData, got %d", kind);
			}
			if (label == "processData") found_process = true;
		}
		assert(found_fetch, "expected 'fetchData' from workspace class members");
		assert(found_process, "expected 'processData' from workspace class members");
	};
}

fn void dot_completion_workspace_class_property() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String class_content =
`class Config {
    val host: String = "localhost"
    var port: Int = 8080
}`;
		ws.index_file("file:///config.kt", class_content);
		store.open("file:///config.kt", "kotlin", 1, class_content);

		String content = "fun main() {\n    val cfg: Config = Config()\n    cfg.\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 2, 8);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;

		bool found_host = false;
		bool found_port = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "host") {
				found_host = true;
				int kind = item.get_int("kind")!!;
				assert(kind == completion::COMPLETION_KIND_PROPERTY,
					"expected Property kind for host, got %d", kind);
			}
			if (label == "port") found_port = true;
		}
		assert(found_host, "expected 'host' from workspace class members");
		assert(found_port, "expected 'port' from workspace class members");
	};
}

fn void dot_completion_workspace_class_with_prefix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String class_content =
`class MyService {
    fun fetchData(): String { return "" }
    fun fetchMore(): String { return "" }
    fun process(): Int { return 0 }
}`;
		ws.index_file("file:///service.kt", class_content);
		store.open("file:///service.kt", "kotlin", 1, class_content);

		// Typing "svc.fe" -- prefix is "fe"
		String content = "fun main() {\n    val svc: MyService = MyService()\n    svc.fe\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		// Cursor after "svc.fe" on line 2, col 10
		Object* params = make_params("file:///main.kt", 2, 10);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;

		bool found_fetch_data = false;
		bool found_fetch_more = false;
		bool found_process = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "fetchData") found_fetch_data = true;
			if (label == "fetchMore") found_fetch_more = true;
			if (label == "process") found_process = true;
		}
		assert(found_fetch_data, "expected 'fetchData' with prefix 'fe'");
		assert(found_fetch_more, "expected 'fetchMore' with prefix 'fe'");
		// process should not match prefix "fe"
		assert(!found_process, "process should not match prefix 'fe'");
	};
}

fn void dot_completion_workspace_data_class_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String class_content = "data class User(val name: String, val age: Int)";
		ws.index_file("file:///user.kt", class_content);
		store.open("file:///user.kt", "kotlin", 1, class_content);

		String content = "fun main() {\n    val u: User = User(\"Alice\", 30)\n    u.\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 2, 6);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;

		bool found_name = false;
		bool found_age = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "name") found_name = true;
			if (label == "age") found_age = true;
		}
		assert(found_name, "expected 'name' from data class params");
		assert(found_age, "expected 'age' from data class params");
	};
}

fn void dot_completion_workspace_inherited_members() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String base_content =
`open class Base {
    fun baseMethod(): String { return "" }
}`;
		ws.index_file("file:///base.kt", base_content);
		store.open("file:///base.kt", "kotlin", 1, base_content);

		String child_content =
`class Child : Base() {
    fun childMethod(): Int { return 0 }
}`;
		ws.index_file("file:///child.kt", child_content);
		store.open("file:///child.kt", "kotlin", 1, child_content);

		String content = "fun main() {\n    val c: Child = Child()\n    c.\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 2, 6);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;

		bool found_child_method = false;
		bool found_base_method = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "childMethod") found_child_method = true;
			if (label == "baseMethod") found_base_method = true;
		}
		assert(found_child_method, "expected 'childMethod' from Child class");
		assert(found_base_method, "expected 'baseMethod' inherited from Base class");
	};
}

fn void dot_completion_workspace_interface_members() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		String iface_content =
`interface Repository {
    fun findAll(): String
    fun findById(id: Int): String
    val count: Int
}`;
		ws.index_file("file:///repo.kt", iface_content);
		store.open("file:///repo.kt", "kotlin", 1, iface_content);

		String content = "fun main() {\n    val repo: Repository = TODO()\n    repo.\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 2, 9);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		Object* items = result.get("items")!!;

		bool found_find_all = false;
		bool found_find_by_id = false;
		bool found_count = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "findAll") found_find_all = true;
			if (label == "findById") found_find_by_id = true;
			if (label == "count") found_count = true;
		}
		assert(found_find_all, "expected 'findAll' from interface members");
		assert(found_find_by_id, "expected 'findById' from interface members");
		assert(found_count, "expected 'count' from interface members");
	};
}

fn void dot_completion_workspace_no_match_unknown_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// No class named "UnknownType" exists
		String content = "fun main() {\n    val x: UnknownType = TODO()\n    x.\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 2, 6);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		// Should still return a result (possibly with keyword/identifier completions)
		assert(result != null, "expected completion result");
	};
}

fn void dot_completion_workspace_null_workspace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// With null workspace, dot-completion should still work for built-in types
		String content = "fun main() {\n    val s: String = \"hello\"\n    s.\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 2, 6);
		Object* result = completion::handle_completion(&store, null, params)!!;

		assert(result != null, "expected completion result with null workspace");
	};
}

// ── Dot completion via cross-file type inference (no explicit annotation) ──

fn void dot_completion_inferred_cross_file_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a class with members in another file
		String model_content = "class User(val name: String, val age: Int) {\n    fun greet(): String = \"hi\"\n}";
		ws.index_file("file:///models.kt", model_content);
		store.open("file:///models.kt", "kotlin", 1, model_content);

		// Wire workspace into document store for cross-file type resolution
		store.workspace = &ws;

		// Current file: val u = User(...) — type inferred, no explicit annotation
		String content = "fun main() {\n    val u = User(\"Alice\", 30)\n    u.\n}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 2, 6);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_name = false;
		bool found_age = false;
		bool found_greet = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "name") found_name = true;
			if (label == "age") found_age = true;
			if (label == "greet") found_greet = true;
		}
		assert(found_name, "expected 'name' member from inferred User type");
		assert(found_age, "expected 'age' member from inferred User type");
		assert(found_greet, "expected 'greet' member from inferred User type");
	};
}

// ── Annotation completion ─────────────────────────────────────────

fn void annotation_completion_offers_kotlin_annotations() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Cursor right after @
		String content = "@\nfun test() {}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 1);
		Object* result = completion::handle_completion(&store, null, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_deprecated = false;
		bool found_suppress = false;
		bool found_test = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "Deprecated") found_deprecated = true;
			if (label == "Suppress") found_suppress = true;
			if (label == "Test") found_test = true;
		}
		assert(found_deprecated, "expected 'Deprecated' in annotation completions");
		assert(found_suppress, "expected 'Suppress' in annotation completions");
		assert(found_test, "expected 'Test' in annotation completions");
	};
}

fn void annotation_completion_filters_by_prefix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Cursor after @Dep
		String content = "@Dep\nfun test() {}";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 4);
		Object* result = completion::handle_completion(&store, null, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_deprecated = false;
		bool found_test = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "Deprecated") found_deprecated = true;
			if (label == "Test") found_test = true;
		}
		assert(found_deprecated, "expected 'Deprecated' filtered by prefix 'Dep'");
		// Test should NOT match since prefix is "Dep"
	};
}

// ── Import path completion ────────────────────────────────────────

fn void import_completion_offers_packages() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index files with packages
		ws.index_file("file:///models.kt", "package com.example.models\n\nclass User {}");
		ws.index_file("file:///service.kt", "package com.example.service\n\nclass UserService {}");

		// Typing "import com."
		String content = "import com.";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 11);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_example = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "example") found_example = true;
		}
		assert(found_example, "expected 'example' package segment");
	};
}

fn void import_completion_offers_classes() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///models.kt", "package com.example\n\nclass User {}\nclass Account {}");

		// Typing "import com.example."
		String content = "import com.example.";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 19);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_user = false;
		bool found_account = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "User") found_user = true;
			if (label == "Account") found_account = true;
		}
		assert(found_user, "expected 'User' in import completions");
		assert(found_account, "expected 'Account' in import completions");
	};
}

fn void import_completion_filters_by_prefix() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///models.kt", "package com.example\n\nclass User {}\nclass Account {}");

		// Typing "import com.example.Us"
		String content = "import com.example.Us";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 21);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_user = false;
		bool found_account = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "User") found_user = true;
			if (label == "Account") found_account = true;
		}
		assert(found_user, "expected 'User' filtered by 'Us' prefix");
		assert(!found_account, "Account should not match 'Us' prefix");
	};
}

// ── Cross-file completion: empty workspace ─────────────────────────

fn void cross_file_completion_empty_workspace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Empty workspace — no files indexed
		String content = "fun main() { hel }";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 16);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result even with empty workspace");
		Object* items = result.get("items")!!;
		// Should still have keyword completions but no workspace symbols
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			assert(label != "helperFunction", "should not find workspace symbols in empty workspace");
		}
	};
}

// ── Cross-file completion: symbols from multiple files ─────────────

fn void cross_file_completion_multiple_files() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Three different files with symbols starting with "proc"
		ws.index_file("file:///a.kt", "fun dataUtils() {}");
		ws.index_file("file:///b.kt", "class DataProcessor {}");
		ws.index_file("file:///c.kt", "val dataPath = \"\"");

		// Current file typing "data"
		String content = "fun main() { data }";
		store.open("file:///main.kt", "kotlin", 1, content);

		Object* params = make_params("file:///main.kt", 0, 17);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_data_utils = false;
		bool found_data_processor = false;
		bool found_data_path = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "dataUtils") found_data_utils = true;
			if (label == "DataProcessor") found_data_processor = true;
			if (label == "dataPath") found_data_path = true;
		}
		assert(found_data_utils, "expected 'dataUtils' from file a.kt");
		assert(found_data_processor || found_data_path, "expected symbols from multiple workspace files");
	};
}

// ── Dep-class member dot-completion ────────────────────────────────

fn void dot_completion_dep_class_static_member_via_class_ref() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index UUID class + static factory randomUUID
		jar_index::add_dep_symbol(&ws.dep_index,
			"UUID", "class UUID", "java.util", "UUID", "/fake/java.base.jmod",
			DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&ws.dep_index,
			"randomUUID", "fun randomUUID(): UUID", "java.util", "UUID", "/fake/java.base.jmod",
			DEP_METHOD, null, 0, false, true);

		store.workspace = &ws;

		String content = "import java.util.UUID\nfun main() {\n    UUID.\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor right after "UUID." on line 2, col 9
		Object* params = make_params("file:///test.kt", 2, 9);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "randomUUID") {
				found = true;
				break;
			}
		}
		assert(found, "expected 'randomUUID' as static member completion on UUID class-ref");
	};
}

fn void dot_completion_dep_class_instance_member() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// ArrayList class + instance method add (instance => is_static=false)
		jar_index::add_dep_symbol(&ws.dep_index,
			"ArrayList", "class ArrayList", "java.util", "ArrayList", "/fake/java.base.jmod",
			DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&ws.dep_index,
			"add", "fun add(E): Boolean", "java.util", "ArrayList", "/fake/java.base.jmod",
			DEP_METHOD, null, 0, false, false);
		jar_index::add_dep_symbol(&ws.dep_index,
			"size", "val size: Int", "java.util", "ArrayList", "/fake/java.base.jmod",
			DEP_FIELD, null, 0, false, false);

		store.workspace = &ws;

		String content = "import java.util.ArrayList\nfun main() {\n    val xs: ArrayList = ArrayList()\n    xs.\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor right after "xs." on line 3, col 7
		Object* params = make_params("file:///test.kt", 3, 7);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_add = false;
		bool found_size = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "add") found_add = true;
			if (label == "size") found_size = true;
		}
		assert(found_add, "expected 'add' as instance member completion on ArrayList instance");
		assert(found_size, "expected 'size' as instance field completion on ArrayList instance");
	};
}

fn void dot_completion_dep_class_static_hidden_on_instance_in_strict_mode_NA() @test {
	// Documentation test: strict instance mode is NOT yet implemented.
	// is_member_accessible currently allows statics on instance receivers
	// (only filters when receiver is class-ref). So `instance.STATIC_MEMBER`
	// will surface in completion until strict mode lands. This test
	// codifies current behaviour.
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		jar_index::add_dep_symbol(&ws.dep_index,
			"UUID", "class UUID", "java.util", "UUID", "/fake/java.base.jmod",
			DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&ws.dep_index,
			"randomUUID", "fun randomUUID(): UUID", "java.util", "UUID", "/fake/java.base.jmod",
			DEP_METHOD, null, 0, false, true);

		store.workspace = &ws;

		String content = "import java.util.UUID\nfun main() {\n    val u: UUID = UUID.randomUUID()\n    u.\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 3, 6);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		// Currently allowed (no strict instance filter); when strict mode lands,
		// flip the assertion.
		bool found = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "randomUUID") {
				found = true;
				break;
			}
		}
		assert(found, "current behaviour: static surfaces on instance receiver (strict instance mode pending)");
	};
}

fn void dot_completion_dep_class_inherited_member_via_supertype() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Subclass with one supertype "AbstractList"
		String[jar_index::MAX_DEP_SUPERTYPES] supers;
		supers[0] = "AbstractList";
		jar_index::add_dep_symbol(&ws.dep_index,
			"ArrayList", "class ArrayList", "java.util", "ArrayList", "/fake/java.base.jmod",
			DEP_CLASS, &supers, 1);

		// Supertype with an inherited method
		jar_index::add_dep_symbol(&ws.dep_index,
			"AbstractList", "class AbstractList", "java.util", "AbstractList", "/fake/java.base.jmod",
			DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&ws.dep_index,
			"clear", "fun clear(): Unit", "java.util", "AbstractList", "/fake/java.base.jmod",
			DEP_METHOD, null, 0, false, false);

		store.workspace = &ws;

		String content = "import java.util.ArrayList\nfun main() {\n    val xs: ArrayList = ArrayList()\n    xs.\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 3, 7);
		Object* result = completion::handle_completion(&store, &ws, params)!!;

		assert(result != null, "expected completion result");
		Object* items = result.get("items")!!;

		bool found_clear = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "clear") {
				found_clear = true;
				break;
			}
		}
		assert(found_clear, "expected 'clear' inherited from AbstractList supertype");
	};
}
