module kls::test::compareto_chain_test;

import std::collections::object;
import kls::document;
import kls::lsp::code_actions;
import kls::kotlin::ast;
import kls::kotlin::parser;

fn Object* make_params(String uri, int line, int col) {
	Object* td = object::new_obj(tmem);
	td.set("uri", uri);
	Object* s = object::new_obj(tmem);
	s.set("line", line);
	s.set("character", col);
	Object* e = object::new_obj(tmem);
	e.set("line", line);
	e.set("character", col);
	Object* range = object::new_obj(tmem);
	range.set("start", s);
	range.set("end", e);
	Object* context = object::new_obj(tmem);
	context.set("diagnostics", object::new_obj(tmem));
	Object* params = object::new_obj(tmem);
	params.set("textDocument", td);
	params.set("range", range);
	params.set("context", context);
	return params;
}

fn Object* find_action_with_title(Object* actions, String needle) {
	for (sz i = 0; i < actions.get_len(); i++) {
		Object* a = actions.get_at((usz)i);
		String t = a.get_string("title") ?? "";
		if (t.contains(needle)) return a;
	}
	return null;
}

fn String first_edit_new_text(Object* action, String uri) {
	Object* edit = action.get("edit") ?? null;
	if (edit == null) return "";
	Object* changes = edit.get("changes") ?? null;
	if (changes == null) return "";
	Object* edits = changes.get(uri) ?? null;
	if (edits == null) return "";
	if (edits.get_len() == 0) return "";
	return edits.get_at(0).get_string("newText") ?? "";
}

fn String apply_edit(String content, Object* action, String uri) {
	Object* edit = action.get("edit") ?? null;
	Object* changes = edit.get("changes") ?? null;
	Object* edits = changes.get(uri) ?? null;
	Object* e = edits.get_at(0);
	String new_text = e.get_string("newText") ?? "";
	Object* range = e.get("range") ?? null;
	Object* s = range.get("start") ?? null;
	Object* en = range.get("end") ?? null;
	int sl = s.get_int("line") ?? 0;
	int sc = s.get_int("character") ?? 0;
	int el = en.get_int("line") ?? 0;
	int ec = en.get_int("character") ?? 0;

	// Convert (line,col) to byte offsets in content.
	int line = 0;
	int col = 0;
	int start_off = 0;
	int end_off = 0;
	for (int i = 0; i <= content.len; i++) {
		if (line == sl && col == sc) start_off = i;
		if (line == el && col == ec) { end_off = i; break; }
		if (i == content.len) break;
		if (content[i] == '\n') { line++; col = 0; }
		else { col++; }
	}

	DString out;
	out.tinit();
	out.append(content[:(usz)start_off]);
	out.append(new_text);
	out.append(content[(usz)end_off..]);
	return out.str_view();
}

// ── Tests ──────────────────────────────────────────────────────

fn void offered_for_two_field_chain() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int, val b: Int) : Comparable<P> {
	override fun compareTo(other: P): Int {
		val cmp = a.compareTo(other.a)
		if (cmp != 0) return cmp
		return b.compareTo(other.b)
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		// Cursor on the 'compareTo' line (line 1, col 14).
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "compareValuesBy");
		assert(action != null, "action offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text.contains("compareValuesBy(this, other"),
			"replacement uses compareValuesBy(this, other, ...)");
		assert(new_text.contains("{ it.a }"), "selector for a");
		assert(new_text.contains("{ it.b }"), "selector for b");
	};
}

fn void offered_for_three_field_chain() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int, val b: Int, val c: Int) : Comparable<P> {
	override fun compareTo(other: P): Int {
		val cmp1 = a.compareTo(other.a)
		if (cmp1 != 0) return cmp1
		val cmp2 = b.compareTo(other.b)
		if (cmp2 != 0) return cmp2
		return c.compareTo(other.c)
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "compareValuesBy");
		assert(action != null, "offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text.contains("{ it.a }") && new_text.contains("{ it.b }") && new_text.contains("{ it.c }"),
			"all three selectors");
	};
}

fn void applied_edit_rebuilds_one_liner() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int, val b: Int) : Comparable<P> {
	override fun compareTo(other: P): Int {
		val cmp = a.compareTo(other.a)
		if (cmp != 0) return cmp
		return b.compareTo(other.b)
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "compareValuesBy");
		assert(action != null, "offered");

		String result = apply_edit(content, action, uri);
		// The edited source must contain the one-liner expression body:
		assert(result.contains("override fun compareTo(other: P): Int = compareValuesBy(this, other, { it.a }, { it.b })"),
			"applied edit produces idiomatic one-liner");
	};
}

fn void uses_param_name_from_signature() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int, val b: Int) : Comparable<P> {
	override fun compareTo(rhs: P): Int {
		val cmp = a.compareTo(rhs.a)
		if (cmp != 0) return cmp
		return b.compareTo(rhs.b)
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "compareValuesBy");
		assert(action != null, "offered");
		String new_text = first_edit_new_text(action, uri);
		assert(new_text.contains("compareValuesBy(this, rhs"),
			"uses rhs as second arg");
	};
}

// ── Negative: must NOT offer ──────────────────────────────────

fn void not_offered_when_field_mismatch() @test {
	@pool() {
		// other.X must match the receiver field. Mismatched names => bail.
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int, val b: Int) : Comparable<P> {
	override fun compareTo(other: P): Int {
		val cmp = a.compareTo(other.b)
		if (cmp != 0) return cmp
		return b.compareTo(other.a)
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		assert(find_action_with_title(res, "compareValuesBy") == null,
			"mismatched fields => no action");
	};
}

fn void not_offered_for_single_field() @test {
	@pool() {
		// Single field => use field.compareTo directly; refactor not useful.
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int) : Comparable<P> {
	override fun compareTo(other: P): Int = a.compareTo(other.a)
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		assert(find_action_with_title(res, "compareValuesBy") == null,
			"no block body => no action");
	};
}

fn void not_offered_for_unrelated_function() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int) {
	fun describe(other: P): String {
		val cmp = a.compareTo(other.a)
		if (cmp != 0) return "lt"
		return "eq"
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		assert(find_action_with_title(res, "compareValuesBy") == null,
			"function not named compareTo => no action");
	};
}

fn void not_offered_when_not_equals_zero_pattern_differs() @test {
	@pool() {
		// Use '< 0' instead of '!= 0' — signals different semantics, bail.
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int, val b: Int) : Comparable<P> {
	override fun compareTo(other: P): Int {
		val cmp = a.compareTo(other.a)
		if (cmp < 0) return cmp
		return b.compareTo(other.b)
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		assert(find_action_with_title(res, "compareValuesBy") == null,
			"non-canonical pattern => no action");
	};
}

fn void action_kind_is_refactor_rewrite() @test {
	@pool() {
		String uri = "file:///t.kt";
		String content =
			`class P(val a: Int, val b: Int) : Comparable<P> {
	override fun compareTo(other: P): Int {
		val cmp = a.compareTo(other.a)
		if (cmp != 0) return cmp
		return b.compareTo(other.b)
	}
}
`;
		DocumentStore store; store.init(); defer store.free();
		store.open(uri, "kotlin", 1, content);
		Object* params = make_params(uri, 1, 14);
		Object* res = code_actions::handle_code_action(&store, null, params)!!;
		Object* action = find_action_with_title(res, "compareValuesBy");
		assert(action != null, "found");
		String kind = action.get_string("kind") ?? "";
		assert(kind == "refactor.rewrite", "refactor.rewrite kind");
	};
}
