module kls::test::nested_dep_class_test;

import kls::deps::jar_index;
import kls::deps::member_resolver;

// Regression: nested dep class `Outer.Inner` (e.g.
// `ProcessingExceptionHandler.Response`) was not resolvable via go-to-def or
// hover because the indexer stores nested classes under `Outer$Inner` while
// the resolver only matched flat `class_name` against METHOD/FIELD members.

fn void find_dep_nested_class_resolves_inner_by_outer_dot_inner() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		// Outer interface
		jar_index::add_dep_symbol(&idx, "ProcessingExceptionHandler",
			"interface ProcessingExceptionHandler",
			"org.apache.kafka.streams.errors", "ProcessingExceptionHandler",
			"/jar/kafka-streams.jar", DEP_INTERFACE, null, 0);

		// Nested public class indexed under "Outer$Inner"
		jar_index::add_dep_symbol(&idx, "ProcessingExceptionHandler$Response",
			"class ProcessingExceptionHandler$Response",
			"org.apache.kafka.streams.errors", "ProcessingExceptionHandler$Response",
			"/jar/kafka-streams.jar", DEP_CLASS, null, 0);

		// Direct lookup by the compound name still works
		DepSymbol*[4] direct;
		usz dc = idx.lookup_by_name("ProcessingExceptionHandler$Response", &direct);
		assert(dc == 1, "expected 1 symbol for compound name, got %d", (int)dc);

		// New helper resolves Outer.Inner without compound name knowledge
		DepSymbol* nested = member_resolver::find_dep_nested_class(
			&idx, "ProcessingExceptionHandler", "Response", "");
		assert(nested != null, "expected to resolve nested class via Outer.Inner");
		assert(nested.kind == DEP_CLASS, "expected DEP_CLASS for nested");
		assert(nested.name == "ProcessingExceptionHandler$Response",
			"expected compound simple name, got '%s'", nested.name);
	};
}

fn void find_dep_nested_class_returns_null_for_missing() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "Foo", "class Foo",
			"com.example", "Foo", "/jar/x.jar", DEP_CLASS, null, 0);

		DepSymbol* nested = member_resolver::find_dep_nested_class(
			&idx, "Foo", "DoesNotExist", "");
		assert(nested == null, "expected null for missing nested class");
	};
}

fn void find_dep_nested_class_prefers_preferred_pkg() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		// Two outer "Foo" types in different packages, each with nested "Bar"
		jar_index::add_dep_symbol(&idx, "Foo$Bar", "class Foo$Bar",
			"com.first", "Foo$Bar", "/jar/a.jar", DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&idx, "Foo$Bar", "class Foo$Bar",
			"com.second", "Foo$Bar", "/jar/b.jar", DEP_CLASS, null, 0);

		DepSymbol* picked = member_resolver::find_dep_nested_class(
			&idx, "Foo", "Bar", "com.second");
		assert(picked != null, "expected resolution");
		assert(picked.package_name == "com.second",
			"expected preferred package match, got '%s'", picked.package_name);
	};
}

fn void find_dep_class_members_returns_nested_class_when_class_ref() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "ProcessingExceptionHandler",
			"interface ProcessingExceptionHandler",
			"org.apache.kafka.streams.errors", "ProcessingExceptionHandler",
			"/jar/kafka-streams.jar", DEP_INTERFACE, null, 0);
		jar_index::add_dep_symbol(&idx, "ProcessingExceptionHandler$Response",
			"class ProcessingExceptionHandler$Response",
			"org.apache.kafka.streams.errors", "ProcessingExceptionHandler$Response",
			"/jar/kafka-streams.jar", DEP_CLASS, null, 0);

		DepSymbol*[8] out;
		usz count = member_resolver::find_dep_class_members(
			&idx, "ProcessingExceptionHandler", "Response",
			true, "", &out);
		assert(count == 1, "expected 1 result via class-ref nested lookup, got %d", (int)count);
		assert(out[0].kind == DEP_CLASS, "expected nested DEP_CLASS");
		assert(out[0].name == "ProcessingExceptionHandler$Response",
			"expected compound name, got '%s'", out[0].name);
	};
}

fn void find_dep_class_members_skips_nested_for_instance_receiver() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "Outer", "class Outer",
			"com.example", "Outer", "/jar/x.jar", DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&idx, "Outer$Inner", "class Outer$Inner",
			"com.example", "Outer$Inner", "/jar/x.jar", DEP_CLASS, null, 0);

		// Instance receiver (`outerInstance.Inner` is invalid Kotlin) — must NOT
		// surface the nested class.
		DepSymbol*[8] out;
		usz count = member_resolver::find_dep_class_members(
			&idx, "Outer", "Inner", false, "", &out);
		assert(count == 0,
			"expected 0 results for instance-receiver nested lookup, got %d", (int)count);
	};
}

// Regression: indexer policy must allow named nested classes (Outer$Response)
// through `has_dollar_in_class_name` so the dep index actually contains them.
// Anonymous classes (Outer$1, Outer$12) must still be skipped.
fn void indexer_policy_named_nested_allowed() @test {
	assert(!jar_index::has_dollar_in_class_name("com/example/Outer$Inner.class"),
		"named nested class must be indexed");
	assert(!jar_index::has_dollar_in_class_name("com/example/Foo$Response.class"),
		"named nested class with arbitrary name must be indexed");
}

fn void indexer_policy_anonymous_skipped() @test {
	assert(jar_index::has_dollar_in_class_name("com/example/Foo$1.class"),
		"anonymous class (digit suffix) must be skipped");
	assert(jar_index::has_dollar_in_class_name("com/example/Foo$42.class"),
		"multi-digit anonymous must be skipped");
}

// Regression: chained access `Outer.Inner.staticMethod()` — find_dep_class_members
// must find a static method whose `class_name` is the COMPOUND `Outer$Inner` form
// when called with a class-ref receiver typed as `Outer$Inner`.
fn void find_dep_class_members_finds_static_method_on_compound_class() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "ProcessingExceptionHandler$Response",
			"class ProcessingExceptionHandler$Response",
			"org.apache.kafka.streams.errors", "ProcessingExceptionHandler$Response",
			"/jar/kafka-streams.jar", DEP_CLASS, null, 0);
		// Static factory method inside the nested class — class_name retains compound form
		jar_index::add_dep_symbol(&idx, "resume",
			"public static Response resume(List<Record> records)",
			"org.apache.kafka.streams.errors", "ProcessingExceptionHandler$Response",
			"/jar/kafka-streams.jar", DEP_METHOD, null, 0,
			is_static: true);

		DepSymbol*[8] out;
		usz count = member_resolver::find_dep_class_members(
			&idx, "ProcessingExceptionHandler$Response", "resume",
			true, "", &out);
		assert(count >= 1,
			"expected static method 'resume' to resolve on class-ref receiver of compound class, got %d",
			(int)count);
		assert(out[0].kind == DEP_METHOD, "expected DEP_METHOD");
		assert(out[0].is_static, "expected static method");
		assert(out[0].class_name == "ProcessingExceptionHandler$Response",
			"expected compound class_name retained, got '%s'", out[0].class_name);
	};
}

fn void find_dep_class_members_hides_static_from_instance_receiver() @test {
	@pool() {
		DependencyIndex idx;
		idx.init();
		defer idx.free();

		jar_index::add_dep_symbol(&idx, "Outer$Inner", "class Outer$Inner",
			"com.example", "Outer$Inner", "/jar/x.jar", DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&idx, "factory", "public static Inner factory()",
			"com.example", "Outer$Inner", "/jar/x.jar", DEP_METHOD, null, 0,
			is_static: true);

		// Instance receiver must NOT see static method (strict mode).
		DepSymbol*[8] out;
		usz count = member_resolver::find_dep_class_members(
			&idx, "Outer$Inner", "factory", false, "", &out);
		assert(count == 0,
			"expected static method hidden from instance receiver, got %d", (int)count);
	};
}
