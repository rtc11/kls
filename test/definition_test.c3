module kls::test::definition_test;

import std::collections::object;
import kls::document;
import kls::lsp::definition;
import kls::workspace;
import kls::deps::jar_index;
import kls::deps::classpath;
import kls::lsp::hover;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, &ws, params)!!;

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
		Object* result = definition::handle_definition(&store, &ws, params)!!;

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
		Object* result = definition::handle_definition(&store, &ws, params)!!;

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
		Object* result = definition::handle_definition(&store, &ws, params)!!;

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
		Object* result = definition::handle_definition(&store, &ws, params)!!;

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
		Object* result = definition::handle_definition(&store, &ws, params)!!;

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
		Object* result = definition::handle_definition(&store, &ws, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

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
		Object* result = definition::handle_definition(&store, null, params)!!;

		assert(result != null, "expected a Location result for class type param T");

		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int col = start.get_int("character")!!;
		assert(col == 10, "expected col 10 (TYPE_PARAM T declaration), got %d", col);
	};
}

// ── Prefer file-name-matching symbol over nested same-name symbol ──

fn void definition_prefers_filename_matching_symbol() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index two files in package "models", both declaring "Simulering"
		// ApiError.kt has a nested enum class Simulering (symbol scanner finds it)
		ws.index_file("file:///models/ApiError.kt",
			"package models\nval Simulering = 1");
		// Simulering.kt has the top-level class Simulering
		ws.index_file("file:///models/Simulering.kt",
			"package models\ninterface Simulering");

		// The file under test imports models.* and references Simulering
		String content =
`package abetal
import models.*
fun foo(s: Simulering) {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Simulering" at line 2, col 11 ("fun foo(s: Simulering) {}")
		Object* params = make_params("file:///test.kt", 2, 11);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// Debug: check how many symbols are indexed
		assert(result != null, "expected a Location result");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///models/Simulering.kt",
			"expected Simulering.kt, got %s", uri);
	};
}

// ── Extension function receiver member navigation ──────────────────

fn void definition_extension_function_receiver_member() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a class with a member
		ws.index_file("file:///Oppdrag.kt",
			"package oppdrag\ndata class Oppdrag(val oppdrag110: Oppdrag110)");

		// File with an extension function on Oppdrag
		String content =
`import oppdrag.Oppdrag

fun Oppdrag.info(): String {
    return oppdrag110.toString()
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "oppdrag110" at line 3 ("    return oppdrag110.toString()")
		Object* params = make_params("file:///test.kt", 3, 11);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected a Location for extension receiver member");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///Oppdrag.kt",
			"expected Oppdrag.kt, got %s", uri);
	};
}

fn void definition_extension_function_local_shadows_receiver() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///MyClass.kt",
			"package pkg\nclass MyClass(val name: String)");

		// Local `name` should shadow the receiver member
		String content =
`import pkg.MyClass

fun MyClass.greet(): String {
    val name = "local"
    return name
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "name" at line 4 ("    return name")
		Object* params = make_params("file:///test.kt", 4, 11);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected a Location for local name");
		// Should resolve to the local val on line 3, NOT the workspace member
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///test.kt",
			"local should shadow receiver member, got %s", uri);
	};
}

// ── Explicit import prevents wrong workspace fallback ──────────────

fn void definition_qualified_type_in_type_arg() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a class in package "urskog.models"
		ws.index_file("file:///models/Utbetaling.kt",
			"package urskog.models\ndata class Utbetaling(val id: String)");

		// The file under test uses a star import and references the type
		// via its qualified name inside a type argument: json<models.Utbetaling>()
		String content =
`package urskog
import urskog.models.*
val serde = json<models.Utbetaling>()`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Utbetaling" in "models.Utbetaling" at line 2
		// "val serde = json<models.Utbetaling>()"
		//                          ^ col 24
		Object* params = make_params("file:///test.kt", 2, 24);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected a Location for qualified type in type arg");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///models/Utbetaling.kt",
			"expected Utbetaling.kt, got %s", uri);
	};
}

// Cursor on the qualifier part "models" in "models.Utbetaling" should also resolve
fn void definition_qualified_type_on_qualifier() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		ws.index_file("file:///models/Utbetaling.kt",
			"package urskog.models\ndata class Utbetaling(val id: String)");

		String content =
`package urskog
import urskog.models.*
val serde = json<models.Utbetaling>()`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "models" at line 2, col 17
		// "val serde = json<models.Utbetaling>()"
		//                   ^ col 17
		Object* params = make_params("file:///test.kt", 2, 17);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// "models" is a package qualifier — ideally should navigate to Utbetaling
		// but at minimum should not crash. Currently returns null which is acceptable
		// for a package name, but if we can resolve it, even better.
	};
}

// Cross-module: qualified type in type arg with Gradle module boundaries
fn void definition_qualified_type_cross_module() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Set up two Gradle modules: :urskog depends on :models
		ws.classpath.module_count = 2;

		// Module :models with source root
		GradleModule* models_mod = &ws.classpath.modules[0];
		models_mod.name = ":models".copy(mem);
		models_mod.dir = "/project/models".copy(mem);
		models_mod.src_roots[0] = "/project/models/src/main/kotlin".copy(mem);
		models_mod.src_root_count = 1;
		models_mod.dep_module_count = 0;

		// Module :urskog depends on :models
		GradleModule* urskog_mod = &ws.classpath.modules[1];
		urskog_mod.name = ":urskog".copy(mem);
		urskog_mod.dir = "/project/urskog".copy(mem);
		urskog_mod.src_roots[0] = "/project/urskog/src/main/kotlin".copy(mem);
		urskog_mod.src_root_count = 1;
		urskog_mod.dep_modules[0] = ":models".copy(mem);
		urskog_mod.dep_module_count = 1;

		// Index model class (URI maps to models src root)
		ws.index_file("file:///project/models/src/main/kotlin/models/Utbetaling.kt",
			"package urskog.models\ndata class Utbetaling(val id: String)");

		// The file under test is in :urskog module
		String content =
`package urskog
import urskog.models.*
val serde = json<models.Utbetaling>()`;
		store.open("file:///project/urskog/src/main/kotlin/urskog/Kafka.kt", "kotlin", 1, content);

		// Cursor on "Utbetaling" in "models.Utbetaling" at line 2, col 24
		Object* params = make_params("file:///project/urskog/src/main/kotlin/urskog/Kafka.kt", 2, 24);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		assert(result != null, "expected a Location for cross-module qualified type");
		String uri = result.get_string("uri")!!;
		assert(uri == "file:///project/models/src/main/kotlin/models/Utbetaling.kt",
			"expected Utbetaling.kt, got %s", uri);
	};
}

fn void definition_explicit_import_prevents_wrong_workspace_match() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a class with the same name but in a different package
		ws.index_file("file:///wrong/WrongOppdrag.kt",
			"package wrong.pkg\ndata class Oppdrag(val x: Int)");

		// Add the correct Oppdrag to the dep index (no real JAR, so source nav will fail)
		jar_index::add_dep_symbol(&ws.dep_index, "Oppdrag", "class Oppdrag",
			"no.trygdeetaten.skjema.oppdrag", "Oppdrag", "/nonexistent.jar", jar_index::DepSymbolKind.DEP_CLASS,
			null, 0);

		// The file has an explicit import for a DIFFERENT package's Oppdrag
		String content =
`import no.trygdeetaten.skjema.oppdrag.Oppdrag

fun foo(o: Oppdrag) {}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Oppdrag" at line 2
		Object* params = make_params("file:///test.kt", 2, 11);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// Should NOT resolve to the wrong package's Oppdrag.
		// Since the correct one is external and has no source JAR,
		// it should fall back to the import statement itself (line 0).
		assert(result != null, "expected fallback to import statement");
		String uri = result.get_string("uri") ?? "";
		assert(uri == "file:///test.kt",
			"expected navigation to import statement in same file, got %s", uri);
		assert(uri != "file:///wrong/WrongOppdrag.kt",
			"should not navigate to wrong-package Oppdrag, got %s", uri);
		Object* range = result.get("range") ?? null;
		if (range != null) {
			Object* start = range.get("start") ?? null;
			if (start != null) {
				int line = start.get_int("line") ?? -1;
				assert(line == 0, "expected import line 0, got %d", line);
			}
		}
	};
}

// ── Import-aware dot-member fallback (extension functions from deps) ──

fn void definition_dot_member_via_star_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add "respond" extension function from ktor (keyed by receiver type)
		jar_index::add_dep_symbol(&ws.dep_index,
			"respond", "fun respond(ApplicationCall, Any): Unit",
			"io.ktor.server.response", "ApplicationCall", "/fake/ktor.jar",
			DEP_METHOD, null, 0);

		// Code with star import and call.respond()
		String content =
			`import io.ktor.server.response.*

			fun handle(call: Any) {
				call.respond("hello")
			}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "respond" — find column
		// Line 3: "\t\t\t\tcall.respond("hello")" — "respond" after "call."
		Object* params = make_params("file:///test.kt", 3, 9);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// Result will be null since /fake/ktor.jar doesn't exist as source JAR,
		// but the import-aware dep lookup path is exercised without crashing.
	};
}

fn void definition_dot_member_via_explicit_import() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add "respond" extension function
		jar_index::add_dep_symbol(&ws.dep_index,
			"respond", "fun respond(ApplicationCall, Any): Unit",
			"io.ktor.server.response", "ApplicationCall", "/fake/ktor.jar",
			DEP_METHOD, null, 0);

		// Also add a different "respond" in another package (should NOT match)
		jar_index::add_dep_symbol(&ws.dep_index,
			"respond", "fun respond(HttpClient, Any): Unit",
			"io.ktor.client", "HttpClient", "/fake/ktor-client.jar",
			DEP_METHOD, null, 0);

		// Code with explicit import
		String content =
			`import io.ktor.server.response.respond

			fun handle(call: Any) {
				call.respond("hello")
			}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		Object* params = make_params("file:///test.kt", 3, 9);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// Exercised without crashing. Real sources would navigate.
	};
}

// ── Global fallback prefers top-level declaration before cursor ─────

fn void global_fallback_prefers_top_level_before_cursor() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Two classes both have `process()`, cursor on `process()` at top level
		// outside both classes. Global fallback should prefer top-level decl.
		String content =
			"fun process() {}\nclass Foo {\n    fun process() {}\n}\nfun main() { process() }";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "process" in main() call — line 4, col 14
		Object* params = make_params("file:///test.kt", 4, 14);
		Object* result = definition::handle_definition(&store, null, params)!!;

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should go to top-level fun process() at line 0, not the nested one at line 2
		assert(line == 0, "global fallback should prefer top-level decl, got line %d", line);
	};
}

// ── Global fallback prefers enclosing scope ────────────────────────

fn void global_fallback_prefers_declaration_before_use() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// `name` declared inside a class and at top level. Reference inside class
		// should resolve to inner class member, not top-level.
		String content =
			"val name = \"top\"\nclass Foo {\n    val name = \"inner\"\n    fun bar() { println(name) }\n}";
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "name" in bar() — line 3, col 25
		Object* params = make_params("file:///test.kt", 3, 25);
		Object* result = definition::handle_definition(&store, null, params)!!;

		assert(result != null, "expected a Location result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should go to class member `name` at line 2 (scope walk finds it)
		assert(line == 2, "should resolve to inner scope decl, got line %d", line);
	};
}

// Dot member with known receiver type should NOT fall back to import-based
// name matching. E.g., record.get("key") should NOT navigate to HashMap.get()
// just because java.util.* is imported.
fn void definition_dot_member_no_import_fallback_when_receiver_known() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();
		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Index a class "Record" with a member "value"
		ws.index_file("file:///record.kt",
			"class Record(val value: String)");

		// Index another class with a "get" method in a different file
		ws.index_file("file:///cache.kt",
			"class Cache {\n  fun get(key: String): String = \"\"\n}");

		// File under test: record.get("x") — Record has no "get" method
		String content =
`import java.util.*
fun test(record: Record) {
    record.get("x")
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "get" in "record.get" at line 2, col 11
		Object* params = make_params("file:///test.kt", 2, 11);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// "get" is not a member of Record, should return null rather than
		// incorrectly navigating to Cache.get or HashMap.get
		assert(result == null, "should NOT find definition for non-existent member");
	};
}

// Type-based overload disambiguation: when two overloads have the same
// name and param count, prefer the one whose param types match arg types.
fn void definition_overload_by_type() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		String content =
`fun process(input: String): String = input
fun process(input: Int): Int = input
fun main() {
    val x: String = "hello"
    process(x)
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "process" call at line 4, col 4
		Object* params = make_params("file:///test.kt", 4, 4);
		Object* result = definition::handle_definition(&store, null, params)!!;

		assert(result != null, "expected definition result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should go to line 0 (fun process(input: String)) not line 1 (fun process(input: Int))
		assert(line == 0, "expected String overload at line 0, got line %d", line);
	};
}

// ── extract_return_type_from_signature tests ─────────────────────

fn void definition_extract_return_type_fun() @test {
	String sig = "fun stream(): Stream<E>";
	String ret = definition::extract_return_type_from_signature(sig);
	assert(ret == "Stream<E>", "expected 'Stream<E>', got '%s'", ret);
}

fn void definition_extract_return_type_fun_with_params() @test {
	String sig = "fun add(element: E): Boolean";
	String ret = definition::extract_return_type_from_signature(sig);
	assert(ret == "Boolean", "expected 'Boolean', got '%s'", ret);
}

fn void definition_extract_return_type_val() @test {
	String sig = "val size: Int";
	String ret = definition::extract_return_type_from_signature(sig);
	assert(ret == "Int", "expected 'Int', got '%s'", ret);
}

fn void definition_extract_return_type_void() @test {
	String sig = "fun clear()";
	String ret = definition::extract_return_type_from_signature(sig);
	assert(ret == "", "expected empty for void, got '%s'", ret);
}

fn void definition_extract_return_type_nested_parens() @test {
	String sig = "fun map(transform: (T) -> R): List<R>";
	String ret = definition::extract_return_type_from_signature(sig);
	assert(ret == "List<R>", "expected 'List<R>', got '%s'", ret);
}

fn void definition_overload_by_named_arg() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		// Two overloads with same param count but different param names
		String src = `fun connect(host: String, port: Int) { }
fun connect(url: String, timeout: Int) { }
fun main() { connect(url = "http://x", timeout = 30) }`;
		//                    ^ cursor on "connect" at line 2, col 14
		store.open("file:///test.kt", "kotlin", 1, src);

		Object* params = make_params("file:///test.kt", 2, 14);
		Object* result = definition::handle_definition(&store, null, params)!!;
		assert(result != null, "expected a definition result");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		// Should pick the second overload (url, timeout) on line 1
		assert(line == 1, "expected line 1 (url/timeout overload), got %d", line);
	};
}

// ── Star import dep lookup: correct package ────────────────────────

fn void definition_star_import_picks_correct_package() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Two classes named "Properties" in different packages
		jar_index::add_dep_symbol(&ws.dep_index,
			"Properties", "class Properties", "com.sun.xml.fastinfoset.sax", "Properties", "/fake/fastinfoset.jar",
			DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&ws.dep_index,
			"Properties", "class Properties", "java.util", "Properties", "/fake/java.base.jmod",
			DEP_CLASS, null, 0);

		// Star import for java.util.* — should resolve to java.util.Properties
		String content = `import java.util.*
fun main() { val p = Properties() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "Properties" at line 1 — "    val p = Properties()" col 22
		Object* params = make_params("file:///test.kt", 1, 22);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// Source JAR is fake so resolve_dep_definition returns null,
		// but it should fall back to the import statement at line 0.
		assert(result != null, "expected result from star import lookup");
		Object* range = result.get("range")!!;
		Object* start = range.get("start")!!;
		int line = start.get_int("line")!!;
		assert(line == 0, "expected fallback to import at line 0, got %d", line);
	};
}

// ── No star import match: returns null ─────────────────────────────

fn void definition_no_star_import_match_returns_null() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Class in dep index but not matching any star import
		jar_index::add_dep_symbol(&ws.dep_index,
			"FakeWidget", "class FakeWidget", "com.example.widgets", "FakeWidget", "/fake/widgets.jar",
			DEP_CLASS, null, 0);

		// Star import for java.util.* — FakeWidget not in java.util
		String content = `import java.util.*
fun main() { val w = FakeWidget() }`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "FakeWidget" at line 1
		Object* params = make_params("file:///test.kt", 1, 22);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// No star import matches, no unfiltered fallback — should be null
		assert(result == null, "expected null when no import matches");
	};
}

// ── FQN dot-member: class member via fully-qualified reference ──────

fn void definition_fqn_class_member() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add StreamsConfig class and its field to dep_index
		jar_index::add_dep_symbol(&ws.dep_index,
			"StreamsConfig", "class StreamsConfig", "org.apache.kafka.streams", "StreamsConfig", "/fake/kafka.jar",
			DEP_CLASS, null, 0);
		jar_index::add_dep_symbol(&ws.dep_index,
			"NUM_STANDBY_REPLICAS_CONFIG", "val NUM_STANDBY_REPLICAS_CONFIG: String", "org.apache.kafka.streams", "StreamsConfig", "/fake/kafka.jar",
			DEP_FIELD, null, 0);

		// Fully-qualified reference: org.apache.kafka.streams.StreamsConfig.NUM_STANDBY_REPLICAS_CONFIG
		String content = `fun main() {
    val x = org.apache.kafka.streams.StreamsConfig.NUM_STANDBY_REPLICAS_CONFIG
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "NUM_STANDBY_REPLICAS_CONFIG" at line 1
		// "    val x = org.apache.kafka.streams.StreamsConfig.NUM_STANDBY_REPLICAS_CONFIG"
		// offset: "    val x = org.apache.kafka.streams.StreamsConfig." = 51 chars
		Object* params = make_params("file:///test.kt", 1, 51);
		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// Source JAR is fake so resolve_dep_definition returns null,
		// but the FQN path should be exercised without crashing.
		// With a real JAR this would return a location.
	};
}

// ── FQN: cursor on class name navigates to class ────────────────────

fn void definition_fqn_class_name() @test {
	@pool() {
		DocumentStore store;
		store.init();
		defer store.free();

		WorkspaceIndex ws;
		ws.init();
		defer ws.free();

		// Add StreamsConfig class to dep_index
		jar_index::add_dep_symbol(&ws.dep_index,
			"StreamsConfig", "class StreamsConfig", "org.apache.kafka.streams", "StreamsConfig", "/fake/kafka.jar",
			DEP_CLASS, null, 0);

		// Also add StreamsConfig to workspace (simulating libs.kafka.StreamsConfig)
		String ws_content = `package libs.kafka
class StreamsConfig(val additionalProperties: Any? = null)`;
		store.open("file:///libs/kafka/StreamsConfig.kt", "kotlin", 1, ws_content);
		ws.index_file("file:///libs/kafka/StreamsConfig.kt", ws_content);

		// File with FQN reference inside this[...]
		String content = `import libs.kafka.StreamsConfig

class Config {
    val kafka: StreamsConfig = StreamsConfig(
        additionalProperties = Properties().apply {
            this[org.apache.kafka.streams.StreamsConfig.NUM_STANDBY_REPLICAS_CONFIG] = 0
        }
    )
}`;
		store.open("file:///test.kt", "kotlin", 1, content);

		// Cursor on "StreamsConfig" in the FQN at line 5
		// "            this[org.apache.kafka.streams.StreamsConfig..."
		// 12 spaces + "this[" (5) + "org." (4) + "apache." (7) + "kafka." (6) + "streams." (8) = 42
		Object* params = make_params("file:///test.kt", 5, 42);

		// Verify token is found at this position
		Document* doc = store.get("file:///test.kt") ?? null;
		assert(doc != null, "document should exist");
		if (try tok = hover::find_token_at_position(doc.content, 5, 42)) {
			assert(tok.text == "StreamsConfig", "expected token 'StreamsConfig' at 5:42, got '%s'", tok.text);
		} else {
			assert(false, "no token found at line 5, col 42");
		}

		Object* result = definition::handle_definition(&store, &ws, params)!!;

		// Should NOT go to libs/kafka/StreamsConfig.kt (workspace match)
		// Should either go to dep source or return null (no source available)
		if (result != null) {
			String result_uri = result.get_string("uri")!!;
			assert(result_uri != "file:///libs/kafka/StreamsConfig.kt",
				"FQN should not resolve to workspace StreamsConfig, got uri=%s", result_uri);
		}
		// Returning null is acceptable (dep source unavailable)
	};
}
