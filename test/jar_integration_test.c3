module kls::test::jar_integration_test;

import std::io;
import std::compression::zip;
import kls::deps::jar_index;
import kls::deps::classfile;
import kls::deps::kotlin_metadata;
import kls::deps::source_nav;
import kls::deps::javadoc;

const String TEST_JAR = "resources/testlib.jar";
const String TEST_SOURCES_JAR = "resources/testlib-sources.jar";

// ══════════════════════════════════════════════════════════════════
// Helper: index the test JAR into a fresh DependencyIndex
// ══════════════════════════════════════════════════════════════════

fn DependencyIndex index_test_jar() {
	DependencyIndex idx;
	idx.init();
	idx.index_jar(TEST_JAR);
	return idx;
}

// Helper: find first symbol matching name and kind
fn DepSymbol* find_symbol(DependencyIndex* idx, String name, DepSymbolKind kind) {
	DepSymbol*[32] buf;
	usz count = idx.lookup_by_name(name, &buf);
	for (usz i = 0; i < count; i++) {
		if (buf[i].kind == kind) return buf[i];
	}
	return null;
}

// Helper: find any symbol matching name
fn DepSymbol* find_any(DependencyIndex* idx, String name) {
	DepSymbol*[32] buf;
	usz count = idx.lookup_by_name(name, &buf);
	if (count > 0) return buf[0];
	return null;
}

// Helper: count symbols matching name
fn usz count_symbols(DependencyIndex* idx, String name) {
	DepSymbol*[32] buf;
	return idx.lookup_by_name(name, &buf);
}

// Helper: count symbols matching name and kind
fn usz count_symbols_of_kind(DependencyIndex* idx, String name, DepSymbolKind kind) {
	DepSymbol*[32] buf;
	usz count = idx.lookup_by_name(name, &buf);
	usz result = 0;
	for (usz i = 0; i < count; i++) {
		if (buf[i].kind == kind) result++;
	}
	return result;
}

// ══════════════════════════════════════════════════════════════════
// JAR indexing: kind classification
// ══════════════════════════════════════════════════════════════════

fn void jar_index_class() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Animal", DEP_CLASS);
		assert(sym != null, "Animal should be indexed as DEP_CLASS");
		assert(sym.package_name == "com.test.lib", "expected package com.test.lib, got '%s'", sym.package_name);
	};
}

fn void jar_index_interface() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Describable", DEP_INTERFACE);
		assert(sym != null, "Describable should be indexed as DEP_INTERFACE");
	};
}

fn void jar_index_enum() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Color", DEP_ENUM);
		assert(sym != null, "Color should be indexed as DEP_ENUM");
	};
}

fn void jar_index_annotation() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Marker", DEP_ANNOTATION);
		assert(sym != null, "Marker should be indexed as DEP_ANNOTATION");
	};
}

fn void jar_index_data_class() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Point", DEP_CLASS);
		assert(sym != null, "Point data class should be indexed as DEP_CLASS");
	};
}

fn void jar_index_sealed_class() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Result", DEP_CLASS);
		assert(sym != null, "sealed class Result should be indexed as DEP_CLASS");
	};
}

fn void jar_index_object() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		// Object can be DEP_CLASS or DEP_OBJECT depending on heuristics
		DepSymbol* sym = find_any(&idx, "Registry");
		assert(sym != null, "object Registry should be indexed");
	};
}

fn void jar_index_abstract_class() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Shape", DEP_CLASS);
		assert(sym != null, "abstract class Shape should be indexed as DEP_CLASS");
	};
}

fn void jar_index_value_class() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Email", DEP_CLASS);
		assert(sym != null, "value class Email should be indexed as DEP_CLASS");
	};
}

fn void jar_index_generic_interface() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Repository", DEP_INTERFACE);
		assert(sym != null, "Repository<T> should be indexed as DEP_INTERFACE");
	};
}

fn void jar_index_generic_class() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Container", DEP_CLASS);
		assert(sym != null, "Container<T> should be indexed as DEP_CLASS");
	};
}

// ══════════════════════════════════════════════════════════════════
// JAR indexing: supertypes
// ══════════════════════════════════════════════════════════════════

fn void jar_index_class_supertypes() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Dog", DEP_CLASS);
		assert(sym != null, "Dog should be indexed");
		assert(sym.supertype_count >= 2, "Dog should have >= 2 supertypes (Animal, Describable), got %d", sym.supertype_count);

		// Check that both Animal and Describable appear
		bool has_animal = false;
		bool has_describable = false;
		for (usz i = 0; i < sym.supertype_count; i++) {
			if (sym.supertypes[i] == "Animal") has_animal = true;
			if (sym.supertypes[i] == "Describable") has_describable = true;
		}
		assert(has_animal, "Dog supertypes should include Animal");
		assert(has_describable, "Dog supertypes should include Describable");
	};
}

fn void jar_index_circle_extends_shape() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Circle", DEP_CLASS);
		assert(sym != null, "Circle should be indexed");
		bool has_shape = false;
		for (usz i = 0; i < sym.supertype_count; i++) {
			if (sym.supertypes[i] == "Shape") has_shape = true;
		}
		assert(has_shape, "Circle supertypes should include Shape");
	};
}

fn void jar_index_supertype_lookup() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		// Look up all classes implementing Describable
		DepSymbol*[16] buf;
		usz count = idx.lookup_by_supertype("Describable", &buf);
		assert(count >= 1, "should find >= 1 class implementing Describable, got %d", count);
		bool found_dog = false;
		for (usz i = 0; i < count; i++) {
			if (buf[i].name == "Dog") found_dog = true;
		}
		assert(found_dog, "Dog should appear in Describable supertype lookup");
	};
}

// ══════════════════════════════════════════════════════════════════
// JAR indexing: methods
// ══════════════════════════════════════════════════════════════════

fn void jar_index_top_level_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "greet", DEP_METHOD);
		assert(sym != null, "top-level fun greet should be indexed as DEP_METHOD");
		assert(sym.signature.len > 0, "greet should have a signature");
	};
}

fn void jar_index_method_signature_has_params() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "greet", DEP_METHOD);
		assert(sym != null, "greet should be indexed");
		// Signature should contain parameter info
		bool has_name_param = false;
		// Check signature contains "name" or "String" as param
		for (usz i = 0; i + 5 < sym.signature.len; i++) {
			if (sym.signature[i..i+5] == "String") {
				has_name_param = true;
				break;
			}
		}
		assert(has_name_param, "greet signature should mention String param, got '%s'", sym.signature);
	};
}

fn void jar_index_extension_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "capitalize2", DEP_METHOD);
		assert(sym != null, "String.capitalize2 extension should be indexed");
		// NOTE: extension receiver in signature depends on metadata parsing.
		// If metadata receiver detection works, sig shows "fun String.capitalize2(): String".
		// If fallback, sig shows "fun capitalize2(String): String".
		// Either way, "String" should appear in the signature.
		bool has_string = false;
		for (usz i = 0; i + 5 < sym.signature.len; i++) {
			if (sym.signature[i..i+5] == "String") {
				has_string = true;
				break;
			}
		}
		assert(has_string, "capitalize2 signature should mention String, got '%s'", sym.signature);
	};
}

fn void jar_index_generic_extension_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "secondOrNull", DEP_METHOD);
		assert(sym != null, "List<T>.secondOrNull should be indexed");
	};
}

fn void jar_index_companion_method() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "create", DEP_METHOD);
		assert(sym != null, "Animal.Companion.create should be indexed as DEP_METHOD");
		// Should be associated with Animal
		assert(sym.class_name == "Animal", "create should belong to Animal, got '%s'", sym.class_name);
	};
}

fn void jar_index_overloaded_functions() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		usz count = count_symbols_of_kind(&idx, "convert", DEP_METHOD);
		assert(count >= 2, "convert should have >= 2 overloads, got %d", count);
	};
}

fn void jar_index_suspend_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "fetchData", DEP_METHOD);
		assert(sym != null, "suspend fun fetchData should be indexed");
	};
}

fn void jar_index_class_method() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "speak", DEP_METHOD);
		assert(sym != null, "Animal.speak should be indexed as DEP_METHOD");
	};
}

fn void jar_index_interface_method() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "summary", DEP_METHOD);
		assert(sym != null, "Describable.summary should be indexed");
	};
}

fn void jar_index_enum_method() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "lighter", DEP_METHOD);
		assert(sym != null, "Color.lighter should be indexed");
	};
}

fn void jar_index_operator_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "plus", DEP_METHOD);
		assert(sym != null, "operator fun Point.plus should be indexed");
	};
}

fn void jar_index_infix_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "power", DEP_METHOD);
		assert(sym != null, "infix fun Int.power should be indexed");
	};
}

fn void jar_index_hof_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "transform", DEP_METHOD);
		assert(sym != null, "fun transform should be indexed");
	};
}

fn void jar_index_vararg_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "joinAll", DEP_METHOD);
		assert(sym != null, "fun joinAll(vararg) should be indexed");
	};
}

fn void jar_index_default_param_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "greetFull", DEP_METHOD);
		assert(sym != null, "fun greetFull with defaults should be indexed");
	};
}

fn void jar_index_tailrec_function() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "factorial", DEP_METHOD);
		assert(sym != null, "tailrec fun factorial should be indexed");
	};
}

fn void jar_index_lambda_receiver_signature() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "buildAnimal", DEP_METHOD);
		assert(sym != null, "fun buildAnimal should be indexed");
		// Signature should reference Animal as receiver in lambda param
		assert(sym.signature.len > 0, "buildAnimal should have a signature, got empty");
	};
}

fn void jar_index_data_class_method() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "distanceTo", DEP_METHOD);
		assert(sym != null, "Point.distanceTo should be indexed");
	};
}

fn void jar_index_generic_interface_method() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "findById", DEP_METHOD);
		assert(sym != null, "Repository.findById should be indexed");
	};
}

fn void jar_index_object_method() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "register", DEP_METHOD);
		assert(sym != null, "Registry.register should be indexed");
	};
}

// ══════════════════════════════════════════════════════════════════
// JAR indexing: fields / properties
// ══════════════════════════════════════════════════════════════════

fn void jar_index_class_field() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		// Kotlin val properties generate private backing fields + public getters.
		// The getter heuristic lowercases: getEntries() -> "entries" as DEP_FIELD.
		DepSymbol* sym = find_symbol(&idx, "entries", DEP_FIELD);
		assert(sym != null, "Registry.entries (via getEntries getter) should be indexed as DEP_FIELD");
	};
}

fn void jar_index_const_field() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		// Companion const — may be indexed under DEFAULT_SPECIES or via getter
		DepSymbol* sym = find_any(&idx, "DEFAULT_SPECIES");
		assert(sym != null, "Animal.DEFAULT_SPECIES const should be indexed");
	};
}

fn void jar_index_enum_property() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		// Enum constructor val params: getHex() -> "hex" as DEP_FIELD
		DepSymbol* sym = find_symbol(&idx, "hex", DEP_FIELD);
		assert(sym != null, "Color.hex (via getHex getter) should be indexed as DEP_FIELD");
	};
}

// ══════════════════════════════════════════════════════════════════
// JAR indexing: inner classes are skipped (except Companion)
// ══════════════════════════════════════════════════════════════════

fn void jar_index_inner_class_skipped() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		// Result$Success and Result$Error are inner classes — should be skipped
		DepSymbol* sym = find_symbol(&idx, "Success", DEP_CLASS);
		assert(sym == null, "inner class Result.Success should NOT be indexed as top-level");
	};
}

fn void jar_index_inner_iterator_skipped() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		// Container$ItemIterator is an inner class — should be skipped
		DepSymbol* sym = find_symbol(&idx, "ItemIterator", DEP_CLASS);
		assert(sym == null, "inner class ItemIterator should NOT be indexed");
	};
}

// ══════════════════════════════════════════════════════════════════
// Classfile parsing: real .class bytes from JAR
// ══════════════════════════════════════════════════════════════════

fn void classfile_parse_real_class() @test {
	@pool() {
		ZipArchive archive;
		if (try a = zip::open(tmem, TEST_JAR, "r")) {
			archive = a;
		} else {
			assert(false, "failed to open test JAR");
		}
		defer (void)archive.close();

		char[] data;
		if (try d = archive.read_file_all(tmem, "com/test/lib/Animal.class")) {
			data = d;
		} else {
			assert(false, "failed to read Animal.class");
		}

		ClassInfo info;
		if (catch excuse = classfile::parse_class(data, &info)) {
			assert(false, "failed to parse Animal.class: %s", excuse);
		}

		assert(info.class_name == "com/test/lib/Animal", "expected class_name com/test/lib/Animal, got '%s'", info.class_name);
		assert(info.super_name == "java/lang/Object", "expected super_name java/lang/Object, got '%s'", info.super_name);
		assert(info.method_count > 0, "Animal should have methods, got 0");
		assert(info.has_kotlin_metadata, "Animal should have Kotlin metadata");
		assert(info.metadata_kind == 1, "Animal metadata_kind should be 1 (class), got %d", info.metadata_kind);
	};
}

fn void classfile_parse_interface() @test {
	@pool() {
		ZipArchive archive;
		if (try a = zip::open(tmem, TEST_JAR, "r")) {
			archive = a;
		} else {
			assert(false, "failed to open test JAR");
		}
		defer (void)archive.close();

		char[] data;
		if (try d = archive.read_file_all(tmem, "com/test/lib/Describable.class")) {
			data = d;
		} else {
			assert(false, "failed to read Describable.class");
		}

		ClassInfo info;
		if (catch excuse = classfile::parse_class(data, &info)) {
			assert(false, "failed to parse Describable.class");
		}

		assert((info.access_flags & classfile::ACC_INTERFACE) != 0, "Describable should have ACC_INTERFACE flag");
		assert(info.has_kotlin_metadata, "Describable should have Kotlin metadata");
	};
}

fn void classfile_parse_enum() @test {
	@pool() {
		ZipArchive archive;
		if (try a = zip::open(tmem, TEST_JAR, "r")) {
			archive = a;
		} else {
			assert(false, "failed to open test JAR");
		}
		defer (void)archive.close();

		char[] data;
		if (try d = archive.read_file_all(tmem, "com/test/lib/Color.class")) {
			data = d;
		} else {
			assert(false, "failed to read Color.class");
		}

		ClassInfo info;
		if (catch excuse = classfile::parse_class(data, &info)) {
			assert(false, "failed to parse Color.class");
		}

		assert((info.access_flags & classfile::ACC_ENUM) != 0, "Color should have ACC_ENUM flag");
		assert(info.has_kotlin_metadata, "Color should have Kotlin metadata");
		assert(info.field_count > 0, "Color should have enum entry fields");
	};
}

fn void classfile_parse_annotation() @test {
	@pool() {
		ZipArchive archive;
		if (try a = zip::open(tmem, TEST_JAR, "r")) {
			archive = a;
		} else {
			assert(false, "failed to open test JAR");
		}
		defer (void)archive.close();

		char[] data;
		if (try d = archive.read_file_all(tmem, "com/test/lib/Marker.class")) {
			data = d;
		} else {
			assert(false, "failed to read Marker.class");
		}

		ClassInfo info;
		if (catch excuse = classfile::parse_class(data, &info)) {
			assert(false, "failed to parse Marker.class");
		}

		assert((info.access_flags & classfile::ACC_INTERFACE) != 0, "annotation should have ACC_INTERFACE");
		assert((info.access_flags & classfile::ACC_ANNOTATION) != 0, "Marker should have ACC_ANNOTATION flag");
	};
}

fn void classfile_parse_file_facade() @test {
	@pool() {
		ZipArchive archive;
		if (try a = zip::open(tmem, TEST_JAR, "r")) {
			archive = a;
		} else {
			assert(false, "failed to open test JAR");
		}
		defer (void)archive.close();

		char[] data;
		if (try d = archive.read_file_all(tmem, "com/test/lib/TestLibKt.class")) {
			data = d;
		} else {
			assert(false, "failed to read TestLibKt.class");
		}

		ClassInfo info;
		if (catch excuse = classfile::parse_class(data, &info)) {
			assert(false, "failed to parse TestLibKt.class");
		}

		assert(info.has_kotlin_metadata, "TestLibKt should have Kotlin metadata");
		assert(info.metadata_kind == 2, "TestLibKt metadata_kind should be 2 (file facade), got %d", info.metadata_kind);
		assert(info.method_count > 0, "TestLibKt should have top-level function methods");
	};
}

fn void classfile_parse_data_class_has_methods() @test {
	@pool() {
		ZipArchive archive;
		if (try a = zip::open(tmem, TEST_JAR, "r")) {
			archive = a;
		} else {
			assert(false, "failed to open test JAR");
		}
		defer (void)archive.close();

		char[] data;
		if (try d = archive.read_file_all(tmem, "com/test/lib/Point.class")) {
			data = d;
		} else {
			assert(false, "failed to read Point.class");
		}

		ClassInfo info;
		if (catch excuse = classfile::parse_class(data, &info)) {
			assert(false, "failed to parse Point.class");
		}

		// Data class should have copy, toString, hashCode, equals, componentN, plus our distanceTo
		assert(info.method_count >= 3, "Point should have >= 3 public methods, got %d", info.method_count);
		assert(info.has_kotlin_metadata, "Point should have Kotlin metadata");
	};
}

fn void classfile_parse_companion() @test {
	@pool() {
		ZipArchive archive;
		if (try a = zip::open(tmem, TEST_JAR, "r")) {
			archive = a;
		} else {
			assert(false, "failed to open test JAR");
		}
		defer (void)archive.close();

		char[] data;
		if (try d = archive.read_file_all(tmem, "com/test/lib/Animal$Companion.class")) {
			data = d;
		} else {
			assert(false, "failed to read Animal$Companion.class");
		}

		ClassInfo info;
		if (catch excuse = classfile::parse_class(data, &info)) {
			assert(false, "failed to parse Animal$Companion.class");
		}

		assert(info.class_name == "com/test/lib/Animal$Companion",
			"expected class_name com/test/lib/Animal$Companion, got '%s'", info.class_name);
		assert(info.method_count >= 1, "Companion should have >= 1 public method (create), got %d", info.method_count);
	};
}

// ══════════════════════════════════════════════════════════════════
// Source navigation: find source entry in sources JAR
// ══════════════════════════════════════════════════════════════════

fn void source_nav_find_entry_in_sources_jar() @test {
	@pool() {
		String entry = source_nav::find_source_entry_in_jar(TEST_SOURCES_JAR, "com.test.lib", "Animal") ?? "";
		assert(entry.len > 0, "should find source entry for Animal in sources JAR, got empty");
		// Should find com/test/lib/TestLib.kt (all classes in one file)
		bool has_kt = false;
		for (usz i = 0; i + 2 < entry.len; i++) {
			if (entry[i] == '.' && entry[i+1] == 'k' && entry[i+2] == 't') {
				has_kt = true;
				break;
			}
		}
		assert(has_kt, "source entry should be a .kt file, got '%s'", entry);
	};
}

fn void source_nav_find_symbol_position_class() @test {
	@pool() {
		String content = (String)std::io::file::load(tmem, "resources/TestLib.kt")!!;
		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "Animal", DEP_CLASS, &line, &col);
		assert(found, "should find 'class Animal' position in source");
		assert(line > 0, "line should be > 0, got %d", line);
	};
}

fn void source_nav_find_symbol_position_interface() @test {
	@pool() {
		String content = (String)std::io::file::load(tmem, "resources/TestLib.kt")!!;
		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "Describable", DEP_INTERFACE, &line, &col);
		assert(found, "should find 'interface Describable' position");
	};
}

fn void source_nav_find_symbol_position_enum() @test {
	@pool() {
		String content = (String)std::io::file::load(tmem, "resources/TestLib.kt")!!;
		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "Color", DEP_ENUM, &line, &col);
		assert(found, "should find 'enum class Color' position");
	};
}

fn void source_nav_find_symbol_position_function() @test {
	@pool() {
		String content = (String)std::io::file::load(tmem, "resources/TestLib.kt")!!;
		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "greet", DEP_METHOD, &line, &col);
		assert(found, "should find 'fun greet' position");
	};
}

fn void source_nav_find_symbol_position_object() @test {
	@pool() {
		String content = (String)std::io::file::load(tmem, "resources/TestLib.kt")!!;
		uint line = 0;
		uint col = 0;
		bool found = source_nav::find_symbol_position(content, "Registry", DEP_CLASS, &line, &col);
		assert(found, "should find 'object Registry' position");
	};
}

// ══════════════════════════════════════════════════════════════════
// Source navigation: build_source_candidates
// ══════════════════════════════════════════════════════════════════

fn void source_nav_candidates_for_class() @test {
	@pool() {
		String[4] candidates;
		usz count = source_nav::build_source_candidates("com.test.lib", "Animal", &candidates, 4);
		assert(count >= 2, "should generate >= 2 source candidates, got %d", count);
		// First candidate should be com/test/lib/Animal.kt
		assert(candidates[0] == "com/test/lib/Animal.kt", "first candidate should be .kt, got '%s'", candidates[0]);
	};
}

fn void source_nav_candidates_for_kt_facade() @test {
	@pool() {
		String[4] candidates;
		usz count = source_nav::build_source_candidates("com.test.lib", "TestLibKt", &candidates, 4);
		assert(count >= 3, "Kt facade should generate >= 3 candidates, got %d", count);
		// Should include stripped version: TestLib.kt
		bool found_stripped = false;
		for (usz i = 0; i < count; i++) {
			if (candidates[i] == "com/test/lib/TestLib.kt") {
				found_stripped = true;
				break;
			}
		}
		assert(found_stripped, "candidates for TestLibKt should include TestLib.kt");
	};
}

// ══════════════════════════════════════════════════════════════════
// Javadoc/KDoc extraction from source
// ══════════════════════════════════════════════════════════════════

fn void javadoc_clean_kdoc() @test {
	@pool() {
		String raw = "/**\n * Base class for all animals in the system.\n *\n * @param name the display name of the animal\n * @param age the age in years\n */";
		String cleaned = javadoc::clean_javadoc(raw);
		assert(cleaned.len > 0, "cleaned KDoc should not be empty");
		// Should contain the description
		bool has_base = false;
		for (usz i = 0; i + 3 < cleaned.len; i++) {
			if (cleaned[i] == 'B' && cleaned[i+1] == 'a' && cleaned[i+2] == 's' && cleaned[i+3] == 'e') {
				has_base = true;
				break;
			}
		}
		assert(has_base, "cleaned KDoc should contain 'Base', got '%s'", cleaned);
	};
}

// ══════════════════════════════════════════════════════════════════
// Metadata: verify receiver type detection for extension functions
// ══════════════════════════════════════════════════════════════════

fn void metadata_extension_function_has_receiver() @test {
	@pool() {
		ZipArchive archive;
		if (try a = zip::open(tmem, TEST_JAR, "r")) {
			archive = a;
		} else {
			assert(false, "failed to open test JAR");
		}
		defer (void)archive.close();

		char[] data;
		if (try d = archive.read_file_all(tmem, "com/test/lib/TestLibKt.class")) {
			data = d;
		} else {
			assert(false, "failed to read TestLibKt.class");
		}

		ClassInfo info;
		classfile::parse_class(data, &info)!!;
		assert(info.has_kotlin_metadata, "TestLibKt should have metadata");
		assert(info.metadata_kind == 2, "should be k=2");

		KmClass* km = mem::new(KmClass);
		defer mem::free(km);
		*km = {};
		bool ok = kotlin_metadata::parse_metadata(&info, km);
		assert(ok, "metadata parse should succeed");

		assert(km.function_count > 0, "should have functions");

		// Find capitalize2 in metadata functions — should have receiver type (extension function)
		bool found = false;
		bool has_receiver = false;
		for (usz i = 0; i < km.function_count; i++) {
			String name = kotlin_metadata::resolve_string(
				km.functions[i].name_id, info.metadata_d2[..], info.metadata_d2_len);
			if (name == "capitalize2") {
				found = true;
				has_receiver = km.functions[i].has_receiver_type;
				break;
			}
		}

		assert(found, "capitalize2 should exist in metadata functions (count=%d)", km.function_count);
		assert(has_receiver, "capitalize2 should have has_receiver_type=true in metadata");

		// Also check greet function has params and return type
		for (usz i = 0; i < km.function_count; i++) {
			String name = kotlin_metadata::resolve_string(
				km.functions[i].name_id, info.metadata_d2[..], info.metadata_d2_len);
			if (name == "greet") {
				assert(km.functions[i].has_return_type, "greet should have return type");
				assert(km.functions[i].param_count >= 1, "greet should have >= 1 param, got %d", km.functions[i].param_count);

				// Check return type resolves
				String ret = kotlin_metadata::resolve_km_type_to_string(
					&km.functions[i].return_type, km, info.metadata_d2[..], info.metadata_d2_len);
				assert(ret.len > 0, "greet return type should resolve");
				break;
			}
		}
	};
}

// ══════════════════════════════════════════════════════════════════
// End-to-end: index JAR + lookup + verify package/class associations
// ══════════════════════════════════════════════════════════════════

fn void jar_index_package_names_correct() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();

		DepSymbol* animal = find_symbol(&idx, "Animal", DEP_CLASS);
		assert(animal != null);
		assert(animal.package_name == "com.test.lib", "Animal package should be com.test.lib, got '%s'", animal.package_name);

		DepSymbol* greet = find_symbol(&idx, "greet", DEP_METHOD);
		assert(greet != null);
		assert(greet.package_name == "com.test.lib", "greet package should be com.test.lib, got '%s'", greet.package_name);
	};
}

fn void jar_index_class_name_associations() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();

		// Method on a class should have that class as class_name
		DepSymbol* speak = find_symbol(&idx, "speak", DEP_METHOD);
		assert(speak != null, "speak should be indexed");
		assert(speak.class_name == "Animal", "speak.class_name should be Animal, got '%s'", speak.class_name);

		// Top-level functions should have the Kt facade class
		DepSymbol* greet = find_symbol(&idx, "greet", DEP_METHOD);
		assert(greet != null, "greet should be indexed");
		assert(greet.class_name == "TestLibKt", "greet.class_name should be TestLibKt, got '%s'", greet.class_name);
	};
}

fn void jar_index_jar_path_set() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		DepSymbol* sym = find_symbol(&idx, "Animal", DEP_CLASS);
		assert(sym != null);
		assert(sym.jar_path == TEST_JAR, "jar_path should be '%s', got '%s'", TEST_JAR, sym.jar_path);
	};
}

fn void jar_index_total_symbol_count() @test {
	@pool() {
		DependencyIndex idx = index_test_jar();
		defer idx.free();
		// We have ~12 top-level classes (non-inner), each with methods/fields
		// Should have a reasonable number of symbols
		usz total = idx.symbols.len();
		assert(total >= 20, "should have >= 20 total symbols, got %d", total);
		assert(total < 500, "should have < 500 symbols (sanity check), got %d", total);
	};
}
