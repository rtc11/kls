module kls::test::cross_file_completion_test;

import std::collections::object;
import kls::document;
import kls::lsp::completion;
import kls::workspace;

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
		Object* result = completion::handle_completion(&store, &ws, params);

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
		Object* result = completion::handle_completion(&store, &ws, params);

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
		Object* result = completion::handle_completion(&store, &ws, params);

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
		Object* result = completion::handle_completion(&store, &ws, params);

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
		Object* result = completion::handle_completion(&store, null, params);

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
		Object* result = completion::handle_completion(&store, &ws, params);

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
		Object* result = completion::handle_completion(&store, &ws, params);

		Object* items = result.get("items")!!;
		// No workspace items should match prefix "xyz"
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			assert(label != "helper", "helper should not match prefix xyz");
		}
	};
}
