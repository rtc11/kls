module kls::test::definition_test;

import std::collections::object;
import kls::document;
import kls::lsp::definition;
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

// ── Go to function definition ──────────────────────────────────────

fn void definition_of_function_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun greet() {}\nfun main() { greet() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" in the call at line 1, col 13
		Object* params = make_params("file:///test.kt", 1, 13);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");

		String uri = result.get_string("uri")!!;
		assert(uri == "file:///test.kt", "expected same URI");

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 0, "expected line 0, got %d", line);
		assert(col == 4, "expected col 4, got %d", col);
	};
}

// ── Go to variable definition ──────────────────────────────────────

fn void definition_of_variable() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val x = 42\nval y = x + 1";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "x" at line 1, col 8
		Object* params = make_params("file:///test.kt", 1, 8);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 0, "expected line 0, got %d", line);
		assert(col == 4, "expected col 4, got %d", col);
	};
}

// ── Go to class definition ─────────────────────────────────────────

fn void definition_of_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Foo {}\nfun make(): Foo = Foo()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Foo" at line 1, col 18 (the constructor call)
		Object* params = make_params("file:///test.kt", 1, 18);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 0, "expected line 0, got %d", line);
		assert(col == 6, "expected col 6, got %d", col);
	};
}

// ── Cursor on keyword returns null ─────────────────────────────────

fn void definition_on_keyword_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun main() {}");

		// Cursor on "fun" keyword at col 0
		Object* params = make_params("file:///test.kt", 0, 0);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result == null, "expected null for keyword");
	};
}

// ── Identifier with no declaration returns null ────────────────────

fn void definition_no_declaration_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun main() { println(unknown) }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "unknown" at col 21
		Object* params = make_params("file:///test.kt", 0, 21);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result == null, "expected null when no declaration found");
	};
}

// ── Unknown document returns null ──────────────────────────────────

fn void definition_unknown_document() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		Object* params = make_params("file:///unknown.kt", 0, 0);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result == null, "expected null for unknown document");
	};
}

// ── Definition on the declaration itself ───────────────────────────

fn void definition_on_declaration_itself() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "fun foo() {}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "foo" at col 4 -- the declaration itself
		Object* params = make_params("file:///test.kt", 0, 4);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location even on declaration itself");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int col = start.get_int("character")!!;
		assert(col == 4, "expected col 4, got %d", col);
	};
}

// ── Location range includes full name length ───────────────────────

fn void definition_range_covers_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class MyWidget {}\nval w: MyWidget = MyWidget()";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "MyWidget" at line 1, col 19
		Object* params = make_params("file:///test.kt", 1, 19);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		Object* end_pos = range.get("end")!!;
		int start_col = start.get_int("character")!!;
		int end_col = end_pos.get_int("character")!!;
		// "MyWidget" is 8 chars, starts at col 6
		assert(start_col == 6, "expected start col 6, got %d", start_col);
		assert(end_col == 14, "expected end col 14, got %d", end_col);
	};
}

// ── Multiple declarations, finds first match ───────────────────────

fn void definition_finds_first_match() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Two functions named "doWork" -- should find the first one
		String content = "fun doWork() {}\nfun doWork(x: Int) {}\nfun main() { doWork() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "doWork" call at line 2
		Object* params = make_params("file:///test.kt", 2, 14);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 0, "expected first declaration at line 0, got %d", line);
	};
}

// ── Cursor on whitespace returns null ──────────────────────────────

fn void definition_on_whitespace() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		store.open("file:///test.kt", "kotlin", 1, "fun foo() {}");

		// Cursor on space between "fun" and "foo" (col 3)
		Object* params = make_params("file:///test.kt", 0, 3);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result == null, "expected null on whitespace");
	};
}

// ── Call context: prefers function over property ───────────────────

fn void definition_prefers_function_in_call_context() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// val module appears before fun module -- but cursor is on a call site
		String content =
			`val module = nob.module {
    name = "nob"
}

fun module(block: Int): Int {
    return block
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "module" in "nob.module {" at line 0, col 18
		Object* params = make_params("file:///test.kt", 0, 18);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should navigate to fun module on line 4, not val module on line 0
		assert(line == 4, "expected function declaration at line 4, got %d", line);
	};
}

fn void definition_prefers_function_with_paren_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "val greet = 42\nfun greet(name: String) {}\nfun main() { greet(\"hi\") }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "greet" in "greet("hi")" at line 2, col 13
		Object* params = make_params("file:///test.kt", 2, 13);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should navigate to fun greet on line 1, not val greet on line 0
		assert(line == 1, "expected function declaration at line 1, got %d", line);
	};
}

fn void definition_non_call_context_returns_first_match() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "module" used as a value (not called), should get the val
		String content = "val module = 42\nfun module() {}\nfun main() { val x = module }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "module" in "val x = module" at line 2
		// "val x = module }" -- "module" starts at col 21
		Object* params = make_params("file:///test.kt", 2, 21);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Non-call context: first match is val module on line 0
		assert(line == 0, "expected property declaration at line 0, got %d", line);
	};
}

// ── Member function via receiver (global fallback) ─────────────────

fn void definition_of_member_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "module" is a member function of class Nob, called via nob.module { }
		String content =
			`class Nob {
    fun module(block: Int): Int {
        return block
    }
}
fun main() {
    val nob = Nob()
    nob.module { }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "module" in "nob.module { }" at line 7, col 8
		Object* params = make_params("file:///test.kt", 7, 8);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location for member function");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		// "fun module(...)" is at line 1, col 8
		assert(line == 1, "expected member fun at line 1, got %d", line);
		assert(col == 8, "expected member fun at col 8, got %d", col);
	};
}

// ── Companion object function (global fallback) ────────────────────

fn void definition_of_companion_function() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// "new" is inside Nob's companion object, called via Nob.new(args)
		String content =
			`class Nob {
    companion object {
        fun new(args: Int): Nob {
            return Nob()
        }
    }
}
fun main() {
    val nob = Nob.new(42)
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "new" in "Nob.new(42)" at line 8, col 18
		Object* params = make_params("file:///test.kt", 8, 18);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location for companion fun");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// "fun new(...)" is at line 2
		assert(line == 2, "expected companion fun at line 2, got %d", line);
	};
}

// ── Nested class member (global fallback) ──────────────────────────

fn void definition_of_nested_class_member() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
			`class Outer {
    class Inner {
        fun doWork() {}
    }
}
fun main() {
    val i = Outer.Inner()
    i.doWork()
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "doWork" in "i.doWork()" at line 7, col 6
		Object* params = make_params("file:///test.kt", 7, 6);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location for nested member");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// "fun doWork()" is at line 2
		assert(line == 2, "expected nested fun at line 2, got %d", line);
	};
}

// ── Go to definition of local variable ─────────────────────────────

fn void definition_of_local_val() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun process() {
    val result = compute()
    println(result)
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "result" in "println(result)" at line 2, col 12
		Object* params = make_params("file:///test.kt", 2, 12);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for local val");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		// "val result" -- "result" starts at col 8 on line 1
		assert(line == 1, "expected local val at line 1, got %d", line);
		assert(col == 8, "expected local val at col 8, got %d", col);
	};
}

fn void definition_of_local_var() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun process() {
    var count = 0
    count = count + 1
    println(count)
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "count" in "println(count)" at line 3, col 12
		Object* params = make_params("file:///test.kt", 3, 12);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for local var");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		// "var count" -- "count" starts at col 8 on line 1
		assert(line == 1, "expected local var at line 1, got %d", line);
		assert(col == 8, "expected local var at col 8, got %d", col);
	};
}

// ── Go to definition of function parameter ─────────────────────────

fn void definition_of_function_param() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun greet(name: String) {
    println(name)
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "name" in "println(name)" at line 1, col 12
		Object* params = make_params("file:///test.kt", 1, 12);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for function param");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		// "fun greet(name: String)" -- "name" starts at col 10 on line 0
		assert(line == 0, "expected param at line 0, got %d", line);
		assert(col == 10, "expected param at col 10, got %d", col);
	};
}

// ── Go to definition of for-loop variable ──────────────────────────

fn void definition_of_for_loop_variable() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun process(items: List<String>) {
    for (item in items) {
        println(item)
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "item" in "println(item)" at line 2, col 16
		Object* params = make_params("file:///test.kt", 2, 16);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for for-loop variable");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		// "for (item in items)" -- "item" starts at col 9 on line 1
		assert(line == 1, "expected for-loop var at line 1, got %d", line);
		assert(col == 9, "expected for-loop var at col 9, got %d", col);
	};
}

// ── Go to definition of catch parameter ────────────────────────────

fn void definition_of_catch_param() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun process() {
    try {
        risky()
    } catch (e: Exception) {
        println(e)
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "e" in "println(e)" at line 4, col 16
		Object* params = make_params("file:///test.kt", 4, 16);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for catch parameter");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// "catch (e: Exception)" -- "e" is on line 3
		assert(line == 3, "expected catch param at line 3, got %d", line);
	};
}

// ── Local val shadows top-level val (scope-aware) ──────────────────

fn void definition_local_shadows_top_level() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`val name = "global"
fun process() {
    val name = "local"
    println(name)
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "name" in "println(name)" at line 3, col 12
		Object* params = make_params("file:///test.kt", 3, 12);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for shadowed local val");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should find the LOCAL val on line 2, not the top-level on line 0
		assert(line == 2, "expected local val at line 2, got %d", line);
	};
}

// ── Local variable in expression context ───────────────────────────

fn void definition_local_var_in_binary_expr() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun calculate() {
    val base = 10
    val result = base + 5
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "base" in "base + 5" at line 2, col 17
		Object* params = make_params("file:///test.kt", 2, 17);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for local val 'base'");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 1, "expected line 1 for 'base' decl, got %d", line);
		assert(col == 8, "expected col 8 for 'base' decl, got %d", col);
	};
}

fn void definition_fun_call_with_ast_context() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Function declared, then called with a trailing lambda (no parens)
		String content =
`fun process(action: () -> Unit) {}
fun main() {
    process { println("hello") }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "process" in the call at line 2, col 4
		Object* params = make_params("file:///test.kt", 2, 4);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for 'process' function");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 0, "expected line 0 for 'process' decl, got %d", line);
	};
}

fn void definition_local_var_in_member_chain() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun process() {
    val items = listOf(1, 2, 3)
    items.map { it * 2 }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "items" in "items.map { it * 2 }" at line 2, col 4
		Object* params = make_params("file:///test.kt", 2, 4);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for local val 'items'");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 1, "expected line 1 for 'items' decl, got %d", line);
	};
}

// ── Receiver lambda member definition ─────────────────────────────

fn void definition_of_receiver_lambda_member_data_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// src at line 6 inside the lambda should go to the data class param at line 0
		String content =
`data class Module(var src: String = "", var name: String = "")
fun module(block: Module.() -> Unit) {}
fun main() {
    module {
        name = "example"
        src = "src/main"
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "src" at line 5, col 8
		Object* params = make_params("file:///test.kt", 5, 8);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for receiver lambda member 'src'");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		// Should go to 'src' in data class Module at line 0
		assert(line == 0, "expected line 0 for Module.src, got %d", line);
	};
}

fn void definition_of_receiver_lambda_member_via_dot_call() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Member function in a class, called via dot expression
		String content =
`data class Config(var timeout: Int = 30, var debug: Boolean = false)
class Builder {
    fun configure(block: Config.() -> Unit) {}
}
fun main() {
    val b = Builder()
    b.configure {
        timeout = 60
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "timeout" at line 7, col 8
		Object* params = make_params("file:///test.kt", 7, 8);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for receiver lambda member 'timeout'");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should go to 'timeout' in data class Config at line 0
		assert(line == 0, "expected line 0 for Config.timeout, got %d", line);
	};
}

fn void definition_of_receiver_lambda_fun_member() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`class Builder {
    fun add(item: String) {}
}
fun build(block: Builder.() -> Unit) {}
fun main() {
    build {
        add("item1")
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "add" at line 6, col 8
		Object* params = make_params("file:///test.kt", 6, 8);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for receiver lambda member 'add'");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should go to 'add' in class Builder at line 1
		assert(line == 1, "expected line 1 for Builder.add, got %d", line);
	};
}

fn void definition_of_receiver_lambda_local_shadows_member() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Local 'src' declared inside the lambda should shadow the receiver member
		String content =
`data class Module(var src: String = "")
fun module(block: Module.() -> Unit) {}
fun main() {
    module {
        val src = "local"
        println(src)
    }
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "src" at line 5 in "println(src)"
		// The "src" there should go to the local "val src" at line 4, not Module.src
		Object* params = make_params("file:///test.kt", 5, 16);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected Location for local 'src'");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should go to 'val src' at line 4 (local shadows receiver member)
		assert(line == 4, "expected line 4 for local src, got %d", line);
	};
}

// ── Overload resolution: go-to-definition picks correct overload ───

fn void definition_overload_two_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun process(x: Int): String = ""
fun process(x: Int, y: Int): Boolean = true
fun main() {
    process(1, 2)
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "process" in the call at line 3 — process(1, 2) has 2 args
		Object* params = make_params("file:///test.kt", 3, 5);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should go to the 2-param overload at line 1
		assert(line == 1, "expected line 1 for 2-param overload, got %d", line);
	};
}

fn void definition_overload_zero_params() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun create(): String = ""
fun create(name: String): Int = 0
fun main() {
    create()
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "create" in create() call at line 3 — 0 args
		Object* params = make_params("file:///test.kt", 3, 5);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should go to the 0-param overload at line 0
		assert(line == 0, "expected line 0 for 0-param overload, got %d", line);
	};
}

// ── Dep-aware dot-member definition (JDK classes) ──────────────────

fn void definition_of_dep_dot_member_method() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add "System" class to dep_index
		jar_index::add_dep_symbol(&ws.dep_index,
			"System", "class System", "java.lang", "System", "/fake/java.base.jmod",
			DEP_CLASS, null, 0);

		// Add "nanoTime" method to dep_index
		jar_index::add_dep_symbol(&ws.dep_index,
			"nanoTime", "fun nanoTime(): Long", "java.lang", "System", "/fake/java.base.jmod",
			DEP_METHOD, null, 0);

		// Code referencing System.nanoTime()
		String content = "fun main() {\n    val t = System.nanoTime()\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "nanoTime" in System.nanoTime() at line 1
		// "    val t = System.nanoTime()" — "nanoTime" starts at col 19
		Object* params = make_params("file:///test.kt", 1, 19);
		Object* result = definition::handle_definition(&store, &ws, params);

		// Result will be null since /fake/java.base.jmod doesn't exist,
		// but the dep member lookup path is exercised without crashing.
		// In a real scenario with JAVA_HOME/lib/src.zip, this returns a Location.
	};
}

fn void definition_of_dep_dot_member_field() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add "System" class to dep_index
		jar_index::add_dep_symbol(&ws.dep_index,
			"System", "class System", "java.lang", "System", "/fake/java.base.jmod",
			DEP_CLASS, null, 0);

		// Add "out" field to dep_index
		jar_index::add_dep_symbol(&ws.dep_index,
			"out", "val out: PrintStream", "java.lang", "System", "/fake/java.base.jmod",
			DEP_FIELD, null, 0);

		// Code referencing System.out
		String content = "fun main() {\n    val o = System.out\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "out" in System.out at line 1
		// "    val o = System.out" — "out" starts at col 19
		Object* params = make_params("file:///test.kt", 1, 19);
		Object* result = definition::handle_definition(&store, &ws, params);

		// Same as above: null because no real source, but no crash
	};
}

fn void definition_dep_dot_member_unknown_class_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// dep_index has no "FakeClass"
		String content = "fun main() {\n    val t = FakeClass.method()\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "method" in FakeClass.method() at line 1
		// "    val t = FakeClass.method()" — "method" starts at col 22
		Object* params = make_params("file:///test.kt", 1, 22);
		Object* result = definition::handle_definition(&store, &ws, params);

		assert(result == null, "expected null for unknown dep class member");
	};
}

fn void definition_dep_dot_member_wrong_class_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add "Runtime" class and "nanoTime" on "System" — mismatched
		jar_index::add_dep_symbol(&ws.dep_index,
			"Runtime", "class Runtime", "java.lang", "Runtime", "/fake/java.base.jmod",
			DEP_CLASS, null, 0);

		jar_index::add_dep_symbol(&ws.dep_index,
			"nanoTime", "fun nanoTime(): Long", "java.lang", "System", "/fake/java.base.jmod",
			DEP_METHOD, null, 0);

		// Code referencing Runtime.nanoTime() — nanoTime doesn't belong to Runtime
		String content = "fun main() {\n    val t = Runtime.nanoTime()\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "nanoTime" at col 20
		Object* params = make_params("file:///test.kt", 1, 20);
		Object* result = definition::handle_definition(&store, &ws, params);

		// nanoTime belongs to System, not Runtime — should not resolve
		assert(result == null, "expected null when member doesn't match class");
	};
}

// ── Scope function definition (apply, let, etc.) ───────────────────

fn void definition_scope_fn_apply_not_bifunction() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add BiFunction.apply — the wrong target that was previously matched
		jar_index::add_dep_symbol(&ws.dep_index,
			"apply", "fun apply(t: Object, u: Object): Object", "java.util.function",
			"BiFunction", "/fake/java.base.jmod", DEP_METHOD, null, 0);

		// Add StandardKt class — the public facade from kotlin-stdlib.
		// The actual apply method is private (inline), so only the class is indexed.
		jar_index::add_dep_symbol(&ws.dep_index,
			"StandardKt", "class StandardKt", "kotlin",
			"StandardKt", "/fake/kotlin-stdlib.jar", DEP_CLASS, null, 0);

		// Code using .apply on a local variable
		String content = "class Builder {\n    fun build() = 42\n}\nfun main() {\n    val b = Builder().apply {\n        build()\n    }\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "apply" at line 4
		// "    val b = Builder().apply {" — "apply" starts at col 22
		Object* params = make_params("file:///test.kt", 4, 22);
		Object* result = definition::handle_definition(&store, &ws, params);

		// Result is null because /fake/kotlin-stdlib.jar doesn't exist on disk,
		// but crucially we do NOT navigate to BiFunction.java.
		// The scope function check short-circuits the dep fallback.
		assert(result == null, "expected null (no real sources), not BiFunction");
	};
}

fn void definition_scope_fn_let_not_dep_fallback() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add a hypothetical dep method named "let" on some class
		jar_index::add_dep_symbol(&ws.dep_index,
			"let", "fun let(): Unit", "com.example",
			"SomeClass", "/fake/some-lib.jar", DEP_METHOD, null, 0);

		// Add StandardKt class — the public facade from kotlin-stdlib
		jar_index::add_dep_symbol(&ws.dep_index,
			"StandardKt", "class StandardKt", "kotlin",
			"StandardKt", "/fake/kotlin-stdlib.jar", DEP_CLASS, null, 0);

		// Code using .let on a string
		String content = "fun main() {\n    val x = \"hello\".let { it.length }\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "let" at line 1
		// `    val x = "hello".let { it.length }` — "let" starts at col 22
		Object* params = make_params("file:///test.kt", 1, 22);
		Object* result = definition::handle_definition(&store, &ws, params);

		// Null because no real sources, but does NOT fall through to SomeClass.let
		assert(result == null, "expected null for scope fn let, not SomeClass");
	};
}

fn void definition_scope_fn_also_returns_null_without_deps() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// No dep symbols at all — just verify .also doesn't crash
		String content = "fun main() {\n    val x = listOf(1).also { println(it) }\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "also" at line 1
		// `    val x = listOf(1).also { println(it) }` — "also" starts at col 24
		Object* params = make_params("file:///test.kt", 1, 24);
		Object* result = definition::handle_definition(&store, &ws, params);

		assert(result == null, "expected null for .also with no deps");
	};
}

// ── Go to type parameter definition ────────────────────────────────

fn void definition_of_type_param_in_fun() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		//                  0123456789012345678901234567
		String content = "fun <T> identity(x: T): T = x";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "T" in return type at col 24
		Object* params = make_params("file:///test.kt", 0, 24);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result for type param T");

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		int col = start.get_int("character")!!;
		assert(line == 0, "expected line 0, got %d", line);
		assert(col == 5, "expected col 5 (TYPE_PARAM declaration), got %d", col);
	};
}

fn void definition_of_type_param_in_class() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content = "class Box<T>(val value: T)";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "T" in "val value: T" at col 24
		Object* params = make_params("file:///test.kt", 0, 24);
		Object* result = definition::handle_definition(&store, null, params);

		assert(result != null, "expected a Location result for class type param T");

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int col = start.get_int("character")!!;
		assert(col == 10, "expected col 10 (TYPE_PARAM T declaration), got %d", col);
	};
}
