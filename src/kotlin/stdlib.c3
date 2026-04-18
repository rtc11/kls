module kls::kotlin::stdlib;

// ── Stdlib symbol kinds ────────────────────────────────────────────

enum StdlibKind : int {
	FUNCTION,
	CLASS,
	INTERFACE,
	PROPERTY,
	METHOD,
	OBJECT,
	TYPEALIAS,
}

// ── Stdlib symbol entry ────────────────────────────────────────────

struct StdlibSymbol {
	String name;
	String signature;
	String package_name;
	String receiver;
	String doc;
	StdlibKind kind;
}

// ── Lookup functions ───────────────────────────────────────────────

/**
 * Find all stdlib symbols whose name starts with `prefix`.
 * Writes matching pointers into `out_buf` and returns the count.
 * If prefix is empty, returns nothing (too many results).
 */
fn usz lookup_by_prefix(String prefix, StdlibSymbol*[] out_buf) {
	if (prefix.len == 0 || out_buf.len == 0) return 0;

	usz count = 0;
	foreach (i, &sym : STDLIB_SYMBOLS) {
		if (count >= out_buf.len) break;
		if (sym.name.starts_with(prefix)) {
			out_buf[count] = sym;
			count++;
		}
	}
	return count;
}

/**
 * Find the first stdlib symbol matching `name` exactly.
 * Returns a pointer to the symbol or a fault.
 */
fn StdlibSymbol*? lookup_by_name(String name) {
	foreach (i, &sym : STDLIB_SYMBOLS) {
		if (sym.name == name) {
			return sym;
		}
	}
	return NOT_FOUND~;
}

/**
 * Find all stdlib symbols matching `name` exactly.
 * Writes matching pointers into `out_buf` and returns the count.
 */
fn usz lookup_all_by_name(String name, StdlibSymbol*[] out_buf) {
	if (out_buf.len == 0) return 0;

	usz count = 0;
	foreach (i, &sym : STDLIB_SYMBOLS) {
		if (count >= out_buf.len) break;
		if (sym.name == name) {
			out_buf[count] = sym;
			count++;
		}
	}
	return count;
}

/**
 * Find all stdlib symbols with the given receiver type name.
 * Also matches "Any" receiver symbols (available on all types)
 * and "Iterable" for Collection-like types.
 */
fn usz lookup_by_receiver(String receiver_type, StdlibSymbol*[] out_buf) {
	if (out_buf.len == 0 || receiver_type.len == 0) return 0;

	usz count = 0;
	foreach (i, &sym : STDLIB_SYMBOLS) {
		if (count >= out_buf.len) break;
		if (sym.receiver.len == 0) continue;

		if (sym.receiver == receiver_type ||
			sym.receiver == "Any" ||
			sym.receiver == "Any?" ||
			sym.receiver == "T") {
			out_buf[count] = sym;
			count++;
			continue;
		}

		// Match Iterable receiver for collection types
		if (sym.receiver == "Iterable" || sym.receiver == "Iterable<T>") {
			if (receiver_type == "List" || receiver_type == "MutableList" ||
				receiver_type == "Set" || receiver_type == "MutableSet" ||
				receiver_type == "Collection" || receiver_type == "Sequence") {
				out_buf[count] = sym;
				count++;
				continue;
			}
		}

		// Match Array receiver
		if (sym.receiver == "Array" || sym.receiver == "Array<T>") {
			if (receiver_type == "Array") {
				out_buf[count] = sym;
				count++;
			}
		}
	}
	return count;
}

/**
 * Return the total number of bundled stdlib symbols.
 */
fn usz symbol_count() {
	return STDLIB_SYMBOLS.len;
}

// ── Fault ──────────────────────────────────────────────────────────

faultdef NOT_FOUND;

// ── Embedded stdlib symbol data ────────────────────────────────────
//
// Covers the most commonly used declarations from kotlin-stdlib.
// Organised by category for readability. Each entry:
//   { name, signature, package, receiver, doc, kind }

const StdlibSymbol[*] STDLIB_SYMBOLS = {

	// ── Top-level I/O functions ────────────────────────────────────
	{ "println", "fun println(message: Any?): Unit", "kotlin.io", "", "Prints the given message and a newline to the standard output stream.", FUNCTION },
	{ "println", "fun println(): Unit", "kotlin.io", "", "Prints a newline to the standard output stream.", FUNCTION },
	{ "print", "fun print(message: Any?): Unit", "kotlin.io", "", "Prints the given message to the standard output stream.", FUNCTION },
	{ "readLine", "fun readLine(): String?", "kotlin.io", "", "Reads a line of input from stdin. Returns null on EOF.", FUNCTION },
	{ "readlnOrNull", "fun readlnOrNull(): String?", "kotlin.io", "", "Reads a line of input from stdin. Returns null on EOF.", FUNCTION },
	{ "readln", "fun readln(): String", "kotlin.io", "", "Reads a line of input from stdin. Throws on EOF.", FUNCTION },

	// ── Top-level utility functions ────────────────────────────────
	{ "TODO", "fun TODO(reason: String = \"\"): Nothing", "kotlin", "", "Always throws NotImplementedError.", FUNCTION },
	{ "error", "fun error(message: Any): Nothing", "kotlin", "", "Throws an IllegalStateException with the given message.", FUNCTION },
	{ "require", "fun require(value: Boolean, lazyMessage: () -> Any = ...): Unit", "kotlin", "", "Throws IllegalArgumentException if value is false.", FUNCTION },
	{ "requireNotNull", "fun <T : Any> requireNotNull(value: T?, lazyMessage: () -> Any = ...): T", "kotlin", "", "Throws IllegalArgumentException if value is null, otherwise returns the non-null value.", FUNCTION },
	{ "check", "fun check(value: Boolean, lazyMessage: () -> Any = ...): Unit", "kotlin", "", "Throws IllegalStateException if value is false.", FUNCTION },
	{ "checkNotNull", "fun <T : Any> checkNotNull(value: T?, lazyMessage: () -> Any = ...): T", "kotlin", "", "Throws IllegalStateException if value is null, otherwise returns the non-null value.", FUNCTION },
	{ "assert", "fun assert(value: Boolean, lazyMessage: () -> Any = ...): Unit", "kotlin", "", "Throws AssertionError if value is false and runtime assertions are enabled.", FUNCTION },

	// ── Scope functions ────────────────────────────────────────────
	{ "let", "fun <T, R> T.let(block: (T) -> R): R", "kotlin", "T", "Calls block with this value as argument and returns the result.", FUNCTION },
	{ "run", "fun <T, R> T.run(block: T.() -> R): R", "kotlin", "T", "Calls block with this value as receiver and returns the result.", FUNCTION },
	{ "run", "fun <R> run(block: () -> R): R", "kotlin", "", "Calls the specified block and returns its result.", FUNCTION },
	{ "also", "fun <T> T.also(block: (T) -> Unit): T", "kotlin", "T", "Calls block with this value as argument and returns this value.", FUNCTION },
	{ "apply", "fun <T> T.apply(block: T.() -> Unit): T", "kotlin", "T", "Calls block with this value as receiver and returns this value.", FUNCTION },
	{ "with", "fun <T, R> with(receiver: T, block: T.() -> R): R", "kotlin", "", "Calls block with the given receiver as this and returns the result.", FUNCTION },
	{ "takeIf", "fun <T> T.takeIf(predicate: (T) -> Boolean): T?", "kotlin", "T", "Returns this value if it satisfies the predicate, or null otherwise.", FUNCTION },
	{ "takeUnless", "fun <T> T.takeUnless(predicate: (T) -> Boolean): T?", "kotlin", "T", "Returns this value if it does not satisfy the predicate, or null otherwise.", FUNCTION },
	{ "repeat", "fun repeat(times: Int, action: (Int) -> Unit): Unit", "kotlin", "", "Executes the given action the specified number of times.", FUNCTION },

	// ── Collection factory functions ───────────────────────────────
	{ "listOf", "fun <T> listOf(vararg elements: T): List<T>", "kotlin.collections", "", "Returns a new read-only list of the given elements.", FUNCTION },
	{ "listOf", "fun <T> listOf(): List<T>", "kotlin.collections", "", "Returns an empty read-only list.", FUNCTION },
	{ "listOfNotNull", "fun <T : Any> listOfNotNull(vararg elements: T?): List<T>", "kotlin.collections", "", "Returns a new read-only list of only the non-null elements.", FUNCTION },
	{ "mutableListOf", "fun <T> mutableListOf(vararg elements: T): MutableList<T>", "kotlin.collections", "", "Returns a new MutableList with the given elements.", FUNCTION },
	{ "arrayListOf", "fun <T> arrayListOf(vararg elements: T): ArrayList<T>", "kotlin.collections", "", "Returns a new ArrayList with the given elements.", FUNCTION },
	{ "emptyList", "fun <T> emptyList(): List<T>", "kotlin.collections", "", "Returns an empty read-only list.", FUNCTION },
	{ "buildList", "fun <E> buildList(builderAction: MutableList<E>.() -> Unit): List<E>", "kotlin.collections", "", "Builds a new read-only List by populating a MutableList.", FUNCTION },
	{ "mapOf", "fun <K, V> mapOf(vararg pairs: Pair<K, V>): Map<K, V>", "kotlin.collections", "", "Returns a new read-only map with the given key-value pairs.", FUNCTION },
	{ "mutableMapOf", "fun <K, V> mutableMapOf(vararg pairs: Pair<K, V>): MutableMap<K, V>", "kotlin.collections", "", "Returns a new MutableMap with the given key-value pairs.", FUNCTION },
	{ "hashMapOf", "fun <K, V> hashMapOf(vararg pairs: Pair<K, V>): HashMap<K, V>", "kotlin.collections", "", "Returns a new HashMap with the given key-value pairs.", FUNCTION },
	{ "linkedMapOf", "fun <K, V> linkedMapOf(vararg pairs: Pair<K, V>): LinkedHashMap<K, V>", "kotlin.collections", "", "Returns a new LinkedHashMap with the given key-value pairs.", FUNCTION },
	{ "emptyMap", "fun <K, V> emptyMap(): Map<K, V>", "kotlin.collections", "", "Returns an empty read-only map.", FUNCTION },
	{ "buildMap", "fun <K, V> buildMap(builderAction: MutableMap<K, V>.() -> Unit): Map<K, V>", "kotlin.collections", "", "Builds a new read-only Map by populating a MutableMap.", FUNCTION },
	{ "setOf", "fun <T> setOf(vararg elements: T): Set<T>", "kotlin.collections", "", "Returns a new read-only set with the given elements.", FUNCTION },
	{ "mutableSetOf", "fun <T> mutableSetOf(vararg elements: T): MutableSet<T>", "kotlin.collections", "", "Returns a new MutableSet with the given elements.", FUNCTION },
	{ "hashSetOf", "fun <T> hashSetOf(vararg elements: T): HashSet<T>", "kotlin.collections", "", "Returns a new HashSet with the given elements.", FUNCTION },
	{ "emptySet", "fun <T> emptySet(): Set<T>", "kotlin.collections", "", "Returns an empty read-only set.", FUNCTION },
	{ "buildSet", "fun <E> buildSet(builderAction: MutableSet<E>.() -> Unit): Set<E>", "kotlin.collections", "", "Builds a new read-only Set by populating a MutableSet.", FUNCTION },
	{ "sequenceOf", "fun <T> sequenceOf(vararg elements: T): Sequence<T>", "kotlin.sequences", "", "Returns a sequence of the given elements.", FUNCTION },

	// ── Array factory functions ─────────────────────────────────────
	{ "arrayOf", "fun <T> arrayOf(vararg elements: T): Array<T>", "kotlin", "", "Returns an array of the given elements.", FUNCTION },
	{ "intArrayOf", "fun intArrayOf(vararg elements: Int): IntArray", "kotlin", "", "Returns an IntArray of the given elements.", FUNCTION },
	{ "longArrayOf", "fun longArrayOf(vararg elements: Long): LongArray", "kotlin", "", "Returns a LongArray of the given elements.", FUNCTION },
	{ "doubleArrayOf", "fun doubleArrayOf(vararg elements: Double): DoubleArray", "kotlin", "", "Returns a DoubleArray of the given elements.", FUNCTION },
	{ "floatArrayOf", "fun floatArrayOf(vararg elements: Float): FloatArray", "kotlin", "", "Returns a FloatArray of the given elements.", FUNCTION },
	{ "booleanArrayOf", "fun booleanArrayOf(vararg elements: Boolean): BooleanArray", "kotlin", "", "Returns a BooleanArray of the given elements.", FUNCTION },
	{ "charArrayOf", "fun charArrayOf(vararg elements: Char): CharArray", "kotlin", "", "Returns a CharArray of the given elements.", FUNCTION },
	{ "byteArrayOf", "fun byteArrayOf(vararg elements: Byte): ByteArray", "kotlin", "", "Returns a ByteArray of the given elements.", FUNCTION },
	{ "shortArrayOf", "fun shortArrayOf(vararg elements: Short): ShortArray", "kotlin", "", "Returns a ShortArray of the given elements.", FUNCTION },
	{ "emptyArray", "fun <T> emptyArray(): Array<T>", "kotlin", "", "Returns an empty array.", FUNCTION },

	// ── Pair / Triple ──────────────────────────────────────────────
	{ "to", "infix fun <A, B> A.to(that: B): Pair<A, B>", "kotlin", "A", "Creates a Pair from this and that.", FUNCTION },
	{ "Pair", "class Pair<out A, out B>(val first: A, val second: B)", "kotlin", "", "Represents a pair of two values.", CLASS },
	{ "Triple", "class Triple<out A, out B, out C>(val first: A, val second: B, val third: C)", "kotlin", "", "Represents a triple of three values.", CLASS },

	// ── Lazy ───────────────────────────────────────────────────────
	{ "lazy", "fun <T> lazy(initializer: () -> T): Lazy<T>", "kotlin", "", "Creates a Lazy instance that uses the given initializer function.", FUNCTION },
	{ "lazy", "fun <T> lazy(mode: LazyThreadSafetyMode, initializer: () -> T): Lazy<T>", "kotlin", "", "Creates a Lazy instance with the specified thread-safety mode.", FUNCTION },
	{ "Lazy", "interface Lazy<out T>", "kotlin", "", "Represents a value with lazy initialization.", INTERFACE },
	{ "lazyOf", "fun <T> lazyOf(value: T): Lazy<T>", "kotlin", "", "Creates a Lazy instance that is already initialized with the given value.", FUNCTION },

	// ── Math / comparison ──────────────────────────────────────────
	{ "maxOf", "fun <T : Comparable<T>> maxOf(a: T, b: T): T", "kotlin.comparisons", "", "Returns the greater of two values.", FUNCTION },
	{ "minOf", "fun <T : Comparable<T>> minOf(a: T, b: T): T", "kotlin.comparisons", "", "Returns the smaller of two values.", FUNCTION },

	// ── Common classes ─────────────────────────────────────────────
	{ "String", "class String : Comparable<String>, CharSequence", "kotlin", "", "Represents a string of characters.", CLASS },
	{ "Int", "class Int : Comparable<Int>, Number", "kotlin", "", "Represents a 32-bit signed integer.", CLASS },
	{ "Long", "class Long : Comparable<Long>, Number", "kotlin", "", "Represents a 64-bit signed integer.", CLASS },
	{ "Double", "class Double : Comparable<Double>, Number", "kotlin", "", "Represents a double-precision 64-bit floating point number.", CLASS },
	{ "Float", "class Float : Comparable<Float>, Number", "kotlin", "", "Represents a single-precision 32-bit floating point number.", CLASS },
	{ "Boolean", "class Boolean : Comparable<Boolean>", "kotlin", "", "Represents a boolean value (true or false).", CLASS },
	{ "Char", "class Char : Comparable<Char>", "kotlin", "", "Represents a 16-bit Unicode character.", CLASS },
	{ "Byte", "class Byte : Comparable<Byte>, Number", "kotlin", "", "Represents a signed 8-bit integer.", CLASS },
	{ "Short", "class Short : Comparable<Short>, Number", "kotlin", "", "Represents a signed 16-bit integer.", CLASS },
	{ "Any", "open class Any", "kotlin", "", "The root of the Kotlin class hierarchy. Every class has Any as a superclass.", CLASS },
	{ "Unit", "object Unit", "kotlin", "", "Type with only one value: the Unit object. Corresponds to void in Java.", OBJECT },
	{ "Nothing", "class Nothing", "kotlin", "", "A type that has no instances. Used for functions that never return.", CLASS },
	{ "Number", "abstract class Number", "kotlin", "", "Superclass for all platform numeric types.", CLASS },
	{ "Enum", "abstract class Enum<E : Enum<E>> : Comparable<E>", "kotlin", "", "The common base class of all enum classes.", CLASS },

	// ── Collection types ───────────────────────────────────────────
	{ "List", "interface List<out E> : Collection<E>", "kotlin.collections", "", "A generic ordered collection of elements. Read-only.", INTERFACE },
	{ "MutableList", "interface MutableList<E> : List<E>, MutableCollection<E>", "kotlin.collections", "", "A generic ordered mutable collection of elements.", INTERFACE },
	{ "Map", "interface Map<K, out V>", "kotlin.collections", "", "A collection of key-value pairs. Read-only.", INTERFACE },
	{ "MutableMap", "interface MutableMap<K, V> : Map<K, V>", "kotlin.collections", "", "A modifiable collection of key-value pairs.", INTERFACE },
	{ "Set", "interface Set<out E> : Collection<E>", "kotlin.collections", "", "A generic unordered collection of elements that does not support duplicates.", INTERFACE },
	{ "MutableSet", "interface MutableSet<E> : Set<E>, MutableCollection<E>", "kotlin.collections", "", "A modifiable collection that does not support duplicates.", INTERFACE },
	{ "Collection", "interface Collection<out E> : Iterable<E>", "kotlin.collections", "", "A generic collection of elements. Read-only.", INTERFACE },
	{ "MutableCollection", "interface MutableCollection<E> : Collection<E>, MutableIterable<E>", "kotlin.collections", "", "A generic modifiable collection of elements.", INTERFACE },
	{ "Iterable", "interface Iterable<out T>", "kotlin.collections", "", "Classes that inherit from this interface can be iterated with a for-loop.", INTERFACE },
	{ "MutableIterable", "interface MutableIterable<out T> : Iterable<T>", "kotlin.collections", "", "Classes that inherit from this interface can produce a MutableIterator.", INTERFACE },
	{ "Iterator", "interface Iterator<out T>", "kotlin.collections", "", "An iterator over a collection or another entity that can be iterated.", INTERFACE },
	{ "MutableIterator", "interface MutableIterator<out T> : Iterator<T>", "kotlin.collections", "", "An iterator over a mutable collection that supports removal.", INTERFACE },
	{ "Array", "class Array<T>", "kotlin", "", "Represents an array. Use arrayOf() to create.", CLASS },
	{ "ArrayList", "class ArrayList<E> : MutableList<E>", "kotlin.collections", "", "A resizable array-backed list implementation.", CLASS },
	{ "HashMap", "class HashMap<K, V> : MutableMap<K, V>", "kotlin.collections", "", "Hash table based implementation of MutableMap.", CLASS },
	{ "HashSet", "class HashSet<E> : MutableSet<E>", "kotlin.collections", "", "Hash table based implementation of MutableSet.", CLASS },
	{ "LinkedHashMap", "class LinkedHashMap<K, V> : MutableMap<K, V>", "kotlin.collections", "", "Hash table and linked list implementation of MutableMap preserving insertion order.", CLASS },
	{ "LinkedHashSet", "class LinkedHashSet<E> : MutableSet<E>", "kotlin.collections", "", "Hash table and linked list implementation of MutableSet preserving insertion order.", CLASS },
	{ "Sequence", "interface Sequence<out T>", "kotlin.sequences", "", "A sequence of values that are evaluated lazily.", INTERFACE },

	// ── Other common types ─────────────────────────────────────────
	{ "Comparable", "interface Comparable<in T>", "kotlin", "", "Classes that have a natural ordering implement this interface.", INTERFACE },
	{ "CharSequence", "interface CharSequence", "kotlin", "", "Represents a readable sequence of Char values.", INTERFACE },
	{ "Regex", "class Regex(pattern: String)", "kotlin.text", "", "Represents a compiled regular expression.", CLASS },
	{ "MatchResult", "interface MatchResult", "kotlin.text", "", "Represents the results of a single regular expression match.", INTERFACE },
	{ "StringBuilder", "class StringBuilder : CharSequence, Appendable", "kotlin.text", "", "A mutable sequence of characters for building strings efficiently.", CLASS },
	{ "Appendable", "interface Appendable", "kotlin.text", "", "An object to which characters and character sequences can be appended.", INTERFACE },
	{ "Charset", "abstract class Charset", "kotlin.text", "", "A named mapping between characters and bytes.", CLASS },
	{ "Charsets", "object Charsets", "kotlin.text", "", "Provides constants for standard charsets. UTF_8, US_ASCII, ISO_8859_1, UTF_16, UTF_16BE, UTF_16LE, UTF_32, UTF_32BE, UTF_32LE.", OBJECT },
	{ "Result", "class Result<out T>", "kotlin", "", "A discriminated union that encapsulates a successful outcome or a failure.", CLASS },
	{ "Exception", "open class Exception : Throwable", "kotlin", "", "The base class for all exceptions.", CLASS },
	{ "RuntimeException", "open class RuntimeException : Exception", "kotlin", "", "The base class for runtime exceptions.", CLASS },
	{ "IllegalStateException", "class IllegalStateException : RuntimeException", "kotlin", "", "Thrown to indicate an illegal or inappropriate state.", CLASS },
	{ "IllegalArgumentException", "class IllegalArgumentException : RuntimeException", "kotlin", "", "Thrown to indicate an illegal or inappropriate argument.", CLASS },
	{ "NullPointerException", "class NullPointerException : RuntimeException", "kotlin", "", "Thrown when a null reference is used where a non-null value is expected.", CLASS },
	{ "IndexOutOfBoundsException", "class IndexOutOfBoundsException : RuntimeException", "kotlin", "", "Thrown to indicate an index is out of range.", CLASS },
	{ "UnsupportedOperationException", "class UnsupportedOperationException : RuntimeException", "kotlin", "", "Thrown to indicate an unsupported operation.", CLASS },
	{ "NoSuchElementException", "class NoSuchElementException : RuntimeException", "kotlin", "", "Thrown when a requested element does not exist.", CLASS },
	{ "ConcurrentModificationException", "class ConcurrentModificationException : RuntimeException", "kotlin", "", "Thrown when a collection is modified during iteration.", CLASS },
	{ "NumberFormatException", "class NumberFormatException : IllegalArgumentException", "kotlin", "", "Thrown when a string cannot be converted to a number.", CLASS },
	{ "ClassCastException", "class ClassCastException : RuntimeException", "kotlin", "", "Thrown when an object cannot be cast to the desired type.", CLASS },
	{ "ArithmeticException", "class ArithmeticException : RuntimeException", "kotlin", "", "Thrown when an arithmetic operation produces an exceptional condition.", CLASS },
	{ "Throwable", "open class Throwable(message: String?, cause: Throwable?)", "kotlin", "", "The base class for all errors and exceptions.", CLASS },
	{ "NotImplementedError", "class NotImplementedError : Error", "kotlin", "", "Thrown by TODO() to indicate unfinished code.", CLASS },

	// ── Ranges / progressions ──────────────────────────────────────
	{ "IntRange", "class IntRange(start: Int, endInclusive: Int) : IntProgression, ClosedRange<Int>", "kotlin.ranges", "", "A range of values of type Int.", CLASS },
	{ "LongRange", "class LongRange(start: Long, endInclusive: Long) : LongProgression, ClosedRange<Long>", "kotlin.ranges", "", "A range of values of type Long.", CLASS },
	{ "CharRange", "class CharRange(start: Char, endInclusive: Char) : CharProgression, ClosedRange<Char>", "kotlin.ranges", "", "A range of values of type Char.", CLASS },
	{ "IntProgression", "open class IntProgression : Iterable<Int>", "kotlin.ranges", "", "A progression of values of type Int.", CLASS },
	{ "ClosedRange", "interface ClosedRange<T : Comparable<T>>", "kotlin.ranges", "", "Represents a range of values with both endpoints included.", INTERFACE },
	{ "until", "infix fun Int.until(to: Int): IntRange", "kotlin.ranges", "Int", "Creates a range from this value up to but excluding the specified to value.", FUNCTION },
	{ "downTo", "infix fun Int.downTo(to: Int): IntProgression", "kotlin.ranges", "Int", "Returns a progression from this value down to the specified to value.", FUNCTION },
	{ "step", "infix fun IntProgression.step(step: Int): IntProgression", "kotlin.ranges", "IntProgression", "Returns a progression with the given step value.", FUNCTION },

	// ── String extension methods ───────────────────────────────────
	{ "length", "val String.length: Int", "kotlin", "String", "Returns the length of this string.", PROPERTY },
	{ "isEmpty", "fun String.isEmpty(): Boolean", "kotlin.text", "String", "Returns true if this string is empty.", METHOD },
	{ "isNotEmpty", "fun String.isNotEmpty(): Boolean", "kotlin.text", "String", "Returns true if this string is not empty.", METHOD },
	{ "isBlank", "fun String.isBlank(): Boolean", "kotlin.text", "String", "Returns true if this string is empty or consists solely of whitespace.", METHOD },
	{ "isNotBlank", "fun String.isNotBlank(): Boolean", "kotlin.text", "String", "Returns true if this string is not empty and does not consist solely of whitespace.", METHOD },
	{ "isNullOrEmpty", "fun String?.isNullOrEmpty(): Boolean", "kotlin.text", "String?", "Returns true if this string is null or empty.", METHOD },
	{ "isNullOrBlank", "fun String?.isNullOrBlank(): Boolean", "kotlin.text", "String?", "Returns true if this string is null, empty, or consists solely of whitespace.", METHOD },
	{ "trim", "fun String.trim(): String", "kotlin.text", "String", "Returns a string with leading and trailing whitespace removed.", METHOD },
	{ "trimStart", "fun String.trimStart(): String", "kotlin.text", "String", "Returns a string with leading whitespace removed.", METHOD },
	{ "trimEnd", "fun String.trimEnd(): String", "kotlin.text", "String", "Returns a string with trailing whitespace removed.", METHOD },
	{ "split", "fun String.split(vararg delimiters: String, ignoreCase: Boolean = false, limit: Int = 0): List<String>", "kotlin.text", "String", "Splits this string around matches of the given delimiters.", METHOD },
	{ "replace", "fun String.replace(oldValue: String, newValue: String, ignoreCase: Boolean = false): String", "kotlin.text", "String", "Returns a new string with all occurrences of oldValue replaced with newValue.", METHOD },
	{ "replaceFirst", "fun String.replaceFirst(oldValue: String, newValue: String, ignoreCase: Boolean = false): String", "kotlin.text", "String", "Replaces the first occurrence of oldValue with newValue.", METHOD },
	{ "contains", "fun String.contains(other: CharSequence, ignoreCase: Boolean = false): Boolean", "kotlin.text", "String", "Returns true if this string contains the specified other as a substring.", METHOD },
	{ "startsWith", "fun String.startsWith(prefix: String, ignoreCase: Boolean = false): Boolean", "kotlin.text", "String", "Returns true if this string starts with the specified prefix.", METHOD },
	{ "endsWith", "fun String.endsWith(suffix: String, ignoreCase: Boolean = false): Boolean", "kotlin.text", "String", "Returns true if this string ends with the specified suffix.", METHOD },
	{ "substring", "fun String.substring(startIndex: Int, endIndex: Int = length): String", "kotlin.text", "String", "Returns a substring beginning at startIndex and ending before endIndex.", METHOD },
	{ "lowercase", "fun String.lowercase(): String", "kotlin.text", "String", "Returns a copy of this string converted to lowercase.", METHOD },
	{ "uppercase", "fun String.uppercase(): String", "kotlin.text", "String", "Returns a copy of this string converted to uppercase.", METHOD },
	{ "toInt", "fun String.toInt(): Int", "kotlin.text", "String", "Parses the string as a signed Int number and returns the result.", METHOD },
	{ "toIntOrNull", "fun String.toIntOrNull(): Int?", "kotlin.text", "String", "Parses the string as a signed Int number and returns the result or null.", METHOD },
	{ "toLong", "fun String.toLong(): Long", "kotlin.text", "String", "Parses the string as a signed Long number and returns the result.", METHOD },
	{ "toLongOrNull", "fun String.toLongOrNull(): Long?", "kotlin.text", "String", "Parses the string as a signed Long and returns the result or null.", METHOD },
	{ "toDouble", "fun String.toDouble(): Double", "kotlin.text", "String", "Parses the string as a Double number and returns the result.", METHOD },
	{ "toDoubleOrNull", "fun String.toDoubleOrNull(): Double?", "kotlin.text", "String", "Parses the string as a Double and returns the result or null.", METHOD },
	{ "toFloat", "fun String.toFloat(): Float", "kotlin.text", "String", "Parses the string as a Float number and returns the result.", METHOD },
	{ "toBoolean", "fun String.toBoolean(): Boolean", "kotlin.text", "String", "Returns true if the content equals \"true\" ignoring case.", METHOD },
	{ "toByteArray", "fun String.toByteArray(charset: Charset = Charsets.UTF_8): ByteArray", "kotlin.text", "String", "Encodes this string to a byte array using the specified charset.", METHOD },
	{ "toCharArray", "fun String.toCharArray(): CharArray", "kotlin.text", "String", "Returns a CharArray containing characters of this string.", METHOD },
	{ "toRegex", "fun String.toRegex(): Regex", "kotlin.text", "String", "Converts this string to a regular expression Regex.", METHOD },
	{ "reversed", "fun String.reversed(): String", "kotlin.text", "String", "Returns a string with characters in reversed order.", METHOD },
	{ "lines", "fun String.lines(): List<String>", "kotlin.text", "String", "Splits this string into lines and returns the result as a list.", METHOD },
	{ "padStart", "fun String.padStart(length: Int, padChar: Char = ' '): String", "kotlin.text", "String", "Pads the string to the specified length at the start.", METHOD },
	{ "padEnd", "fun String.padEnd(length: Int, padChar: Char = ' '): String", "kotlin.text", "String", "Pads the string to the specified length at the end.", METHOD },
	{ "format", "fun String.format(vararg args: Any?): String", "kotlin.text", "String", "Uses this string as a format string and returns the formatted result.", METHOD },
	{ "trimIndent", "fun String.trimIndent(): String", "kotlin.text", "String", "Detects a common minimal indent and removes it from every line.", METHOD },
	{ "trimMargin", "fun String.trimMargin(marginPrefix: String = \"|\"): String", "kotlin.text", "String", "Trims leading whitespace followed by marginPrefix from every line.", METHOD },
	{ "indices", "val String.indices: IntRange", "kotlin.text", "String", "Returns the range of valid character indices.", PROPERTY },
	{ "lastIndex", "val String.lastIndex: Int", "kotlin.text", "String", "Returns the index of the last character, or -1 if empty.", PROPERTY },
	{ "compareTo", "fun String.compareTo(other: String, ignoreCase: Boolean = false): Int", "kotlin.text", "String", "Compares this string with the other string.", METHOD },
	{ "equals", "fun String.equals(other: String?, ignoreCase: Boolean = false): Boolean", "kotlin.text", "String", "Returns true if this string equals the other string.", METHOD },
	{ "indexOf", "fun String.indexOf(string: String, startIndex: Int = 0, ignoreCase: Boolean = false): Int", "kotlin.text", "String", "Returns the index of the first occurrence of string, or -1.", METHOD },
	{ "lastIndexOf", "fun String.lastIndexOf(string: String, startIndex: Int = lastIndex, ignoreCase: Boolean = false): Int", "kotlin.text", "String", "Returns the index of the last occurrence of string, or -1.", METHOD },
	{ "matches", "fun String.matches(regex: Regex): Boolean", "kotlin.text", "String", "Returns true if this string matches the given regular expression.", METHOD },
	{ "removeSuffix", "fun String.removeSuffix(suffix: CharSequence): String", "kotlin.text", "String", "If this string ends with the given suffix, returns a copy without it.", METHOD },
	{ "removePrefix", "fun String.removePrefix(prefix: CharSequence): String", "kotlin.text", "String", "If this string starts with the given prefix, returns a copy without it.", METHOD },
	{ "removeSurrounding", "fun String.removeSurrounding(prefix: CharSequence, suffix: CharSequence): String", "kotlin.text", "String", "Removes the given prefix and suffix if both are present.", METHOD },
	{ "substringBefore", "fun String.substringBefore(delimiter: String, missingDelimiterValue: String = this): String", "kotlin.text", "String", "Returns a substring before the first occurrence of delimiter.", METHOD },
	{ "substringAfter", "fun String.substringAfter(delimiter: String, missingDelimiterValue: String = this): String", "kotlin.text", "String", "Returns a substring after the first occurrence of delimiter.", METHOD },
	{ "substringBeforeLast", "fun String.substringBeforeLast(delimiter: String, missingDelimiterValue: String = this): String", "kotlin.text", "String", "Returns a substring before the last occurrence of delimiter.", METHOD },
	{ "substringAfterLast", "fun String.substringAfterLast(delimiter: String, missingDelimiterValue: String = this): String", "kotlin.text", "String", "Returns a substring after the last occurrence of delimiter.", METHOD },
	{ "drop", "fun String.drop(n: Int): String", "kotlin.text", "String", "Returns a string with the first n characters removed.", METHOD },
	{ "dropLast", "fun String.dropLast(n: Int): String", "kotlin.text", "String", "Returns a string with the last n characters removed.", METHOD },
	{ "take", "fun String.take(n: Int): String", "kotlin.text", "String", "Returns a string containing the first n characters.", METHOD },
	{ "takeLast", "fun String.takeLast(n: Int): String", "kotlin.text", "String", "Returns a string containing the last n characters.", METHOD },
	{ "repeat", "fun String.repeat(n: Int): String", "kotlin.text", "String", "Returns a string repeated n times.", METHOD },
	{ "toList", "fun String.toList(): List<Char>", "kotlin.text", "String", "Returns a List of characters in this string.", METHOD },

	// ── Collection extension methods (Iterable<T>) ─────────────────
	{ "map", "fun <T, R> Iterable<T>.map(transform: (T) -> R): List<R>", "kotlin.collections", "Iterable<T>", "Returns a list containing the results of applying transform to each element.", METHOD },
	{ "mapNotNull", "fun <T, R : Any> Iterable<T>.mapNotNull(transform: (T) -> R?): List<R>", "kotlin.collections", "Iterable<T>", "Returns a list containing only the non-null results of applying transform.", METHOD },
	{ "mapIndexed", "fun <T, R> Iterable<T>.mapIndexed(transform: (index: Int, T) -> R): List<R>", "kotlin.collections", "Iterable<T>", "Returns a list of results of applying transform with index to each element.", METHOD },
	{ "filter", "fun <T> Iterable<T>.filter(predicate: (T) -> Boolean): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list containing only elements matching the given predicate.", METHOD },
	{ "filterNot", "fun <T> Iterable<T>.filterNot(predicate: (T) -> Boolean): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list containing only elements not matching the given predicate.", METHOD },
	{ "filterNotNull", "fun <T : Any> Iterable<T?>.filterNotNull(): List<T>", "kotlin.collections", "Iterable<T?>", "Returns a list containing only non-null elements.", METHOD },
	{ "filterIsInstance", "fun <R> Iterable<*>.filterIsInstance(): List<R>", "kotlin.collections", "Iterable<*>", "Returns a list containing only elements that are instances of the specified type.", METHOD },
	{ "forEach", "fun <T> Iterable<T>.forEach(action: (T) -> Unit): Unit", "kotlin.collections", "Iterable<T>", "Performs the given action on each element.", METHOD },
	{ "forEachIndexed", "fun <T> Iterable<T>.forEachIndexed(action: (index: Int, T) -> Unit): Unit", "kotlin.collections", "Iterable<T>", "Performs the given action on each element, providing sequential index.", METHOD },
	{ "first", "fun <T> Iterable<T>.first(): T", "kotlin.collections", "Iterable<T>", "Returns the first element. Throws NoSuchElementException if empty.", METHOD },
	{ "first", "fun <T> Iterable<T>.first(predicate: (T) -> Boolean): T", "kotlin.collections", "Iterable<T>", "Returns the first element matching predicate.", METHOD },
	{ "firstOrNull", "fun <T> Iterable<T>.firstOrNull(): T?", "kotlin.collections", "Iterable<T>", "Returns the first element, or null if empty.", METHOD },
	{ "firstOrNull", "fun <T> Iterable<T>.firstOrNull(predicate: (T) -> Boolean): T?", "kotlin.collections", "Iterable<T>", "Returns the first element matching predicate, or null.", METHOD },
	{ "last", "fun <T> List<T>.last(): T", "kotlin.collections", "List<T>", "Returns the last element. Throws NoSuchElementException if empty.", METHOD },
	{ "lastOrNull", "fun <T> List<T>.lastOrNull(): T?", "kotlin.collections", "List<T>", "Returns the last element, or null if empty.", METHOD },
	{ "single", "fun <T> Iterable<T>.single(): T", "kotlin.collections", "Iterable<T>", "Returns the single element. Throws if empty or has more than one.", METHOD },
	{ "singleOrNull", "fun <T> Iterable<T>.singleOrNull(): T?", "kotlin.collections", "Iterable<T>", "Returns the single element, or null if empty or has more than one.", METHOD },
	{ "size", "val Collection<*>.size: Int", "kotlin.collections", "Collection<*>", "Returns the number of elements in the collection.", PROPERTY },
	{ "isEmpty", "fun Collection<*>.isEmpty(): Boolean", "kotlin.collections", "Collection<*>", "Returns true if the collection is empty.", METHOD },
	{ "isNotEmpty", "fun Collection<*>.isNotEmpty(): Boolean", "kotlin.collections", "Collection<*>", "Returns true if the collection is not empty.", METHOD },
	{ "any", "fun <T> Iterable<T>.any(predicate: (T) -> Boolean): Boolean", "kotlin.collections", "Iterable<T>", "Returns true if at least one element matches the predicate.", METHOD },
	{ "any", "fun <T> Iterable<T>.any(): Boolean", "kotlin.collections", "Iterable<T>", "Returns true if the collection has at least one element.", METHOD },
	{ "all", "fun <T> Iterable<T>.all(predicate: (T) -> Boolean): Boolean", "kotlin.collections", "Iterable<T>", "Returns true if all elements match the given predicate.", METHOD },
	{ "none", "fun <T> Iterable<T>.none(predicate: (T) -> Boolean): Boolean", "kotlin.collections", "Iterable<T>", "Returns true if no elements match the given predicate.", METHOD },
	{ "none", "fun <T> Iterable<T>.none(): Boolean", "kotlin.collections", "Iterable<T>", "Returns true if the collection has no elements.", METHOD },
	{ "count", "fun <T> Iterable<T>.count(): Int", "kotlin.collections", "Iterable<T>", "Returns the number of elements.", METHOD },
	{ "count", "fun <T> Iterable<T>.count(predicate: (T) -> Boolean): Int", "kotlin.collections", "Iterable<T>", "Returns the number of elements matching the given predicate.", METHOD },
	{ "flatMap", "fun <T, R> Iterable<T>.flatMap(transform: (T) -> Iterable<R>): List<R>", "kotlin.collections", "Iterable<T>", "Returns a list of all elements yielded from transform applied to each element.", METHOD },
	{ "flatten", "fun <T> Iterable<Iterable<T>>.flatten(): List<T>", "kotlin.collections", "Iterable<Iterable<T>>", "Returns a single list of all elements from all collections.", METHOD },
	{ "fold", "fun <T, R> Iterable<T>.fold(initial: R, operation: (acc: R, T) -> R): R", "kotlin.collections", "Iterable<T>", "Accumulates value starting with initial and applying operation left to right.", METHOD },
	{ "reduce", "fun <S, T : S> Iterable<T>.reduce(operation: (acc: S, T) -> S): S", "kotlin.collections", "Iterable<T>", "Accumulates value starting with first element and applying operation left to right.", METHOD },
	{ "sumOf", "fun <T> Iterable<T>.sumOf(selector: (T) -> Int): Int", "kotlin.collections", "Iterable<T>", "Returns the sum of all values produced by selector for each element.", METHOD },
	{ "sortedBy", "fun <T, R : Comparable<R>> Iterable<T>.sortedBy(selector: (T) -> R?): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list sorted according to natural order of the value returned by selector.", METHOD },
	{ "sortedByDescending", "fun <T, R : Comparable<R>> Iterable<T>.sortedByDescending(selector: (T) -> R?): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list sorted descending according to the value returned by selector.", METHOD },
	{ "sortedWith", "fun <T> Iterable<T>.sortedWith(comparator: Comparator<in T>): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list sorted according to the given comparator.", METHOD },
	{ "sorted", "fun <T : Comparable<T>> Iterable<T>.sorted(): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list sorted according to natural ordering.", METHOD },
	{ "reversed", "fun <T> Iterable<T>.reversed(): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list with elements in reversed order.", METHOD },
	{ "groupBy", "fun <T, K> Iterable<T>.groupBy(keySelector: (T) -> K): Map<K, List<T>>", "kotlin.collections", "Iterable<T>", "Groups elements by the key returned by keySelector.", METHOD },
	{ "associate", "fun <T, K, V> Iterable<T>.associate(transform: (T) -> Pair<K, V>): Map<K, V>", "kotlin.collections", "Iterable<T>", "Returns a map containing key-value pairs produced by transform.", METHOD },
	{ "associateWith", "fun <K, V> Iterable<K>.associateWith(valueSelector: (K) -> V): Map<K, V>", "kotlin.collections", "Iterable<K>", "Returns a map where each element is a key associated with a value from valueSelector.", METHOD },
	{ "associateBy", "fun <T, K> Iterable<T>.associateBy(keySelector: (T) -> K): Map<K, T>", "kotlin.collections", "Iterable<T>", "Returns a map where keys are produced by keySelector.", METHOD },
	{ "distinct", "fun <T> Iterable<T>.distinct(): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list containing only distinct elements.", METHOD },
	{ "distinctBy", "fun <T, K> Iterable<T>.distinctBy(selector: (T) -> K): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list containing only elements with distinct keys from selector.", METHOD },
	{ "toList", "fun <T> Iterable<T>.toList(): List<T>", "kotlin.collections", "Iterable<T>", "Returns a List containing all elements.", METHOD },
	{ "toMutableList", "fun <T> Iterable<T>.toMutableList(): MutableList<T>", "kotlin.collections", "Iterable<T>", "Returns a MutableList containing all elements.", METHOD },
	{ "toSet", "fun <T> Iterable<T>.toSet(): Set<T>", "kotlin.collections", "Iterable<T>", "Returns a Set containing all distinct elements.", METHOD },
	{ "toMutableSet", "fun <T> Iterable<T>.toMutableSet(): MutableSet<T>", "kotlin.collections", "Iterable<T>", "Returns a MutableSet containing all distinct elements.", METHOD },
	{ "toMap", "fun <K, V> Iterable<Pair<K, V>>.toMap(): Map<K, V>", "kotlin.collections", "Iterable<Pair<K, V>>", "Returns a Map containing all key-value pairs.", METHOD },
	{ "zip", "fun <T, R> Iterable<T>.zip(other: Iterable<R>): List<Pair<T, R>>", "kotlin.collections", "Iterable<T>", "Returns a list of pairs of elements at same positions.", METHOD },
	{ "unzip", "fun <T, R> Iterable<Pair<T, R>>.unzip(): Pair<List<T>, List<R>>", "kotlin.collections", "Iterable<Pair<T, R>>", "Returns a pair of lists built from the pairs in this collection.", METHOD },
	{ "chunked", "fun <T> Iterable<T>.chunked(size: Int): List<List<T>>", "kotlin.collections", "Iterable<T>", "Splits this collection into a list of lists each not exceeding the given size.", METHOD },
	{ "windowed", "fun <T> Iterable<T>.windowed(size: Int, step: Int = 1, partialWindows: Boolean = false): List<List<T>>", "kotlin.collections", "Iterable<T>", "Returns a list of snapshots of the window of the given size.", METHOD },
	{ "take", "fun <T> Iterable<T>.take(n: Int): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list containing first n elements.", METHOD },
	{ "takeLast", "fun <T> List<T>.takeLast(n: Int): List<T>", "kotlin.collections", "List<T>", "Returns a list containing last n elements.", METHOD },
	{ "takeWhile", "fun <T> Iterable<T>.takeWhile(predicate: (T) -> Boolean): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list containing first elements satisfying predicate.", METHOD },
	{ "drop", "fun <T> Iterable<T>.drop(n: Int): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list with the first n elements removed.", METHOD },
	{ "dropLast", "fun <T> List<T>.dropLast(n: Int): List<T>", "kotlin.collections", "List<T>", "Returns a list with the last n elements removed.", METHOD },
	{ "dropWhile", "fun <T> Iterable<T>.dropWhile(predicate: (T) -> Boolean): List<T>", "kotlin.collections", "Iterable<T>", "Returns a list with leading elements satisfying predicate removed.", METHOD },
	{ "joinToString", "fun <T> Iterable<T>.joinToString(separator: CharSequence = \", \", prefix: CharSequence = \"\", postfix: CharSequence = \"\"): String", "kotlin.collections", "Iterable<T>", "Creates a string from all elements separated by separator.", METHOD },
	{ "contains", "fun <T> Iterable<T>.contains(element: T): Boolean", "kotlin.collections", "Iterable<T>", "Returns true if element is found in the collection.", METHOD },
	{ "indexOf", "fun <T> List<T>.indexOf(element: T): Int", "kotlin.collections", "List<T>", "Returns first index of element, or -1 if not found.", METHOD },
	{ "lastIndexOf", "fun <T> List<T>.lastIndexOf(element: T): Int", "kotlin.collections", "List<T>", "Returns last index of element, or -1 if not found.", METHOD },
	{ "indices", "val Collection<*>.indices: IntRange", "kotlin.collections", "Collection<*>", "Returns the range of valid indices for the collection.", PROPERTY },
	{ "lastIndex", "val <T> List<T>.lastIndex: Int", "kotlin.collections", "List<T>", "Returns the index of the last element, or -1 if empty.", PROPERTY },
	{ "withIndex", "fun <T> Iterable<T>.withIndex(): Iterable<IndexedValue<T>>", "kotlin.collections", "Iterable<T>", "Returns a lazy Iterable that wraps each element with its index.", METHOD },
	{ "onEach", "fun <T> Iterable<T>.onEach(action: (T) -> Unit): Iterable<T>", "kotlin.collections", "Iterable<T>", "Performs the given action on each element and returns the collection.", METHOD },
	{ "maxOrNull", "fun <T : Comparable<T>> Iterable<T>.maxOrNull(): T?", "kotlin.collections", "Iterable<T>", "Returns the largest element, or null if empty.", METHOD },
	{ "minOrNull", "fun <T : Comparable<T>> Iterable<T>.minOrNull(): T?", "kotlin.collections", "Iterable<T>", "Returns the smallest element, or null if empty.", METHOD },
	{ "maxByOrNull", "fun <T, R : Comparable<R>> Iterable<T>.maxByOrNull(selector: (T) -> R): T?", "kotlin.collections", "Iterable<T>", "Returns the first element yielding the largest value of selector, or null if empty.", METHOD },
	{ "minByOrNull", "fun <T, R : Comparable<R>> Iterable<T>.minByOrNull(selector: (T) -> R): T?", "kotlin.collections", "Iterable<T>", "Returns the first element yielding the smallest value of selector, or null if empty.", METHOD },
	{ "sum", "fun Iterable<Int>.sum(): Int", "kotlin.collections", "Iterable<Int>", "Returns the sum of all elements.", METHOD },
	{ "average", "fun Iterable<Int>.average(): Double", "kotlin.collections", "Iterable<Int>", "Returns the average of all elements.", METHOD },
	{ "partition", "fun <T> Iterable<T>.partition(predicate: (T) -> Boolean): Pair<List<T>, List<T>>", "kotlin.collections", "Iterable<T>", "Splits into a pair of lists: elements matching predicate and the rest.", METHOD },

	// ── MutableList methods ────────────────────────────────────────
	{ "add", "fun <T> MutableList<T>.add(element: T): Boolean", "kotlin.collections", "MutableList<T>", "Adds the specified element to the end of this list.", METHOD },
	{ "add", "fun <T> MutableList<T>.add(index: Int, element: T): Unit", "kotlin.collections", "MutableList<T>", "Inserts an element at the specified index.", METHOD },
	{ "addAll", "fun <T> MutableCollection<T>.addAll(elements: Collection<T>): Boolean", "kotlin.collections", "MutableCollection<T>", "Adds all elements of the given collection.", METHOD },
	{ "remove", "fun <T> MutableCollection<T>.remove(element: T): Boolean", "kotlin.collections", "MutableCollection<T>", "Removes a single instance of the specified element.", METHOD },
	{ "removeAt", "fun <T> MutableList<T>.removeAt(index: Int): T", "kotlin.collections", "MutableList<T>", "Removes the element at the specified index.", METHOD },
	{ "removeAll", "fun <T> MutableCollection<T>.removeAll(elements: Collection<T>): Boolean", "kotlin.collections", "MutableCollection<T>", "Removes all elements that are in the given collection.", METHOD },
	{ "clear", "fun <T> MutableCollection<T>.clear(): Unit", "kotlin.collections", "MutableCollection<T>", "Removes all elements from this collection.", METHOD },
	{ "set", "operator fun <T> MutableList<T>.set(index: Int, element: T): T", "kotlin.collections", "MutableList<T>", "Replaces the element at the specified index.", METHOD },
	{ "sort", "fun <T : Comparable<T>> MutableList<T>.sort(): Unit", "kotlin.collections", "MutableList<T>", "Sorts this list in-place according to natural ordering.", METHOD },

	// ── Map extension methods ──────────────────────────────────────
	{ "keys", "val Map<K, V>.keys: Set<K>", "kotlin.collections", "Map<K, V>", "Returns a read-only set of all keys.", PROPERTY },
	{ "values", "val Map<K, V>.values: Collection<V>", "kotlin.collections", "Map<K, V>", "Returns a read-only collection of all values.", PROPERTY },
	{ "entries", "val Map<K, V>.entries: Set<Map.Entry<K, V>>", "kotlin.collections", "Map<K, V>", "Returns a read-only set of all key-value pairs.", PROPERTY },
	{ "getOrDefault", "fun <K, V> Map<K, V>.getOrDefault(key: K, defaultValue: V): V", "kotlin.collections", "Map<K, V>", "Returns the value for the given key, or defaultValue if not found.", METHOD },
	{ "getOrElse", "fun <K, V> Map<K, V>.getOrElse(key: K, defaultValue: () -> V): V", "kotlin.collections", "Map<K, V>", "Returns the value for the given key, or calls defaultValue if not found.", METHOD },
	{ "getOrPut", "fun <K, V> MutableMap<K, V>.getOrPut(key: K, defaultValue: () -> V): V", "kotlin.collections", "MutableMap<K, V>", "Returns the value for key if present, or inserts and returns the defaultValue result.", METHOD },
	{ "mapKeys", "fun <K, V, R> Map<K, V>.mapKeys(transform: (Map.Entry<K, V>) -> R): Map<R, V>", "kotlin.collections", "Map<K, V>", "Returns a new map with entries having keys transformed by the given function.", METHOD },
	{ "mapValues", "fun <K, V, R> Map<K, V>.mapValues(transform: (Map.Entry<K, V>) -> R): Map<K, R>", "kotlin.collections", "Map<K, V>", "Returns a new map with entries having values transformed by the given function.", METHOD },
	{ "filterKeys", "fun <K, V> Map<K, V>.filterKeys(predicate: (K) -> Boolean): Map<K, V>", "kotlin.collections", "Map<K, V>", "Returns a map containing only entries with keys matching predicate.", METHOD },
	{ "filterValues", "fun <K, V> Map<K, V>.filterValues(predicate: (V) -> Boolean): Map<K, V>", "kotlin.collections", "Map<K, V>", "Returns a map containing only entries with values matching predicate.", METHOD },
	{ "toMutableMap", "fun <K, V> Map<K, V>.toMutableMap(): MutableMap<K, V>", "kotlin.collections", "Map<K, V>", "Returns a new MutableMap containing all key-value pairs.", METHOD },
	{ "containsKey", "fun <K, V> Map<K, V>.containsKey(key: K): Boolean", "kotlin.collections", "Map<K, V>", "Returns true if the map contains the given key.", METHOD },
	{ "containsValue", "fun <K, V> Map<K, V>.containsValue(value: V): Boolean", "kotlin.collections", "Map<K, V>", "Returns true if the map contains the given value.", METHOD },
	{ "put", "fun <K, V> MutableMap<K, V>.put(key: K, value: V): V?", "kotlin.collections", "MutableMap<K, V>", "Associates the specified value with the specified key.", METHOD },
	{ "putAll", "fun <K, V> MutableMap<K, V>.putAll(from: Map<K, V>): Unit", "kotlin.collections", "MutableMap<K, V>", "Updates this map with key-value pairs from the given map.", METHOD },
	{ "remove", "fun <K, V> MutableMap<K, V>.remove(key: K): V?", "kotlin.collections", "MutableMap<K, V>", "Removes the entry for the specified key.", METHOD },
	{ "plus", "operator fun <K, V> Map<K, V>.plus(pair: Pair<K, V>): Map<K, V>", "kotlin.collections", "Map<K, V>", "Creates a new map by replacing or adding an entry.", METHOD },

	// ── Sequence extension methods ─────────────────────────────────
	{ "asSequence", "fun <T> Iterable<T>.asSequence(): Sequence<T>", "kotlin.collections", "Iterable<T>", "Creates a Sequence from this iterable for lazy evaluation.", METHOD },

	// ── Numeric extension methods ──────────────────────────────────
	{ "toString", "fun Any?.toString(): String", "kotlin", "Any?", "Returns a string representation of the object.", METHOD },
	{ "hashCode", "fun Any.hashCode(): Int", "kotlin", "Any", "Returns a hash code value for the object.", METHOD },
	{ "equals", "fun Any.equals(other: Any?): Boolean", "kotlin", "Any", "Indicates whether some other object is equal to this one.", METHOD },
	{ "toInt", "fun Number.toInt(): Int", "kotlin", "Number", "Converts this number to an Int.", METHOD },
	{ "toLong", "fun Number.toLong(): Long", "kotlin", "Number", "Converts this number to a Long.", METHOD },
	{ "toDouble", "fun Number.toDouble(): Double", "kotlin", "Number", "Converts this number to a Double.", METHOD },
	{ "toFloat", "fun Number.toFloat(): Float", "kotlin", "Number", "Converts this number to a Float.", METHOD },
	{ "toByte", "fun Number.toByte(): Byte", "kotlin", "Number", "Converts this number to a Byte.", METHOD },
	{ "toShort", "fun Number.toShort(): Short", "kotlin", "Number", "Converts this number to a Short.", METHOD },
	{ "toChar", "fun Int.toChar(): Char", "kotlin", "Int", "Converts this Int to a Char.", METHOD },
	{ "coerceIn", "fun <T : Comparable<T>> T.coerceIn(minimumValue: T, maximumValue: T): T", "kotlin.ranges", "T", "Ensures that this value lies in the specified range.", METHOD },
	{ "coerceAtLeast", "fun <T : Comparable<T>> T.coerceAtLeast(minimumValue: T): T", "kotlin.ranges", "T", "Ensures that this value is not less than the specified minimum.", METHOD },
	{ "coerceAtMost", "fun <T : Comparable<T>> T.coerceAtMost(maximumValue: T): T", "kotlin.ranges", "T", "Ensures that this value is not greater than the specified maximum.", METHOD },

	// ── Type checking / casting ────────────────────────────────────
	{ "isNullOrEmpty", "fun <T> Collection<T>?.isNullOrEmpty(): Boolean", "kotlin.collections", "Collection<T>?", "Returns true if this collection is null or empty.", METHOD },
	{ "orEmpty", "fun <T> List<T>?.orEmpty(): List<T>", "kotlin.collections", "List<T>?", "Returns this list if it is not null, or an empty list otherwise.", METHOD },
	{ "orEmpty", "fun <K, V> Map<K, V>?.orEmpty(): Map<K, V>", "kotlin.collections", "Map<K, V>?", "Returns this map if it is not null, or an empty map otherwise.", METHOD },

	// ── Coroutine support ──────────────────────────────────────────
	{ "Continuation", "interface Continuation<in T>", "kotlin.coroutines", "", "Interface representing a continuation after a suspension point.", INTERFACE },
	{ "CoroutineContext", "interface CoroutineContext", "kotlin.coroutines", "", "Persistent context for the coroutine.", INTERFACE },
	{ "suspendCoroutine", "suspend fun <T> suspendCoroutine(block: (Continuation<T>) -> Unit): T", "kotlin.coroutines", "", "Obtains the current continuation and suspends the coroutine.", FUNCTION },

	// ── Annotations ────────────────────────────────────────────────
	{ "Deprecated", "annotation class Deprecated(val message: String, val replaceWith: ReplaceWith = ..., val level: DeprecationLevel = ...)", "kotlin", "", "Marks a declaration as deprecated.", CLASS },
	{ "Suppress", "annotation class Suppress(vararg val names: String)", "kotlin", "", "Suppresses the given compilation warnings.", CLASS },
	{ "JvmStatic", "annotation class JvmStatic", "kotlin.jvm", "", "Generates a static method in the JVM bytecode.", CLASS },
	{ "JvmOverloads", "annotation class JvmOverloads", "kotlin.jvm", "", "Generates overloads for functions with default parameter values.", CLASS },
	{ "JvmField", "annotation class JvmField", "kotlin.jvm", "", "Exposes the Kotlin property as a JVM field.", CLASS },
	{ "JvmName", "annotation class JvmName(val name: String)", "kotlin.jvm", "", "Specifies the name for the JVM method or field generated from this element.", CLASS },
	{ "Throws", "annotation class Throws(vararg val exceptionClasses: KClass<out Throwable>)", "kotlin.jvm", "", "Lists checked exceptions that a Kotlin function can throw.", CLASS },
	{ "Volatile", "annotation class Volatile", "kotlin.jvm", "", "Marks the JVM backing field as volatile.", CLASS },
	{ "Synchronized", "annotation class Synchronized", "kotlin.jvm", "", "Marks the JVM method as synchronized.", CLASS },
	{ "Transient", "annotation class Transient", "kotlin.jvm", "", "Marks the JVM field as transient.", CLASS },
	{ "Serializable", "annotation class Serializable", "java.io", "", "Marks a class as serializable.", CLASS },
	{ "Target", "annotation class Target(vararg val allowedTargets: AnnotationTarget)", "kotlin.annotation", "", "Restricts where an annotation can be applied.", CLASS },
	{ "Retention", "annotation class Retention(val value: AnnotationRetention = RUNTIME)", "kotlin.annotation", "", "Specifies how an annotation is retained.", CLASS },

	// ── Reflection ─────────────────────────────────────────────────
	{ "KClass", "interface KClass<T : Any>", "kotlin.reflect", "", "Represents a class at runtime.", INTERFACE },
};
