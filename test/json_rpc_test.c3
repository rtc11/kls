module kls::test::json_rpc_test;

import std::collections::object;
import kls::json_rpc;

// ── json_escape_string tests ───────────────────────────────────────

fn void escape_empty_string() @test {
	@pool() {
		DString out;
		out.tinit();
		json_rpc::json_escape_string(&out, "");
		assert(out.str_view() == `""`, "expected empty quoted string");
	};
}

fn void escape_plain_text() @test {
	@pool() {
		DString out;
		out.tinit();
		json_rpc::json_escape_string(&out, "hello");
		assert(out.str_view() == `"hello"`, "expected '\"hello\"'");
	};
}

fn void escape_quotes() @test {
	@pool() {
		DString out;
		out.tinit();
		json_rpc::json_escape_string(&out, `say "hi"`);
		assert(out.str_view() == `"say \"hi\""`, "expected escaped quotes");
	};
}

fn void escape_backslash() @test {
	@pool() {
		DString out;
		out.tinit();
		json_rpc::json_escape_string(&out, `a\b`);
		assert(out.str_view() == `"a\\b"`, "expected escaped backslash");
	};
}

fn void escape_newline() @test {
	@pool() {
		DString out;
		out.tinit();
		json_rpc::json_escape_string(&out, "line1\nline2");
		assert(out.str_view() == `"line1\nline2"`, "expected escaped newline");
	};
}

fn void escape_tab() @test {
	@pool() {
		DString out;
		out.tinit();
		json_rpc::json_escape_string(&out, "a\tb");
		assert(out.str_view() == `"a\tb"`, "expected escaped tab");
	};
}

fn void escape_carriage_return() @test {
	@pool() {
		DString out;
		out.tinit();
		json_rpc::json_escape_string(&out, "a\rb");
		assert(out.str_view() == `"a\rb"`, "expected escaped CR");
	};
}

fn void escape_control_char() @test {
	@pool() {
		DString out;
		out.tinit();
		// ASCII 0x01 (SOH)
		char[1] buf = { 0x01 };
		json_rpc::json_escape_string(&out, (String)buf[:1]);
		assert(out.str_view() == `"\u0001"`, "expected \\u0001, got '%s'", out.str_view());
	};
}

fn void escape_null_char() @test {
	@pool() {
		DString out;
		out.tinit();
		char[1] buf = { 0x00 };
		json_rpc::json_escape_string(&out, (String)buf[:1]);
		assert(out.str_view() == `"\u0000"`, "expected \\u0000, got '%s'", out.str_view());
	};
}

// ── json_serialize tests ───────────────────────────────────────────

fn void serialize_null() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_null();
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view() == "null", "expected 'null'");
	};
}

fn void serialize_true() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_bool(true);
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view() == "true", "expected 'true'");
	};
}

fn void serialize_false() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_bool(false);
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view() == "false", "expected 'false'");
	};
}

fn void serialize_int() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_int(42, tmem);
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view() == "42", "expected '42', got '%s'", out.str_view());
	};
}

fn void serialize_negative_int() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_int(-7, tmem);
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view() == "-7", "expected '-7', got '%s'", out.str_view());
	};
}

fn void serialize_string() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_string("hello", tmem);
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view() == `"hello"`, "expected '\"hello\"'");
	};
}

fn void serialize_string_with_special_chars() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_string("a\nb", tmem);
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view() == `"a\nb"`, "expected escaped newline in string");
	};
}

fn void serialize_array() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* arr = object::new_obj(tmem);
		arr.push(object::new_int(1, tmem));
		arr.push(object::new_int(2, tmem));
		json_rpc::json_serialize(&out, arr);
		assert(out.str_view() == "[1,2]", "expected '[1,2]', got '%s'", out.str_view());
	};
}

fn void serialize_nested_object() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* inner = object::new_obj(tmem);
		inner.set("x", 1);

		Object* outer = object::new_obj(tmem);
		outer.set("inner", inner);
		outer.set("y", 2);

		json_rpc::json_serialize(&out, outer);
		String s = out.str_view();
		assert(s.contains(`"inner"`), "should contain 'inner' key");
		assert(s.contains(`"x":1`), "should contain x:1");
		assert(s.contains(`"y":2`), "should contain y:2");
	};
}

fn void serialize_empty_object() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_obj(tmem);
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view() == "{}", "expected '{}', got '%s'", out.str_view());
	};
}

fn void serialize_map_with_special_key() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_obj(tmem);
		obj.set("key\"with\"quotes", 1);
		json_rpc::json_serialize(&out, obj);
		assert(out.str_view().contains(`"key\"with\"quotes"`), "should escape key quotes");
	};
}

fn void serialize_float() @test {
	@pool() {
		DString out;
		out.tinit();
		Object* obj = object::new_float(3.14, tmem);
		json_rpc::json_serialize(&out, obj);
		String s = out.str_view();
		assert(s.starts_with("3.14"), "expected float starting with 3.14, got '%s'", s);
	};
}
