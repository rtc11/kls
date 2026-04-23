module kls::deps::member_resolver;

/*
 * Shared dep-class member resolution.
 *
 * Both `kls::lsp::hover::describe_dep_member` and
 * `kls::lsp::definition::find_dep_member_definition` historically
 * implemented the same lookup pipeline with subtle drift:
 *   - Class verification + best-match by import-package preference
 *   - Member matching via signature-prefix, first-param, and class_name
 *   - Static-vs-instance filtering against TypeRef.is_class_ref
 *   - One-level supertype walk fallback
 *
 * Definition's version was a strict subset (only class_name match),
 * causing extension functions whose receiver is encoded in the
 * signature (e.g. `fun ArrayList.get(...)` indexed under a Kotlin
 * file class) to be unreachable from go-to-def while reachable from
 * hover.
 *
 * This module owns the shared pipeline. Callers wrap the result in
 * their preferred output format (Location, markdown, completion item).
 */

import std::collections;
import kls::deps::jar_index;

// ── Static-vs-instance accessibility filter ──────────────────────

/**
 * Strict accessibility filter for `receiver.member` access:
 *   - class-ref receiver (e.g. `UUID.randomUUID`)  → only static members
 *   - instance receiver (e.g. `someUuid.toString`) → only non-static members
 *
 * Both directions enforced. Callers must supply an accurate
 * `receiver_is_class_ref` (currently driven by `TypeRef.is_class_ref`,
 * set by the type resolver in `kls::kotlin::types`). When the
 * discriminator is unknown (no type info), callers fall through the
 * UNKNOWN-receiver path which bypasses this filter.
 */
fn bool is_member_accessible(DepSymbol* sym, bool receiver_is_class_ref) {
	if (sym == null) return false;
	if (receiver_is_class_ref) {
		return sym.is_static;
	}
	return !sym.is_static;
}

/**
 * Heuristic: does `name` resolve to a class/interface/enum/object/annotation
 * in the dep index? Used by callers (hover/definition) to decide whether
 * `Name.member` is a static (class-ref) access or an instance access when
 * TypeInfo doesn't supply the discriminator.
 */
fn bool is_dep_class_name(DependencyIndex* dep_index, String name) {
	if (dep_index == null || !dep_index.initialized || name.len == 0) return false;
	DepSymbol*[16] matches;
	usz count = dep_index.lookup_by_name(name, &matches);
	for (usz i = 0; i < count; i++) {
		switch (matches[i].kind) {
			case DEP_CLASS:
			case DEP_INTERFACE:
			case DEP_ENUM:
			case DEP_OBJECT:
			case DEP_ANNOTATION:
				return true;
			default:
				continue;
		}
	}
	return false;
}

// ── Signature-text utilities ─────────────────────────────────────

/**
 * Check if a signature starts with "fun ReceiverType.name(..." pattern.
 * E.g. sig="fun ArrayList.get(Int): Any", receiver="ArrayList" -> true
 */
fn bool sig_has_receiver_prefix(String sig, String receiver_type) {
	if (sig.len < 5 || sig[:4] != "fun ") return false;
	String after_fun = sig[4..];
	if (after_fun.len <= receiver_type.len) return false;
	if (after_fun[:receiver_type.len] == receiver_type &&
		after_fun[receiver_type.len] == '.') {
		return true;
	}
	return false;
}

/**
 * Extract the base type name from a signature's first parameter.
 * For "fun getOrNull(Array<Any>, Int): Any" -> "Array"
 * For "fun getOrNull(List, Int): Any" -> "List"
 * Returns empty string if no parameters or cannot parse.
 */
fn String extract_first_param_type(String sig) {
	usz paren = 0;
	while (paren < sig.len && sig[paren] != '(') {
		paren++;
	}
	if (paren >= sig.len) return "";
	paren++;
	while (paren < sig.len && sig[paren] == ' ') paren++;
	if (paren >= sig.len || sig[paren] == ')') return "";

	usz start = paren;
	usz end = start;
	while (end < sig.len) {
		char c = sig[end];
		if (c == ',' || c == ')' || c == '<') break;
		end++;
	}
	if (end <= start) return "";
	while (end > start && sig[end - 1] == ' ') end--;
	return sig[start..end - 1];
}

/**
 * Check if a parameter type is compatible with the receiver type.
 * Handles subtyping for common Kotlin/Java collection hierarchies.
 */
fn bool receiver_type_matches(String param_type, String receiver_type) {
	if (param_type == receiver_type) return true;
	if (param_type == "Any" || param_type == "Object") return true;
	if (param_type == "Array" && receiver_type == "Array") return true;

	if (param_type == "Iterable" || param_type == "Collection") {
		if (receiver_type == "List" || receiver_type == "MutableList" ||
			receiver_type == "Set" || receiver_type == "MutableSet" ||
			receiver_type == "Collection" || receiver_type == "ArrayList" ||
			receiver_type == "HashSet" || receiver_type == "LinkedHashSet" ||
			receiver_type == "Iterable" || receiver_type == "Sequence") {
			return true;
		}
	}
	if (param_type == "List") {
		if (receiver_type == "List" || receiver_type == "MutableList" ||
			receiver_type == "ArrayList") {
			return true;
		}
	}
	if (param_type == "Set") {
		if (receiver_type == "Set" || receiver_type == "MutableSet" ||
			receiver_type == "HashSet" || receiver_type == "LinkedHashSet") {
			return true;
		}
	}
	if (param_type == "Map") {
		if (receiver_type == "Map" || receiver_type == "MutableMap" ||
			receiver_type == "HashMap" || receiver_type == "LinkedHashMap") {
			return true;
		}
	}
	if (param_type == "CharSequence") {
		if (receiver_type == "String" || receiver_type == "StringBuilder" ||
			receiver_type == "CharSequence") {
			return true;
		}
	}
	if (param_type == "Comparable") return true;

	return false;
}

// ── Shared dep-class member lookup ───────────────────────────────

/**
 * Find the best-matching class symbol for `class_name` in the dep
 * index, preferring the package matching `preferred_pkg` (from
 * explicit imports). Returns null when no class-like symbol matches.
 */
fn DepSymbol* find_best_class(DependencyIndex* dep_index, String class_name, String preferred_pkg) {
	DepSymbol*[16] class_matches;
	usz class_count = dep_index.lookup_by_name(class_name, &class_matches);
	DepSymbol* best_class = null;
	for (usz i = 0; i < class_count; i++) {
		DepSymbolKind k = class_matches[i].kind;
		if (k != DEP_CLASS && k != DEP_INTERFACE && k != DEP_ENUM &&
			k != DEP_ANNOTATION && k != DEP_OBJECT) continue;
		if (preferred_pkg.len > 0 && class_matches[i].package_name == preferred_pkg) {
			return class_matches[i];
		}
		if (best_class == null) best_class = class_matches[i];
	}
	return best_class;
}

/**
 * Find dep-class members matching `member_name` for the receiver
 * type `class_name`. Fills `out` with up to `out.len` candidates.
 *
 * Matching strategy (in order):
 *   1. Signature receiver prefix (`fun ClassName.member(...)`)
 *   2. First parameter type compatible with receiver
 *   3. Declaring class equality (Java methods/fields)
 *
 * Filters out members that fail `is_member_accessible` for the
 * given receiver-class-ref flag. Walks one level of supertypes
 * if no direct match found. Reorders so that members from
 * `preferred_pkg` come first.
 *
 * Returns count of candidates written to `out`.
 */
fn usz find_dep_class_members(
		DependencyIndex* dep_index,
		String class_name,
		String member_name,
		bool receiver_is_class_ref,
		String preferred_pkg,
		DepSymbol*[] out) {

	if (dep_index == null || !dep_index.initialized) return 0;
	if (out.len == 0) return 0;

	// Resolve best class-symbol for supertype walk + class-known guard.
	DepSymbol* best_class = find_best_class(dep_index, class_name, preferred_pkg);
	bool is_known_class = best_class != null;

	DepSymbol*[32] all_matches;
	usz total = dep_index.lookup_by_name(member_name, &all_matches);

	if (total == 0 && !is_known_class) return 0;

	usz count = 0;
	for (usz i = 0; i < total && count < out.len; i++) {
		DepSymbol* sym = all_matches[i];
		bool matched = false;

		// Check 1: instance method signature "fun ClassName.member(...)"
		if (sig_has_receiver_prefix(sym.signature, class_name)) {
			matched = true;
		}

		// Check 2: static extension function — receiver is first param
		if (!matched) {
			String first_param = extract_first_param_type(sym.signature);
			if (first_param.len > 0 && receiver_type_matches(first_param, class_name)) {
				matched = true;
			}
		}

		// Check 3: declaring class matches receiver (Java methods/fields)
		if (!matched && is_known_class && sym.class_name.len > 0 &&
			sym.class_name == class_name &&
			(sym.kind == DEP_METHOD || sym.kind == DEP_FIELD)) {
			matched = true;
		}

		// Static-vs-instance filter
		if (matched && !is_member_accessible(sym, receiver_is_class_ref)) {
			matched = false;
		}

		if (matched) {
			out[count] = sym;
			count++;
		}
	}

	// Supertype walk: if no direct match, try one level up.
	if (count == 0 && best_class != null) {
		for (usz s = 0; s < best_class.supertype_count && count < out.len; s++) {
			String super_name = best_class.supertypes[s];
			if (super_name.len == 0) continue;
			DepSymbol*[32] super_matches;
			usz super_count = dep_index.lookup_by_name(member_name, &super_matches);
			for (usz i = 0; i < super_count && count < out.len; i++) {
				DepSymbol* sym = super_matches[i];
				if (sym.class_name == super_name &&
					(sym.kind == DEP_METHOD || sym.kind == DEP_FIELD)) {
					if (!is_member_accessible(sym, receiver_is_class_ref)) continue;
					out[count] = sym;
					count++;
				}
			}
			if (count > 0) break;
		}
	}

	if (count == 0) return 0;

	// Reorder: prefer entries whose package matches preferred_pkg.
	// Stable selection — first matching package wins, others kept in order.
	if (preferred_pkg.len > 0) {
		for (usz i = 0; i < count; i++) {
			if (out[i].package_name == preferred_pkg && i > 0) {
				DepSymbol* preferred = out[i];
				for (usz j = i; j > 0; j--) out[j] = out[j - 1];
				out[0] = preferred;
				break;
			}
		}
	}

	return count;
}

/**
 * Enumerate all accessible members of a dep class for completion.
 *
 * Unlike `find_dep_class_members` (lookup by member name), this returns
 * every method/field declared on `class_name`, then walks one level of
 * supertypes for inherited members. Static/instance filter applied via
 * `is_member_accessible(receiver_is_class_ref)`.
 *
 * Backed by `dep_index.lookup_members_by_class` (O(class members), not
 * O(all symbols)).
 *
 * Returns count of pointers written to `out`. May contain duplicates by
 * name if a subclass overrides a supertype member — caller dedups.
 */
fn usz find_dep_class_all_members(
		DependencyIndex* dep_index,
		String class_name,
		bool receiver_is_class_ref,
		DepSymbol*[] out) {

	if (dep_index == null || !dep_index.initialized) return 0;
	if (out.len == 0 || class_name.len == 0) return 0;

	usz count = 0;

	// Direct members
	DepSymbol*[256] direct;
	usz direct_count = dep_index.lookup_members_by_class(class_name, &direct);
	for (usz i = 0; i < direct_count && count < out.len; i++) {
		DepSymbol* sym = direct[i];
		if (!is_member_accessible(sym, receiver_is_class_ref)) continue;
		out[count] = sym;
		count++;
	}

	// Supertype walk for inherited members.
	// Look up class symbol to get supertype list.
	DepSymbol*[16] class_matches;
	usz class_count = dep_index.lookup_by_name(class_name, &class_matches);
	DepSymbol* class_sym = null;
	for (usz i = 0; i < class_count; i++) {
		DepSymbol* s = class_matches[i];
		if (s.kind == DEP_CLASS || s.kind == DEP_INTERFACE ||
			s.kind == DEP_ENUM || s.kind == DEP_OBJECT) {
			class_sym = s;
			break;
		}
	}

	if (class_sym != null) {
		for (usz s = 0; s < class_sym.supertype_count && count < out.len; s++) {
			String super_name = class_sym.supertypes[s];
			if (super_name.len == 0) continue;

			DepSymbol*[256] inherited;
			usz inh_count = dep_index.lookup_members_by_class(super_name, &inherited);
			for (usz i = 0; i < inh_count && count < out.len; i++) {
				DepSymbol* sym = inherited[i];
				if (!is_member_accessible(sym, receiver_is_class_ref)) continue;
				out[count] = sym;
				count++;
			}
		}
	}

	return count;
}
