module kls::dual_storage_snapshot_test;

import kls::kotlin::parser;
import kls::kotlin::ast;

fn ParseResult* do_parse(String src) {
	ParseResult* result = mem::new(ParseResult);
	parser::parse(src, result);
	return result;
}

fn void free_result(ParseResult* r) {
	for (uint i = 0; i < r.node_count; i++) {
		if (r.nodes[i].kind == ANNOTATION_ENTRY) continue;
		String ann = r.nodes[i].annotation_text;
		if (ann.len == 0) continue;
		bool has_space = false;
		foreach (c : ann) {
			if (c == ' ') {
				has_space = true;
				break;
			}
		}
		if (has_space) {
			mem::free((void*)ann.ptr);
		}
	}
	r.free_errors();
	mem::free(r);
}

fn String dual_storage_fixture() {
	return `@file:JvmMultifileClass

class Box<T>(val item: T) where T : Comparable<T>, T : Serializable

fun lookup(map: Map<String, List<Pair<Int, Boolean>>>): Int = 0

fun foo(cb: ((Int) -> String)?, susp: suspend (A, B) -> C?) {}

fun greet(name: String = "world", count: Int = 1) {}

class Wrapper(items: List<String>) : List<String> by items, Runnable by Runnable { println("x") }

@Suppress("UNUSED", "DEPRECATION")
@JvmName(name = "foo")
@Inject([1, 2, 3])
class Tagged

class UsesSite {
	@get:JvmName("getValue")
	val value: String = "x"
}

fun <T> bounded(x: T): T & Any = x!!
`;
}

fn String render_param_default_stub(ParseResult* pr, int param_idx) {
	return pr.nodes[(uint)param_idx].extra_text;
}

fn String render_supertype_delegate_stub(ParseResult* pr, int type_ref_idx) {
	uint parent_idx = (uint)type_ref_idx;
	for (uint i = 0; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == parent_idx && pr.nodes[i].extra_text == "delegate") {
			return pr.nodes[i].extra_text;
		}
	}
	return "";
}

fn String render_annotation_args_stub(ParseResult* pr, int annot_idx) {
	return pr.nodes[(uint)annot_idx].annotation_text;
}

fn String render_type_ref_stub(ParseResult* pr, int type_ref_idx) {
	return pr.nodes[(uint)type_ref_idx].type_text;
}

fn uint find_delegate_child(ParseResult* pr, uint type_ref_idx) {
	for (uint i = 0; i < pr.node_count; i++) {
		if (pr.nodes[i].parent == type_ref_idx && pr.nodes[i].extra_text == "delegate") {
			return i;
		}
	}
	return ast::NO_PARENT;
}

fn void test_snapshot_type_ref_dual_storage() @test {
	@pool() {
		ParseResult* pr = do_parse(dual_storage_fixture());
		defer free_result(pr);
		assert(pr.error_count == 0, "expected no parse errors, got %d", (int)pr.error_count);
		uint checked = 0;
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.kind != TYPE_REF || n.type_text.len == 0) continue;
			assert(n.type_text == render_type_ref_stub(pr, (int)i),
				"TYPE_REF %d mismatch: '%s' vs '%s'", (int)i, n.type_text,
				render_type_ref_stub(pr, (int)i));
			checked++;
		}
		assert(checked > 0, "expected TYPE_REF nodes in fixture");
	};
}

fn void test_snapshot_annotation_dual_storage() @test {
	@pool() {
		ParseResult* pr = do_parse(dual_storage_fixture());
		defer free_result(pr);
		assert(pr.error_count == 0, "expected no parse errors, got %d", (int)pr.error_count);
		uint checked = 0;
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.kind != ANNOTATION_ENTRY) continue;
			assert(n.annotation_text == render_annotation_args_stub(pr, (int)i),
				"ANNOTATION_ENTRY %d mismatch: '%s' vs '%s'", (int)i, n.annotation_text,
				render_annotation_args_stub(pr, (int)i));
			checked++;
		}
		assert(checked > 0, "expected ANNOTATION_ENTRY nodes in fixture");
	};
}

fn void test_snapshot_param_default_dual_storage() @test {
	@pool() {
		ParseResult* pr = do_parse(dual_storage_fixture());
		defer free_result(pr);
		assert(pr.error_count == 0, "expected no parse errors, got %d", (int)pr.error_count);
		uint checked = 0;
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.kind != PARAM || n.extra_text.len == 0 || n.child_count == 0) continue;
			assert(n.extra_text == render_param_default_stub(pr, (int)i),
				"PARAM %d mismatch: '%s' vs '%s'", (int)i, n.extra_text,
				render_param_default_stub(pr, (int)i));
			checked++;
		}
		assert(checked >= 2, "expected defaulted PARAM nodes in fixture, got %d", (int)checked);
	};
}

fn void test_snapshot_supertype_delegate_dual_storage() @test {
	@pool() {
		ParseResult* pr = do_parse(dual_storage_fixture());
		defer free_result(pr);
		assert(pr.error_count == 0, "expected no parse errors, got %d", (int)pr.error_count);
		uint checked = 0;
		for (uint i = 0; i < pr.node_count; i++) {
			AstNode* n = &pr.nodes[i];
			if (n.kind != TYPE_REF) continue;
			uint delegate_child = find_delegate_child(pr, i);
			if (delegate_child == ast::NO_PARENT) continue;
			assert(pr.nodes[delegate_child].extra_text == render_supertype_delegate_stub(pr, (int)i),
				"delegate TYPE_REF %d mismatch: '%s' vs '%s'", (int)i,
				pr.nodes[delegate_child].extra_text,
				render_supertype_delegate_stub(pr, (int)i));
			checked++;
		}
		assert(checked >= 2, "expected delegated supertypes in fixture, got %d", (int)checked);
	};
}
