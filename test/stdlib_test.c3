module kls::test::stdlib_test;

import std::collections::object;
import kls::kotlin::stdlib;
import kls::lsp::completion;

// ── lookup_by_name ─────────────────────────────────────────────────

fn void lookup_println_found() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("println")!!;
	assert(sym.name == "println", "expected name 'println', got '%s'", sym.name);
	assert(sym.package_name == "kotlin.io", "expected package 'kotlin.io', got '%s'", sym.package_name);
}

fn void lookup_listof_found() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("listOf")!!;
	assert(sym.name == "listOf", "expected name 'listOf', got '%s'", sym.name);
	assert(sym.package_name == "kotlin.collections", "expected package 'kotlin.collections', got '%s'", sym.package_name);
}

fn void lookup_string_class_found() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("String")!!;
	assert(sym.name == "String", "expected name 'String', got '%s'", sym.name);
	assert(sym.kind == CLASS, "expected CLASS kind");
}

fn void lookup_list_interface_found() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("List")!!;
	assert(sym.name == "List", "expected name 'List', got '%s'", sym.name);
	assert(sym.kind == INTERFACE, "expected INTERFACE kind");
}

fn void lookup_nonexistent_returns_fault() @test {
	if (try sym = stdlib::lookup_by_name("totallyNonexistentSymbol123")) {
		assert(false, "expected fault for nonexistent symbol, got '%s'", sym.name);
	}
}

fn void lookup_map_method_found() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("map")!!;
	assert(sym.name == "map", "expected name 'map', got '%s'", sym.name);
}

// ── lookup_all_by_name ─────────────────────────────────────────────

fn void lookup_all_println_has_overloads() @test {
	StdlibSymbol*[16] buf;
	usz count = stdlib::lookup_all_by_name("println", &buf);
	assert(count >= 2, "expected at least 2 println overloads, got %d", (int)count);
}

fn void lookup_all_listof_has_overloads() @test {
	StdlibSymbol*[16] buf;
	usz count = stdlib::lookup_all_by_name("listOf", &buf);
	assert(count >= 2, "expected at least 2 listOf overloads, got %d", (int)count);
}

fn void lookup_all_nonexistent_returns_zero() @test {
	StdlibSymbol*[16] buf;
	usz count = stdlib::lookup_all_by_name("totallyNonexistentSymbol123", &buf);
	assert(count == 0, "expected 0 for nonexistent symbol, got %d", (int)count);
}

fn void lookup_all_filter_has_multiple() @test {
	// filter exists on Iterable at minimum
	StdlibSymbol*[16] buf;
	usz count = stdlib::lookup_all_by_name("filter", &buf);
	assert(count >= 1, "expected at least 1 filter match, got %d", (int)count);
}

// ── lookup_by_prefix ───────────────────────────────────────────────

fn void prefix_print_finds_println() @test {
	StdlibSymbol*[64] buf;
	usz count = stdlib::lookup_by_prefix("print", &buf);
	assert(count >= 2, "expected at least 2 matches for 'print', got %d", (int)count);

	bool found_println = false;
	bool found_print = false;
	for (usz i = 0; i < count; i++) {
		if (buf[i].name == "println") found_println = true;
		if (buf[i].name == "print") found_print = true;
	}
	assert(found_println, "expected 'println' in prefix 'print' results");
	assert(found_print, "expected 'print' in prefix 'print' results");
}

fn void prefix_listO_finds_listof() @test {
	StdlibSymbol*[64] buf;
	usz count = stdlib::lookup_by_prefix("listO", &buf);
	assert(count >= 1, "expected at least 1 match for 'listO', got %d", (int)count);

	bool found = false;
	for (usz i = 0; i < count; i++) {
		if (buf[i].name == "listOf") found = true;
	}
	assert(found, "expected 'listOf' in prefix 'listO' results");
}

fn void prefix_empty_returns_zero() @test {
	StdlibSymbol*[64] buf;
	usz count = stdlib::lookup_by_prefix("", &buf);
	assert(count == 0, "expected 0 for empty prefix, got %d", (int)count);
}

fn void prefix_xyz_returns_zero() @test {
	StdlibSymbol*[64] buf;
	usz count = stdlib::lookup_by_prefix("xyzNonsense", &buf);
	assert(count == 0, "expected 0 for nonsense prefix, got %d", (int)count);
}

fn void prefix_to_finds_multiple() @test {
	StdlibSymbol*[128] buf;
	usz count = stdlib::lookup_by_prefix("to", &buf);
	// Should find toInt, toLong, toDouble, toList, toSet, toMap, toString, etc.
	assert(count >= 5, "expected at least 5 matches for prefix 'to', got %d", (int)count);
}

// ── symbol_count ───────────────────────────────────────────────────

fn void symbol_count_is_reasonable() @test {
	usz count = stdlib::symbol_count();
	assert(count >= 100, "expected at least 100 stdlib symbols, got %d", (int)count);
	assert(count < 10000, "expected fewer than 10000 symbols, got %d", (int)count);
}

// ── Signature content ──────────────────────────────────────────────

fn void println_signature_contains_fun() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("println")!!;
	assert(sym.signature.contains("fun"), "expected signature to contain 'fun', got '%s'", sym.signature);
	assert(sym.signature.contains("println"), "expected signature to contain 'println', got '%s'", sym.signature);
}

fn void list_signature_contains_interface() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("List")!!;
	assert(sym.signature.contains("interface"), "expected signature to contain 'interface', got '%s'", sym.signature);
}

fn void string_class_has_doc() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("String")!!;
	assert(sym.doc.len > 0, "expected non-empty doc for String");
}

// ── Completion integration ─────────────────────────────────────────

fn void stdlib_completions_for_print() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_stdlib_completions(items, "print");

		bool found_println = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "println") found_println = true;
		}
		assert(found_println, "expected 'println' in stdlib completions for prefix 'print'");
	};
}

fn void stdlib_completions_have_detail() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_stdlib_completions(items, "print");

		// Find println and check it has a detail (package name)
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "println") {
				String detail = item.get_string("detail")!!;
				assert(detail == "kotlin.io", "expected detail 'kotlin.io', got '%s'", detail);
				return;
			}
		}
		assert(false, "println not found in completions");
	};
}

fn void stdlib_completions_have_documentation() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_stdlib_completions(items, "print");

		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "println") {
				// Documentation is deferred to completionItem/resolve.
				// Check that data field has resolve info.
				Object* data = item.get("data")!!;
				String source = data.get_string("source")!!;
				assert(source == "stdlib", "expected data source 'stdlib', got '%s'", source);
				String name = data.get_string("name")!!;
				assert(name == "println", "expected data name 'println', got '%s'", name);
				return;
			}
		}
		assert(false, "println not found in completions");
	};
}

fn void stdlib_completions_have_correct_kind() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_stdlib_completions(items, "Strin");

		bool found = false;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "String") {
				int kind = item.get_int("kind")!!;
				assert(kind == completion::COMPLETION_KIND_CLASS,
					"expected class kind %d, got %d", completion::COMPLETION_KIND_CLASS, kind);
				found = true;
			}
			if (label == "StringBuilder") {
				int kind = item.get_int("kind")!!;
				assert(kind == completion::COMPLETION_KIND_CLASS,
					"expected class kind %d, got %d", completion::COMPLETION_KIND_CLASS, kind);
			}
		}
		assert(found, "expected 'String' in stdlib completions for prefix 'Strin'");
	};
}

fn void stdlib_completions_empty_prefix_returns_nothing() @test {
	@pool() {
		Object* items = object::new_obj(tmem);
		completion::add_stdlib_completions(items, "");
		assert(items.get_len() == 0, "expected 0 items for empty prefix, got %d", (int)items.get_len());
	};
}

fn void stdlib_completions_dedup_against_existing() @test {
	@pool() {
		Object* items = object::new_obj(tmem);

		// Pre-add "println" to simulate it already being in completions
		Object* existing = object::new_obj(tmem);
		existing.set("label", "println");
		existing.set("kind", completion::COMPLETION_KIND_VARIABLE);
		items.push(existing);

		completion::add_stdlib_completions(items, "print");

		// Count how many "println" items exist
		usz count = 0;
		for (usz i = 0; i < items.get_len(); i++) {
			Object* item = items.get_at(i);
			String label = item.get_string("label")!!;
			if (label == "println") count++;
		}
		assert(count == 1, "expected exactly 1 'println' (dedup), got %d", (int)count);
	};
}

// ── Stdlib kinds ───────────────────────────────────────────────────

fn void function_kind_maps_correctly() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("println")!!;
	assert(sym.kind == FUNCTION, "expected FUNCTION kind for println");
}

fn void method_kind_exists() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("map")!!;
	assert(sym.kind == METHOD, "expected METHOD kind for map");
}

fn void interface_kind_exists() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("Comparable")!!;
	assert(sym.kind == INTERFACE, "expected INTERFACE kind for Comparable");
}

fn void property_kind_exists() @test {
	// "size" is a property on Collection
	StdlibSymbol* sym = stdlib::lookup_by_name("size")!!;
	assert(sym.kind == PROPERTY, "expected PROPERTY kind for size");
}

// ── Receiver field ─────────────────────────────────────────────────

fn void top_level_function_has_empty_receiver() @test {
	StdlibSymbol* sym = stdlib::lookup_by_name("listOf")!!;
	assert(sym.receiver == "", "expected empty receiver for listOf, got '%s'", sym.receiver);
}

fn void extension_method_has_receiver() @test {
	// "map" is an extension on Iterable<T>
	StdlibSymbol*[16] buf;
	usz count = stdlib::lookup_all_by_name("map", &buf);
	assert(count >= 1, "expected at least 1 map entry");

	bool found_with_receiver = false;
	for (usz i = 0; i < count; i++) {
		if (buf[i].receiver.len > 0) {
			found_with_receiver = true;
			break;
		}
	}
	assert(found_with_receiver, "expected at least one map overload with a receiver");
}

fn void completion_resolve_stdlib_adds_documentation() @test {
	@pool() {
		// Build a completion item with data like add_stdlib_completions would
		Object* item = object::new_obj(tmem);
		item.set("label", "println");
		item.set("kind", completion::COMPLETION_KIND_FUNCTION);
		item.set("detail", "kotlin.io");

		Object* data = object::new_obj(tmem);
		data.set("source", "stdlib");
		data.set("name", "println");
		data.set("package", "kotlin.io");
		item.set("data", data);

		// Resolve should add documentation
		Object* resolved = completion::handle_completion_resolve(null, item)!!;
		Object* doc_obj = resolved.get("documentation")!!;
		String doc_kind = doc_obj.get_string("kind")!!;
		assert(doc_kind == "markdown", "expected markdown, got '%s'", doc_kind);
		String doc_value = doc_obj.get_string("value")!!;
		assert(doc_value.contains("println"), "expected doc to contain 'println'");
	};
}

fn void completion_resolve_member_adds_signature() @test {
	@pool() {
		Object* item = object::new_obj(tmem);
		item.set("label", "length");
		item.set("kind", completion::COMPLETION_KIND_PROPERTY);

		Object* data = object::new_obj(tmem);
		data.set("source", "member");
		data.set("name", "length");
		data.set("signature", "val length: Int");
		item.set("data", data);

		Object* resolved = completion::handle_completion_resolve(null, item)!!;
		Object* doc_obj = resolved.get("documentation")!!;
		String doc_value = doc_obj.get_string("value")!!;
		assert(doc_value.contains("val length: Int"), "expected signature in doc");
	};
}

fn void completion_resolve_no_data_returns_item_unchanged() @test {
	@pool() {
		Object* item = object::new_obj(tmem);
		item.set("label", "myVar");
		item.set("kind", completion::COMPLETION_KIND_VARIABLE);

		Object* resolved = completion::handle_completion_resolve(null, item)!!;
		// No data -> no documentation added
		assert(resolved == item, "expected same item returned");
		Object* doc = resolved.get("documentation") ?? null;
		assert(doc == null, "expected no documentation for item without data");
	};
}
