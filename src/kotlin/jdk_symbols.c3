module kls::kotlin::jdk_symbols;

import kls::kotlin::stdlib;

// ── Lookup functions ───────────────────────────────────────────────

/**
 * Find all JDK symbols whose name starts with `prefix`.
 * Writes matching pointers into `out_buf` and returns the count.
 */
fn usz lookup_by_prefix(String prefix, StdlibSymbol*[] out_buf) {
	if (prefix.len == 0 || out_buf.len == 0) return 0;

	usz count = 0;
	foreach (i, &sym : JDK_SYMBOLS) {
		if (count >= out_buf.len) break;
		if (sym.name.starts_with(prefix)) {
			out_buf[count] = sym;
			count++;
		}
	}
	return count;
}

/**
 * Find all JDK symbols matching `name` exactly.
 * Writes matching pointers into `out_buf` and returns the count.
 */
fn usz lookup_all_by_name(String name, StdlibSymbol*[] out_buf) {
	if (out_buf.len == 0) return 0;

	usz count = 0;
	foreach (i, &sym : JDK_SYMBOLS) {
		if (count >= out_buf.len) break;
		if (sym.name == name) {
			out_buf[count] = sym;
			count++;
		}
	}
	return count;
}

/**
 * Return the total number of bundled JDK symbols.
 */
fn usz symbol_count() {
	return JDK_SYMBOLS.len;
}

/**
 * Check whether a name is from java.lang (auto-imported in Kotlin/JVM).
 * java.lang.* is implicitly imported, so these should not trigger
 * "unresolved reference" diagnostics or import suggestions.
 */
fn bool is_java_lang_symbol(String name) {
	foreach (&sym : JDK_SYMBOLS) {
		if (sym.name == name && sym.package_name == "java.lang") {
			return true;
		}
	}
	return false;
}

// ── Embedded JDK symbol data ──────────────────────────────────────
//
// Covers the most commonly used Java platform classes accessible from
// Kotlin/JVM. Organised by package. Each entry:
//   { name, signature, package, receiver, doc, kind }
//
// java.lang.* is auto-imported in Kotlin -- these entries exist so
// is_java_lang_symbol() can suppress false diagnostics, and so
// completion can offer them.

const StdlibSymbol[*] JDK_SYMBOLS = {

	// ── java.lang (auto-imported) ─────────────────────────────────
	{ "Thread", "class Thread : Runnable", "java.lang", "", "A thread of execution in a program.", CLASS },
	{ "Runnable", "interface Runnable", "java.lang", "", "Represents a command that can be executed.", INTERFACE },
	{ "StringBuilder", "class StringBuilder : CharSequence, Appendable", "java.lang", "", "A mutable sequence of characters.", CLASS },
	{ "StringBuffer", "class StringBuffer : CharSequence, Appendable", "java.lang", "", "A thread-safe mutable sequence of characters.", CLASS },
	{ "System", "class System", "java.lang", "", "System utilities: standard I/O, properties, environment.", CLASS },
	{ "Runtime", "class Runtime", "java.lang", "", "Allows interaction with the Java runtime environment.", CLASS },
	{ "Process", "class Process", "java.lang", "", "Represents a native process.", CLASS },
	{ "ProcessBuilder", "class ProcessBuilder", "java.lang", "", "Creates operating system processes.", CLASS },
	{ "ClassLoader", "class ClassLoader", "java.lang", "", "An object responsible for loading classes.", CLASS },
	{ "Throwable", "class Throwable", "java.lang", "", "The superclass of all errors and exceptions.", CLASS },
	{ "Exception", "class Exception : Throwable", "java.lang", "", "The superclass of all exceptions.", CLASS },
	{ "RuntimeException", "class RuntimeException : Exception", "java.lang", "", "Superclass of exceptions that can be thrown during normal operation.", CLASS },
	{ "Error", "class Error : Throwable", "java.lang", "", "Superclass of all errors (serious problems).", CLASS },
	{ "IllegalArgumentException", "class IllegalArgumentException : RuntimeException", "java.lang", "", "Thrown when an illegal argument is passed.", CLASS },
	{ "IllegalStateException", "class IllegalStateException : RuntimeException", "java.lang", "", "Thrown when the state is inappropriate for the operation.", CLASS },
	{ "NullPointerException", "class NullPointerException : RuntimeException", "java.lang", "", "Thrown when null is used where an object is required.", CLASS },
	{ "UnsupportedOperationException", "class UnsupportedOperationException : RuntimeException", "java.lang", "", "Thrown when a requested operation is not supported.", CLASS },
	{ "IndexOutOfBoundsException", "class IndexOutOfBoundsException : RuntimeException", "java.lang", "", "Thrown when an index is out of range.", CLASS },
	{ "ClassCastException", "class ClassCastException : RuntimeException", "java.lang", "", "Thrown when an object is cast to an incompatible class.", CLASS },
	{ "NumberFormatException", "class NumberFormatException : IllegalArgumentException", "java.lang", "", "Thrown when a string cannot be converted to a number.", CLASS },
	{ "StackOverflowError", "class StackOverflowError : VirtualMachineError", "java.lang", "", "Thrown when a stack overflow occurs.", CLASS },
	{ "OutOfMemoryError", "class OutOfMemoryError : VirtualMachineError", "java.lang", "", "Thrown when the JVM runs out of memory.", CLASS },
	{ "Comparable", "interface Comparable<T>", "java.lang", "", "Imposes a natural ordering on implementing classes.", INTERFACE },
	{ "Iterable", "interface Iterable<T>", "java.lang", "", "Implementing this interface allows an object to be the target of for-each.", INTERFACE },
	{ "AutoCloseable", "interface AutoCloseable", "java.lang", "", "An object that may hold resources until closed.", INTERFACE },
	{ "Cloneable", "interface Cloneable", "java.lang", "", "Marker interface for objects that support cloning.", INTERFACE },
	{ "Appendable", "interface Appendable", "java.lang", "", "An object to which char sequences can be appended.", INTERFACE },
	{ "CharSequence", "interface CharSequence", "java.lang", "", "A readable sequence of char values.", INTERFACE },
	{ "Math", "class Math", "java.lang", "", "Contains methods for basic numeric operations.", CLASS },
	{ "StrictMath", "class StrictMath", "java.lang", "", "Contains methods for basic numeric operations with strict reproducibility.", CLASS },
	{ "Deprecated", "annotation class Deprecated", "java.lang", "", "Indicates that the annotated element is deprecated.", CLASS },
	{ "Override", "annotation class Override", "java.lang", "", "Indicates that a method overrides a superclass method.", CLASS },
	{ "SuppressWarnings", "annotation class SuppressWarnings", "java.lang", "", "Indicates that compiler warnings should be suppressed.", CLASS },
	{ "FunctionalInterface", "annotation class FunctionalInterface", "java.lang", "", "Indicates that an interface is a functional interface.", CLASS },

	// ── java.util (collections, utilities) ────────────────────────
	{ "UUID", "class UUID : Serializable, Comparable<UUID>", "java.util", "", "A universally unique identifier (128-bit value).", CLASS },
	{ "Date", "class Date : Serializable, Cloneable, Comparable<Date>", "java.util", "", "Represents a specific instant in time (legacy, prefer java.time).", CLASS },
	{ "Calendar", "class Calendar : Serializable, Cloneable, Comparable<Calendar>", "java.util", "", "Abstract class for date/time conversion and manipulation.", CLASS },
	{ "GregorianCalendar", "class GregorianCalendar : Calendar", "java.util", "", "A concrete implementation of Calendar.", CLASS },
	{ "TimeZone", "class TimeZone : Serializable, Cloneable", "java.util", "", "Represents a time zone offset.", CLASS },
	{ "Locale", "class Locale : Cloneable, Serializable", "java.util", "", "Represents a specific geographical/cultural region.", CLASS },
	{ "Currency", "class Currency : Serializable", "java.util", "", "Represents a currency.", CLASS },
	{ "Random", "class Random : Serializable", "java.util", "", "An instance of this class generates pseudo-random numbers.", CLASS },
	{ "Timer", "class Timer", "java.util", "", "A facility for scheduling tasks for future execution.", CLASS },
	{ "TimerTask", "class TimerTask : Runnable", "java.util", "", "A task that can be scheduled for one-time or repeated execution by a Timer.", CLASS },
	{ "Scanner", "class Scanner : Iterator<String>, Closeable", "java.util", "", "A simple text scanner that can parse primitive types and strings.", CLASS },
	{ "Optional", "class Optional<T>", "java.util", "", "A container object which may or may not contain a non-null value.", CLASS },
	{ "OptionalInt", "class OptionalInt", "java.util", "", "A container object which may or may not contain an int value.", CLASS },
	{ "OptionalLong", "class OptionalLong", "java.util", "", "A container object which may or may not contain a long value.", CLASS },
	{ "OptionalDouble", "class OptionalDouble", "java.util", "", "A container object which may or may not contain a double value.", CLASS },
	{ "Properties", "class Properties : Hashtable<Any, Any>", "java.util", "", "A persistent set of properties (key-value string pairs).", CLASS },
	{ "Collections", "class Collections", "java.util", "", "Utility methods for operating on collections.", CLASS },
	{ "Arrays", "class Arrays", "java.util", "", "Utility methods for manipulating arrays.", CLASS },
	{ "Objects", "class Objects", "java.util", "", "Utility methods for operating on objects.", CLASS },
	{ "Base64", "class Base64", "java.util", "", "Contains static methods for Base64 encoding and decoding.", CLASS },
	{ "StringJoiner", "class StringJoiner", "java.util", "", "Constructs a sequence of characters separated by a delimiter.", CLASS },
	{ "BitSet", "class BitSet : Cloneable, Serializable", "java.util", "", "A vector of bits that grows as needed.", CLASS },
	{ "Stack", "class Stack<E> : Vector<E>", "java.util", "", "A last-in-first-out (LIFO) stack of objects.", CLASS },
	{ "Vector", "class Vector<E> : AbstractList<E>, RandomAccess, Cloneable, Serializable", "java.util", "", "A synchronized growable array of objects.", CLASS },
	{ "Hashtable", "class Hashtable<K, V> : Dictionary<K, V>, Map<K, V>, Cloneable, Serializable", "java.util", "", "A synchronized hash table mapping keys to values.", CLASS },
	{ "LinkedList", "class LinkedList<E> : AbstractSequentialList<E>, List<E>, Deque<E>, Cloneable, Serializable", "java.util", "", "A doubly-linked list implementation.", CLASS },
	{ "TreeMap", "class TreeMap<K, V> : AbstractMap<K, V>, NavigableMap<K, V>, Cloneable, Serializable", "java.util", "", "A Red-Black tree based NavigableMap implementation.", CLASS },
	{ "TreeSet", "class TreeSet<E> : AbstractSet<E>, NavigableSet<E>, Cloneable, Serializable", "java.util", "", "A NavigableSet implementation based on a TreeMap.", CLASS },
	{ "LinkedHashMap", "class LinkedHashMap<K, V> : HashMap<K, V>", "java.util", "", "A hash table and linked list implementation of Map with predictable iteration order.", CLASS },
	{ "LinkedHashSet", "class LinkedHashSet<E> : HashSet<E>", "java.util", "", "A hash table and linked list implementation of Set with predictable iteration order.", CLASS },
	{ "WeakHashMap", "class WeakHashMap<K, V> : AbstractMap<K, V>", "java.util", "", "A hash table with weak keys.", CLASS },
	{ "EnumSet", "class EnumSet<E> : AbstractSet<E>, Cloneable, Serializable", "java.util", "", "A specialized Set implementation for use with enum types.", CLASS },
	{ "EnumMap", "class EnumMap<K, V> : AbstractMap<K, V>, Serializable, Cloneable", "java.util", "", "A specialized Map implementation for use with enum type keys.", CLASS },
	{ "PriorityQueue", "class PriorityQueue<E> : AbstractQueue<E>, Serializable", "java.util", "", "A priority queue based on a binary heap.", CLASS },
	{ "ArrayDeque", "class ArrayDeque<E> : AbstractCollection<E>, Deque<E>, Cloneable, Serializable", "java.util", "", "A resizable-array implementation of the Deque interface.", CLASS },
	{ "Comparator", "interface Comparator<T>", "java.util", "", "A comparison function that imposes a total ordering.", INTERFACE },
	{ "Iterator", "interface Iterator<E>", "java.util", "", "An iterator over a collection.", INTERFACE },
	{ "Enumeration", "interface Enumeration<E>", "java.util", "", "Enumerates elements of a collection (legacy).", INTERFACE },
	{ "ServiceLoader", "class ServiceLoader<S> : Iterable<S>", "java.util", "", "A facility to load implementations of a service.", CLASS },
	{ "EventListener", "interface EventListener", "java.util", "", "A tagging interface for event listeners.", INTERFACE },
	{ "Formattable", "interface Formattable", "java.util", "", "An interface for custom formatting.", INTERFACE },
	{ "Formatter", "class Formatter : Closeable, Flushable", "java.util", "", "An interpreter for printf-style format strings.", CLASS },
	{ "StringTokenizer", "class StringTokenizer : Enumeration<Any>", "java.util", "", "Breaks a string into tokens.", CLASS },

	// ── java.util.regex ───────────────────────────────────────────
	{ "Pattern", "class Pattern : Serializable", "java.util.regex", "", "A compiled representation of a regular expression.", CLASS },
	{ "Matcher", "class Matcher : MatchResult", "java.util.regex", "", "An engine that performs match operations on a character sequence.", CLASS },

	// ── java.util.stream ──────────────────────────────────────────
	{ "Stream", "interface Stream<T> : BaseStream<T, Stream<T>>", "java.util.stream", "", "A sequence of elements supporting sequential and parallel aggregate operations.", INTERFACE },
	{ "Collectors", "class Collectors", "java.util.stream", "", "Implementations of Collector for common mutable reduction operations.", CLASS },
	{ "IntStream", "interface IntStream : BaseStream<Int, IntStream>", "java.util.stream", "", "A sequence of primitive int-valued elements.", INTERFACE },
	{ "LongStream", "interface LongStream : BaseStream<Long, LongStream>", "java.util.stream", "", "A sequence of primitive long-valued elements.", INTERFACE },
	{ "DoubleStream", "interface DoubleStream : BaseStream<Double, DoubleStream>", "java.util.stream", "", "A sequence of primitive double-valued elements.", INTERFACE },
	{ "Collector", "interface Collector<T, A, R>", "java.util.stream", "", "A mutable reduction operation that accumulates input elements.", INTERFACE },
	{ "StreamSupport", "class StreamSupport", "java.util.stream", "", "Low-level utility methods for creating and manipulating streams.", CLASS },

	// ── java.util.concurrent ──────────────────────────────────────
	{ "ConcurrentHashMap", "class ConcurrentHashMap<K, V> : ConcurrentMap<K, V>, Serializable", "java.util.concurrent", "", "A hash table supporting full concurrency of retrievals.", CLASS },
	{ "ConcurrentLinkedQueue", "class ConcurrentLinkedQueue<E> : AbstractQueue<E>, Serializable", "java.util.concurrent", "", "An unbounded thread-safe FIFO queue.", CLASS },
	{ "CopyOnWriteArrayList", "class CopyOnWriteArrayList<E> : List<E>, RandomAccess, Cloneable, Serializable", "java.util.concurrent", "", "A thread-safe variant of ArrayList.", CLASS },
	{ "CopyOnWriteArraySet", "class CopyOnWriteArraySet<E> : AbstractSet<E>, Serializable", "java.util.concurrent", "", "A thread-safe variant of HashSet backed by CopyOnWriteArrayList.", CLASS },
	{ "CountDownLatch", "class CountDownLatch", "java.util.concurrent", "", "A synchronization aid that allows threads to wait until a set of operations complete.", CLASS },
	{ "CyclicBarrier", "class CyclicBarrier", "java.util.concurrent", "", "A synchronization aid that allows threads to wait for each other.", CLASS },
	{ "Semaphore", "class Semaphore : Serializable", "java.util.concurrent", "", "A counting semaphore.", CLASS },
	{ "ExecutorService", "interface ExecutorService : Executor", "java.util.concurrent", "", "An Executor that provides methods to manage termination and Future tracking.", INTERFACE },
	{ "ScheduledExecutorService", "interface ScheduledExecutorService : ExecutorService", "java.util.concurrent", "", "An ExecutorService that can schedule commands after a delay or periodically.", INTERFACE },
	{ "Executors", "class Executors", "java.util.concurrent", "", "Factory and utility methods for Executor and related classes.", CLASS },
	{ "Future", "interface Future<V>", "java.util.concurrent", "", "Represents the result of an asynchronous computation.", INTERFACE },
	{ "CompletableFuture", "class CompletableFuture<T> : Future<T>, CompletionStage<T>", "java.util.concurrent", "", "A Future that may be explicitly completed and used as a CompletionStage.", CLASS },
	{ "CompletionStage", "interface CompletionStage<T>", "java.util.concurrent", "", "A stage of a possibly asynchronous computation.", INTERFACE },
	{ "ThreadPoolExecutor", "class ThreadPoolExecutor : AbstractExecutorService", "java.util.concurrent", "", "An ExecutorService that executes each submitted task using a pool of threads.", CLASS },
	{ "BlockingQueue", "interface BlockingQueue<E> : Queue<E>", "java.util.concurrent", "", "A Queue that supports blocking operations.", INTERFACE },
	{ "LinkedBlockingQueue", "class LinkedBlockingQueue<E> : AbstractQueue<E>, BlockingQueue<E>, Serializable", "java.util.concurrent", "", "An optionally-bounded blocking queue based on linked nodes.", CLASS },
	{ "ArrayBlockingQueue", "class ArrayBlockingQueue<E> : AbstractQueue<E>, BlockingQueue<E>, Serializable", "java.util.concurrent", "", "A bounded blocking queue backed by an array.", CLASS },
	{ "TimeUnit", "enum class TimeUnit", "java.util.concurrent", "", "A time duration unit (NANOSECONDS, MICROSECONDS, MILLISECONDS, SECONDS, MINUTES, HOURS, DAYS).", CLASS },
	{ "Callable", "interface Callable<V>", "java.util.concurrent", "", "A task that returns a result and may throw an exception.", INTERFACE },
	{ "Executor", "interface Executor", "java.util.concurrent", "", "An object that executes submitted Runnable tasks.", INTERFACE },
	{ "ForkJoinPool", "class ForkJoinPool : AbstractExecutorService", "java.util.concurrent", "", "An ExecutorService for running ForkJoinTasks.", CLASS },
	{ "ForkJoinTask", "class ForkJoinTask<V> : Future<V>, Serializable", "java.util.concurrent", "", "Abstract base class for tasks that run within a ForkJoinPool.", CLASS },
	{ "RecursiveTask", "class RecursiveTask<V> : ForkJoinTask<V>", "java.util.concurrent", "", "A recursive result-bearing ForkJoinTask.", CLASS },
	{ "RecursiveAction", "class RecursiveAction : ForkJoinTask<Void>", "java.util.concurrent", "", "A recursive resultless ForkJoinTask.", CLASS },

	// ── java.util.concurrent.atomic ───────────────────────────────
	{ "AtomicInteger", "class AtomicInteger : Number, Serializable", "java.util.concurrent.atomic", "", "An int value that may be updated atomically.", CLASS },
	{ "AtomicLong", "class AtomicLong : Number, Serializable", "java.util.concurrent.atomic", "", "A long value that may be updated atomically.", CLASS },
	{ "AtomicBoolean", "class AtomicBoolean : Serializable", "java.util.concurrent.atomic", "", "A boolean value that may be updated atomically.", CLASS },
	{ "AtomicReference", "class AtomicReference<V> : Serializable", "java.util.concurrent.atomic", "", "An object reference that may be updated atomically.", CLASS },
	{ "AtomicIntegerArray", "class AtomicIntegerArray : Serializable", "java.util.concurrent.atomic", "", "An int array in which elements may be updated atomically.", CLASS },
	{ "AtomicLongArray", "class AtomicLongArray : Serializable", "java.util.concurrent.atomic", "", "A long array in which elements may be updated atomically.", CLASS },

	// ── java.util.concurrent.locks ────────────────────────────────
	{ "ReentrantLock", "class ReentrantLock : Lock, Serializable", "java.util.concurrent.locks", "", "A reentrant mutual exclusion Lock.", CLASS },
	{ "ReentrantReadWriteLock", "class ReentrantReadWriteLock : ReadWriteLock, Serializable", "java.util.concurrent.locks", "", "A ReadWriteLock supporting reentrant read and write locks.", CLASS },
	{ "Lock", "interface Lock", "java.util.concurrent.locks", "", "Provides more extensive locking operations than synchronized.", INTERFACE },
	{ "ReadWriteLock", "interface ReadWriteLock", "java.util.concurrent.locks", "", "Maintains a pair of associated locks for reading and writing.", INTERFACE },
	{ "Condition", "interface Condition", "java.util.concurrent.locks", "", "Provides a means for one thread to suspend until notified.", INTERFACE },

	// ── java.io ───────────────────────────────────────────────────
	{ "File", "class File : Serializable, Comparable<File>", "java.io", "", "An abstract representation of file and directory pathnames.", CLASS },
	{ "InputStream", "class InputStream : Closeable", "java.io", "", "Abstract class for reading bytes.", CLASS },
	{ "OutputStream", "class OutputStream : Closeable, Flushable", "java.io", "", "Abstract class for writing bytes.", CLASS },
	{ "Reader", "class Reader : Readable, Closeable", "java.io", "", "Abstract class for reading character streams.", CLASS },
	{ "Writer", "class Writer : Appendable, Closeable, Flushable", "java.io", "", "Abstract class for writing character streams.", CLASS },
	{ "BufferedReader", "class BufferedReader : Reader", "java.io", "", "Reads text from a character-input stream, buffering characters.", CLASS },
	{ "BufferedWriter", "class BufferedWriter : Writer", "java.io", "", "Writes text to a character-output stream, buffering characters.", CLASS },
	{ "InputStreamReader", "class InputStreamReader : Reader", "java.io", "", "A bridge from byte streams to character streams.", CLASS },
	{ "OutputStreamWriter", "class OutputStreamWriter : Writer", "java.io", "", "A bridge from character streams to byte streams.", CLASS },
	{ "FileInputStream", "class FileInputStream : InputStream", "java.io", "", "Obtains input bytes from a file.", CLASS },
	{ "FileOutputStream", "class FileOutputStream : OutputStream", "java.io", "", "An output stream for writing data to a File.", CLASS },
	{ "FileReader", "class FileReader : InputStreamReader", "java.io", "", "Reads character files.", CLASS },
	{ "FileWriter", "class FileWriter : OutputStreamWriter", "java.io", "", "Writes character files.", CLASS },
	{ "ByteArrayInputStream", "class ByteArrayInputStream : InputStream", "java.io", "", "Contains an internal buffer with bytes to read.", CLASS },
	{ "ByteArrayOutputStream", "class ByteArrayOutputStream : OutputStream", "java.io", "", "Captures data written to an output stream in a byte array.", CLASS },
	{ "StringReader", "class StringReader : Reader", "java.io", "", "A character stream that reads from a string.", CLASS },
	{ "StringWriter", "class StringWriter : Writer", "java.io", "", "A character stream that collects output in a StringBuffer.", CLASS },
	{ "PrintWriter", "class PrintWriter : Writer", "java.io", "", "Prints formatted representations of objects to a text-output stream.", CLASS },
	{ "PrintStream", "class PrintStream : FilterOutputStream, Appendable, Closeable", "java.io", "", "Adds the ability to print representations of various data values.", CLASS },
	{ "DataInputStream", "class DataInputStream : FilterInputStream, DataInput", "java.io", "", "Reads primitive Java data types from an underlying input stream.", CLASS },
	{ "DataOutputStream", "class DataOutputStream : FilterOutputStream, DataOutput", "java.io", "", "Writes primitive Java data types to an underlying output stream.", CLASS },
	{ "ObjectInputStream", "class ObjectInputStream : InputStream, ObjectInput, ObjectStreamConstants", "java.io", "", "Deserializes objects previously written using ObjectOutputStream.", CLASS },
	{ "ObjectOutputStream", "class ObjectOutputStream : OutputStream, ObjectOutput, ObjectStreamConstants", "java.io", "", "Serializes objects to an output stream.", CLASS },
	{ "Serializable", "interface Serializable", "java.io", "", "Marker interface for classes whose instances can be serialized.", INTERFACE },
	{ "Closeable", "interface Closeable : AutoCloseable", "java.io", "", "A source or destination of data that can be closed.", INTERFACE },
	{ "Flushable", "interface Flushable", "java.io", "", "A destination of data that can be flushed.", INTERFACE },
	{ "IOException", "class IOException : Exception", "java.io", "", "Signals that an I/O exception of some sort has occurred.", CLASS },
	{ "FileNotFoundException", "class FileNotFoundException : IOException", "java.io", "", "Signals that a file could not be opened.", CLASS },

	// ── java.nio.file ─────────────────────────────────────────────
	{ "Path", "interface Path : Comparable<Path>, Iterable<Path>", "java.nio.file", "", "An object used to locate a file in a file system.", INTERFACE },
	{ "Paths", "class Paths", "java.nio.file", "", "Consists exclusively of static methods that return a Path.", CLASS },
	{ "Files", "class Files", "java.nio.file", "", "Consists exclusively of static methods that operate on files and directories.", CLASS },
	{ "FileSystem", "class FileSystem : Closeable", "java.nio.file", "", "Provides an interface to a file system.", CLASS },
	{ "FileSystems", "class FileSystems", "java.nio.file", "", "Factory methods for file systems.", CLASS },
	{ "StandardOpenOption", "enum class StandardOpenOption : OpenOption", "java.nio.file", "", "Defines the standard open options.", CLASS },
	{ "StandardCopyOption", "enum class StandardCopyOption : CopyOption", "java.nio.file", "", "Defines the standard copy options.", CLASS },
	{ "FileVisitResult", "enum class FileVisitResult", "java.nio.file", "", "The result type of a FileVisitor.", CLASS },
	{ "WatchService", "interface WatchService : Closeable", "java.nio.file", "", "A watch service that watches registered objects for changes.", INTERFACE },

	// ── java.nio ──────────────────────────────────────────────────
	{ "ByteBuffer", "class ByteBuffer : Buffer, Comparable<ByteBuffer>", "java.nio", "", "A byte buffer.", CLASS },
	{ "CharBuffer", "class CharBuffer : Buffer, Comparable<CharBuffer>, Appendable, CharSequence, Readable", "java.nio", "", "A char buffer.", CLASS },
	{ "IntBuffer", "class IntBuffer : Buffer, Comparable<IntBuffer>", "java.nio", "", "An int buffer.", CLASS },
	{ "LongBuffer", "class LongBuffer : Buffer, Comparable<LongBuffer>", "java.nio", "", "A long buffer.", CLASS },
	{ "FloatBuffer", "class FloatBuffer : Buffer, Comparable<FloatBuffer>", "java.nio", "", "A float buffer.", CLASS },
	{ "DoubleBuffer", "class DoubleBuffer : Buffer, Comparable<DoubleBuffer>", "java.nio", "", "A double buffer.", CLASS },
	{ "Buffer", "class Buffer", "java.nio", "", "A container for data of a specific primitive type.", CLASS },

	// ── java.nio.charset ──────────────────────────────────────────
	{ "Charset", "class Charset : Comparable<Charset>", "java.nio.charset", "", "A named mapping between sequences of sixteen-bit Unicode characters and sequences of bytes.", CLASS },
	{ "StandardCharsets", "class StandardCharsets", "java.nio.charset", "", "Constant definitions for standard Charsets.", CLASS },

	// ── java.net ──────────────────────────────────────────────────
	{ "URL", "class URL : Serializable", "java.net", "", "Represents a Uniform Resource Locator.", CLASS },
	{ "URI", "class URI : Comparable<URI>, Serializable", "java.net", "", "Represents a Uniform Resource Identifier.", CLASS },
	{ "HttpURLConnection", "class HttpURLConnection : URLConnection", "java.net", "", "A URLConnection with support for HTTP.", CLASS },
	{ "URLConnection", "class URLConnection", "java.net", "", "Represents a communication link between the application and a URL.", CLASS },
	{ "Socket", "class Socket : Closeable", "java.net", "", "An endpoint for communication between two machines.", CLASS },
	{ "ServerSocket", "class ServerSocket : Closeable", "java.net", "", "A server socket that waits for requests over the network.", CLASS },
	{ "InetAddress", "class InetAddress : Serializable", "java.net", "", "Represents an Internet Protocol address.", CLASS },
	{ "InetSocketAddress", "class InetSocketAddress : SocketAddress", "java.net", "", "An IP socket address (IP address + port number).", CLASS },
	{ "URLEncoder", "class URLEncoder", "java.net", "", "Utility class for HTML form encoding.", CLASS },
	{ "URLDecoder", "class URLDecoder", "java.net", "", "Utility class for HTML form decoding.", CLASS },
	{ "Proxy", "class Proxy", "java.net", "", "Represents a proxy setting.", CLASS },

	// ── java.time ─────────────────────────────────────────────────
	{ "LocalDate", "class LocalDate : Temporal, TemporalAdjuster, ChronoLocalDate, Serializable", "java.time", "", "A date without a time-zone (e.g. 2007-12-03).", CLASS },
	{ "LocalTime", "class LocalTime : Temporal, TemporalAdjuster, Comparable<LocalTime>, Serializable", "java.time", "", "A time without a time-zone (e.g. 10:15:30).", CLASS },
	{ "LocalDateTime", "class LocalDateTime : Temporal, TemporalAdjuster, ChronoLocalDateTime<LocalDate>, Serializable", "java.time", "", "A date-time without a time-zone (e.g. 2007-12-03T10:15:30).", CLASS },
	{ "ZonedDateTime", "class ZonedDateTime : Temporal, ChronoZonedDateTime<LocalDate>, Serializable", "java.time", "", "A date-time with a time-zone.", CLASS },
	{ "OffsetDateTime", "class OffsetDateTime : Temporal, TemporalAdjuster, Comparable<OffsetDateTime>, Serializable", "java.time", "", "A date-time with an offset from UTC/Greenwich.", CLASS },
	{ "OffsetTime", "class OffsetTime : Temporal, TemporalAdjuster, Comparable<OffsetTime>, Serializable", "java.time", "", "A time with an offset from UTC/Greenwich.", CLASS },
	{ "Instant", "class Instant : Temporal, TemporalAdjuster, Comparable<Instant>, Serializable", "java.time", "", "An instantaneous point on the time-line.", CLASS },
	{ "Duration", "class Duration : TemporalAmount, Comparable<Duration>, Serializable", "java.time", "", "A time-based amount (e.g. '34.5 seconds').", CLASS },
	{ "Period", "class Period : ChronoPeriod, Serializable", "java.time", "", "A date-based amount (e.g. '2 years, 3 months and 4 days').", CLASS },
	{ "ZoneId", "class ZoneId : Serializable", "java.time", "", "A time-zone ID, such as Europe/Paris.", CLASS },
	{ "ZoneOffset", "class ZoneOffset : ZoneId, TemporalAccessor, TemporalAdjuster, Comparable<ZoneOffset>, Serializable", "java.time", "", "A time-zone offset from Greenwich/UTC.", CLASS },
	{ "Clock", "class Clock", "java.time", "", "A clock providing access to the current instant, date and time.", CLASS },
	{ "Year", "class Year : Temporal, TemporalAdjuster, Comparable<Year>, Serializable", "java.time", "", "A year in the ISO-8601 calendar system.", CLASS },
	{ "YearMonth", "class YearMonth : Temporal, TemporalAdjuster, Comparable<YearMonth>, Serializable", "java.time", "", "A year-month in the ISO-8601 calendar system.", CLASS },
	{ "Month", "enum class Month : TemporalAccessor, TemporalAdjuster", "java.time", "", "A month-of-year (JANUARY to DECEMBER).", CLASS },
	{ "DayOfWeek", "enum class DayOfWeek : TemporalAccessor, TemporalAdjuster", "java.time", "", "A day-of-week (MONDAY to SUNDAY).", CLASS },
	{ "MonthDay", "class MonthDay : TemporalAccessor, TemporalAdjuster, Comparable<MonthDay>, Serializable", "java.time", "", "A month-day in the ISO-8601 calendar system.", CLASS },

	// ── java.time.format ──────────────────────────────────────────
	{ "DateTimeFormatter", "class DateTimeFormatter", "java.time.format", "", "Formatter for printing and parsing date-time objects.", CLASS },
	{ "DateTimeFormatterBuilder", "class DateTimeFormatterBuilder", "java.time.format", "", "Builder to create date-time formatters.", CLASS },
	{ "DateTimeParseException", "class DateTimeParseException : DateTimeException", "java.time.format", "", "An exception thrown when a parse error occurs.", CLASS },

	// ── java.time.temporal ────────────────────────────────────────
	{ "ChronoUnit", "enum class ChronoUnit : TemporalUnit", "java.time.temporal", "", "A standard set of date-time units.", CLASS },
	{ "ChronoField", "enum class ChronoField : TemporalField", "java.time.temporal", "", "A standard set of fields.", CLASS },
	{ "TemporalAdjusters", "class TemporalAdjusters", "java.time.temporal", "", "Common and useful TemporalAdjusters.", CLASS },

	// ── java.math ─────────────────────────────────────────────────
	{ "BigDecimal", "class BigDecimal : Number, Comparable<BigDecimal>", "java.math", "", "Immutable, arbitrary-precision signed decimal numbers.", CLASS },
	{ "BigInteger", "class BigInteger : Number, Comparable<BigInteger>", "java.math", "", "Immutable, arbitrary-precision integers.", CLASS },
	{ "MathContext", "class MathContext : Serializable", "java.math", "", "Encapsulates precision and rounding settings.", CLASS },
	{ "RoundingMode", "enum class RoundingMode", "java.math", "", "Specifies a rounding behavior for numerical operations.", CLASS },

	// ── java.text ─────────────────────────────────────────────────
	{ "SimpleDateFormat", "class SimpleDateFormat : DateFormat", "java.text", "", "A class for formatting and parsing dates in a locale-sensitive manner.", CLASS },
	{ "DateFormat", "class DateFormat : Format", "java.text", "", "An abstract class for date/time formatting.", CLASS },
	{ "NumberFormat", "class NumberFormat : Format", "java.text", "", "An abstract class for formatting numbers.", CLASS },
	{ "DecimalFormat", "class DecimalFormat : NumberFormat", "java.text", "", "A concrete subclass of NumberFormat for formatting decimal numbers.", CLASS },
	{ "MessageFormat", "class MessageFormat : Format", "java.text", "", "Provides means to produce concatenated messages in a language-neutral way.", CLASS },
	{ "Collator", "class Collator : Comparator<Any>, Cloneable", "java.text", "", "Performs locale-sensitive String comparison.", CLASS },

	// ── java.lang.reflect ─────────────────────────────────────────
	{ "Method", "class Method : Executable", "java.lang.reflect", "", "Provides information about a single method on a class or interface.", CLASS },
	{ "Field", "class Field : AccessibleObject, Member", "java.lang.reflect", "", "Provides information about a single field of a class or interface.", CLASS },
	{ "Constructor", "class Constructor<T> : Executable", "java.lang.reflect", "", "Provides information about a single constructor for a class.", CLASS },
	{ "Proxy", "class Proxy : Serializable", "java.lang.reflect", "", "Provides static methods for creating dynamic proxy instances.", CLASS },
	{ "Array", "class Array", "java.lang.reflect", "", "Provides static methods to dynamically create and access Java arrays.", CLASS },

	// ── java.lang.annotation ──────────────────────────────────────
	{ "Retention", "annotation class Retention", "java.lang.annotation", "", "Indicates how long annotations are to be retained.", CLASS },
	{ "Target", "annotation class Target", "java.lang.annotation", "", "Indicates the contexts in which an annotation type is applicable.", CLASS },
	{ "Documented", "annotation class Documented", "java.lang.annotation", "", "Indicates that annotations should be documented by javadoc.", CLASS },
	{ "Inherited", "annotation class Inherited", "java.lang.annotation", "", "Indicates that an annotation type is automatically inherited.", CLASS },
	{ "Repeatable", "annotation class Repeatable", "java.lang.annotation", "", "Indicates that the annotation type is repeatable.", CLASS },

	// ── java.security ─────────────────────────────────────────────
	{ "MessageDigest", "class MessageDigest : MessageDigestSpi", "java.security", "", "Provides message digest algorithms (e.g. SHA-256, MD5).", CLASS },
	{ "SecureRandom", "class SecureRandom : Random", "java.security", "", "A cryptographically strong random number generator.", CLASS },
	{ "KeyStore", "class KeyStore", "java.security", "", "Represents a storage facility for cryptographic keys and certificates.", CLASS },
	{ "KeyPair", "class KeyPair : Serializable", "java.security", "", "Holds a public key and its corresponding private key.", CLASS },
	{ "KeyPairGenerator", "class KeyPairGenerator : KeyPairGeneratorSpi", "java.security", "", "Generates pairs of public and private keys.", CLASS },
	{ "Signature", "class Signature : SignatureSpi", "java.security", "", "Provides the functionality of a digital signature algorithm.", CLASS },

	// ── javax.crypto ──────────────────────────────────────────────
	{ "Cipher", "class Cipher", "javax.crypto", "", "Provides the functionality of a cryptographic cipher.", CLASS },
	{ "SecretKey", "interface SecretKey : Key, Destroyable", "javax.crypto", "", "A secret (symmetric) key.", INTERFACE },
	{ "SecretKeyFactory", "class SecretKeyFactory", "javax.crypto", "", "A factory for secret keys.", CLASS },
	{ "KeyGenerator", "class KeyGenerator", "javax.crypto", "", "Provides the functionality of a secret key generator.", CLASS },
	{ "Mac", "class Mac : Cloneable", "javax.crypto", "", "Provides the functionality of a Message Authentication Code.", CLASS },

	// ── java.sql ──────────────────────────────────────────────────
	{ "Connection", "interface Connection : Wrapper, AutoCloseable", "java.sql", "", "A connection (session) with a specific database.", INTERFACE },
	{ "Statement", "interface Statement : Wrapper, AutoCloseable", "java.sql", "", "The object used for executing a static SQL statement.", INTERFACE },
	{ "PreparedStatement", "interface PreparedStatement : Statement", "java.sql", "", "A precompiled SQL statement.", INTERFACE },
	{ "CallableStatement", "interface CallableStatement : PreparedStatement", "java.sql", "", "The interface used to execute SQL stored procedures.", INTERFACE },
	{ "ResultSet", "interface ResultSet : Wrapper, AutoCloseable", "java.sql", "", "A table of data representing a database result set.", INTERFACE },
	{ "DriverManager", "class DriverManager", "java.sql", "", "The basic service for managing a set of JDBC drivers.", CLASS },
	{ "SQLException", "class SQLException : Exception, Iterable<Throwable>", "java.sql", "", "An exception that provides information on a database access error.", CLASS },
	{ "Timestamp", "class Timestamp : Date", "java.sql", "", "A wrapper around java.util.Date for SQL TIMESTAMP.", CLASS },
	{ "Blob", "interface Blob", "java.sql", "", "The representation of an SQL BLOB value.", INTERFACE },
	{ "Clob", "interface Clob", "java.sql", "", "The mapping for the SQL CLOB type.", INTERFACE },
	{ "DataSource", "interface DataSource : CommonDataSource, Wrapper", "javax.sql", "", "A factory for connections to the physical data source.", INTERFACE },

	// ── java.util.function ────────────────────────────────────────
	{ "Predicate", "interface Predicate<T>", "java.util.function", "", "Represents a predicate (boolean-valued function) of one argument.", INTERFACE },
	{ "Function", "interface Function<T, R>", "java.util.function", "", "Represents a function that accepts one argument and produces a result.", INTERFACE },
	{ "Consumer", "interface Consumer<T>", "java.util.function", "", "Represents an operation that accepts a single input argument.", INTERFACE },
	{ "Supplier", "interface Supplier<T>", "java.util.function", "", "Represents a supplier of results.", INTERFACE },
	{ "BiFunction", "interface BiFunction<T, U, R>", "java.util.function", "", "Represents a function that accepts two arguments and produces a result.", INTERFACE },
	{ "BiConsumer", "interface BiConsumer<T, U>", "java.util.function", "", "Represents an operation that accepts two input arguments.", INTERFACE },
	{ "BiPredicate", "interface BiPredicate<T, U>", "java.util.function", "", "Represents a predicate of two arguments.", INTERFACE },
	{ "UnaryOperator", "interface UnaryOperator<T> : Function<T, T>", "java.util.function", "", "Represents an operation on a single operand producing a same-type result.", INTERFACE },
	{ "BinaryOperator", "interface BinaryOperator<T> : BiFunction<T, T, T>", "java.util.function", "", "Represents an operation upon two same-type operands producing a same-type result.", INTERFACE },
};
