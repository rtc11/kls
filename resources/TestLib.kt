package com.test.lib

// ── Regular open class with primary constructor, fields, methods, companion ──

/**
 * Base class for all animals in the system.
 *
 * @param name the display name of the animal
 * @param age the age in years
 */
open class Animal(val name: String, var age: Int) {
    /** Make this animal speak. */
    open fun speak(): String = "..."

    /**
     * Describe the animal.
     * @return a human-readable description
     */
    fun describe(): String = "$name, age $age"

    companion object {
        /** Factory method to create an unnamed animal. */
        fun create(name: String): Animal = Animal(name, 0)

        /** Default species name. */
        const val DEFAULT_SPECIES: String = "Unknown"
    }
}

// ── Interface ──

/** Something that can be summarized. */
interface Describable {
    /** Produce a short summary string. */
    fun summary(): String
}

// ── Subclass implementing interface (tests supertypes) ──

/**
 * A dog is an animal with a breed.
 *
 * @param breed the dog breed (e.g. "Labrador")
 */
class Dog(name: String, age: Int, val breed: String) : Animal(name, age), Describable {
    override fun speak(): String = "Woof"
    override fun summary(): String = "$name ($breed)"
}

// ── Enum class ──

/**
 * RGB color constants.
 * @property hex the hex color code
 */
enum class Color(val hex: String) {
    RED("#FF0000"),
    GREEN("#00FF00"),
    BLUE("#0000FF");

    /** Returns a lighter shade (placeholder). */
    fun lighter(): Color = this
}

// ── Annotation class ──

/**
 * Marks a function for special processing.
 * @property tag an optional tag string
 */
@Target(AnnotationTarget.FUNCTION, AnnotationTarget.CLASS)
annotation class Marker(val tag: String = "")

// ── Data class ──

/**
 * A 2D point with integer coordinates.
 * @property x horizontal coordinate
 * @property y vertical coordinate
 */
data class Point(val x: Int, val y: Int) {
    /**
     * Euclidean distance to another point.
     * @param other the target point
     * @return the distance as a Double
     */
    fun distanceTo(other: Point): Double =
        Math.sqrt(((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).toDouble())
}

// ── Sealed class with nested subtypes ──

/**
 * Represents a computation result that is either success or error.
 */
sealed class Result {
    /** Successful result holding a value. */
    data class Success(val value: String) : Result()
    /** Error result holding a message. */
    data class Error(val message: String) : Result()
}

// ── Object (singleton) ──

/**
 * Global registry for named entries.
 */
object Registry {
    /** All registered entry names. */
    val entries: MutableList<String> = mutableListOf()

    /** Register a new entry by name. */
    fun register(name: String) { entries.add(name) }

    /** Check if an entry exists. */
    fun contains(name: String): Boolean = entries.contains(name)
}

// ── Interface with generics and default method ──

/**
 * Generic repository for CRUD operations.
 * @param T the entity type
 */
interface Repository<T> {
    /** Find an entity by its ID. */
    fun findById(id: Int): T?

    /** Return all entities. */
    fun findAll(): List<T>

    /** Save an entity. Returns true on success. */
    fun save(item: T): Boolean { return true }
}

// ── Value class (inline) ──

/**
 * Type-safe wrapper for email addresses.
 * @property address the email string
 */
@JvmInline
value class Email(val address: String) {
    /** Check if the email is valid (contains @). */
    fun isValid(): Boolean = "@" in address
}

// ── Abstract class ──

/**
 * Base class for shapes with area computation.
 */
abstract class Shape {
    /** Compute the area of this shape. */
    abstract fun area(): Double

    /** Human-readable shape description. */
    open fun describe(): String = "Shape with area ${area()}"
}

// ── Concrete subclass of abstract ──

/**
 * A circle with a given radius.
 * @property radius the circle radius
 */
class Circle(val radius: Double) : Shape() {
    override fun area(): Double = Math.PI * radius * radius
}

// ── Inner class ──

/**
 * A container holding items.
 */
class Container<T>(val items: MutableList<T> = mutableListOf()) {
    /** Iterator for this container's items. */
    inner class ItemIterator {
        private var index = 0
        fun hasNext(): Boolean = index < items.size
        fun next(): T = items[index++]
    }

    fun iterator(): ItemIterator = ItemIterator()
    fun add(item: T) { items.add(item) }
    fun size(): Int = items.size
}

// ── Typealias (won't produce .class but good for source tests) ──

typealias StringMap = Map<String, String>
typealias Predicate<T> = (T) -> Boolean

// ══════════════════════════════════════════════════════════════════
// Top-level functions — these produce a TestLibKt facade class (metadata k=2)
// ══════════════════════════════════════════════════════════════════

/**
 * Greet someone by name.
 * @param name the person to greet
 * @return the greeting string
 */
fun greet(name: String): String = "Hello, $name"

// ── Extension functions (receiver type in metadata) ──

/**
 * Capitalize the first character of a string.
 * @return the capitalized string
 */
fun String.capitalize2(): String = this.replaceFirstChar { it.uppercase() }

/** Get the second element or null. */
fun <T> List<T>.secondOrNull(): T? = if (size >= 2) this[1] else null

/** Swap two elements in a mutable list. */
fun <T> MutableList<T>.swap(i: Int, j: Int) {
    val tmp = this[i]
    this[i] = this[j]
    this[j] = tmp
}

// ── Function with receiver lambda param ──

/**
 * Build an [Animal] using a configuration block.
 * Inside the block, `this` refers to the Animal being built.
 *
 * @param block configuration lambda with Animal as receiver
 * @return the configured Animal
 */
fun buildAnimal(block: Animal.() -> Unit): Animal {
    val a = Animal("", 0)
    a.block()
    return a
}

// ── Higher-order functions ──

/**
 * Transform a value using a mapper function.
 * @param value the input value
 * @param mapper transformation function
 * @return the transformed value
 */
fun <T, R> transform(value: T, mapper: (T) -> R): R = mapper(value)

/**
 * Apply a filter and map in one pass.
 * @param items the input list
 * @param predicate filter condition
 * @param mapper transformation for matching items
 * @return filtered and transformed list
 */
fun <T, R> filterMap(items: List<T>, predicate: (T) -> Boolean, mapper: (T) -> R): List<R> =
    items.filter(predicate).map(mapper)

// ── Suspend function ──

/**
 * Fetch data from a URL (simulated).
 * @param url the URL to fetch from
 * @return the response body
 */
suspend fun fetchData(url: String): String = ""

// ── Nullable params and return ──

/**
 * Parse a string to Int, returning null on failure.
 * @param text the input text, may be null
 * @return the parsed integer or null
 */
fun parseOrNull(text: String?): Int? = text?.toIntOrNull()

// ── Overloaded functions ──

/** Convert an Int to String. */
fun convert(value: Int): String = value.toString()

/** Convert a Double to String. */
fun convert(value: Double): String = value.toString()

/** Convert a Boolean to String. */
fun convert(value: Boolean): String = if (value) "yes" else "no"

// ── Infix function ──

/** Raise this Int to a power (simplified, always returns 1). */
infix fun Int.power(exp: Int): Int {
    var result = 1
    repeat(exp) { result *= this }
    return result
}

// ── Operator overloading ──

/** Add two points. */
operator fun Point.plus(other: Point): Point = Point(x + other.x, y + other.y)

/** Subtract two points. */
operator fun Point.minus(other: Point): Point = Point(x - other.x, y - other.y)

// ── Function with vararg ──

/**
 * Concatenate multiple strings with a separator.
 * @param separator the delimiter between strings
 * @param parts the strings to join
 * @return the joined string
 */
fun joinAll(separator: String, vararg parts: String): String = parts.joinToString(separator)

// ── Function with default parameters ──

/**
 * Create a greeting message.
 * @param name who to greet
 * @param greeting the greeting word
 * @param punctuation end punctuation
 * @return the full greeting
 */
fun greetFull(name: String, greeting: String = "Hello", punctuation: String = "!"): String =
    "$greeting, $name$punctuation"

// ── Crossinline / noinline (lambda modifiers) ──

/**
 * Execute a block inline with crossinline semantics.
 */
inline fun <T> runSafe(crossinline block: () -> T): T = block()

/**
 * Execute with a noinline callback for later use.
 */
inline fun <T> withCallback(value: T, noinline callback: (T) -> Unit): T {
    callback(value)
    return value
}

// ── Reified type parameter ──

/**
 * Check if a value is of type T.
 */
inline fun <reified T> isInstance(value: Any): Boolean = value is T

// ── Tailrec function ──

/**
 * Compute factorial using tail recursion.
 * @param n the number
 * @param acc accumulator
 * @return n factorial
 */
tailrec fun factorial(n: Long, acc: Long = 1): Long =
    if (n <= 1) acc else factorial(n - 1, n * acc)

// ── Destructuring-compatible class (already have data class Point, add componentN) ──

/**
 * A named pair for manual destructuring.
 */
class NamedPair<A, B>(val first: A, val second: B) {
    operator fun component1(): A = first
    operator fun component2(): B = second
}

// ── Lazy property via delegation (in a class) ──

/**
 * Configuration that loads lazily.
 */
class Config {
    /** The configuration map, loaded lazily. */
    val settings: Map<String, String> by lazy { mapOf("key" to "value") }

    /** A lateinit property. */
    lateinit var name: String

    /** Computed property with custom getter. */
    val isEmpty: Boolean get() = !::name.isInitialized
}

// ── Constant top-level properties ──

/** The maximum allowed retry count. */
const val MAX_RETRIES: Int = 3

/** Application version string. */
const val VERSION: String = "1.0.0"

/** A top-level mutable property. */
var debugMode: Boolean = false

/** A top-level val with explicit type. */
val defaultName: String = "World"
