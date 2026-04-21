module kls::dap::evaluate;

import std::collections::object;
import kls::log;
import kls::dap::jdwp::transport;
import kls::dap::jdwp::protocol;
import kls::dap::jdwp::ids;
import kls::dap::variables;

// ── Expression value representation ─────────────────────────────────

// A runtime value during expression evaluation.
// Primitives stored inline (tag + raw_value). Objects by JDWP objectID.
struct EvalValue {
	char tag;       // JDWP tag: 'I','J','D','F','Z','B','S','C','s','L','[','V'
	long raw;       // For primitives: value bits. For objects: objectID.
	bool is_error;
	String error_msg;
}

fn EvalValue eval_int(int v)    { return { .tag = 'I', .raw = (long)v }; }
fn EvalValue eval_long(long v)  { return { .tag = 'J', .raw = v }; }
fn EvalValue eval_double(long bits) { return { .tag = 'D', .raw = bits }; }
fn EvalValue eval_float(int bits)  { return { .tag = 'F', .raw = (long)bits }; }
fn EvalValue eval_bool(bool v)  { return { .tag = 'Z', .raw = v ? 1 : 0 }; }
fn EvalValue eval_null()        { return { .tag = 'L', .raw = 0 }; }
fn EvalValue eval_object(long id) { return { .tag = 'L', .raw = id }; }
fn EvalValue eval_string_obj(long id) { return { .tag = 's', .raw = id }; }
fn EvalValue eval_array_obj(long id) { return { .tag = '[', .raw = id }; }
fn EvalValue eval_error(String msg) { return { .is_error = true, .error_msg = msg }; }
fn EvalValue eval_class_ref(long type_id) { return { .tag = 'T', .raw = type_id }; }

fn bool EvalValue.is_truthy(EvalValue* self) {
	if (self.is_error) return false;
	switch (self.tag) {
		case 'Z': return self.raw != 0;
		case 'I': case 'J': case 'B': case 'S': case 'C': return self.raw != 0;
		case 'L': case '[': case 's': return self.raw != 0;  // non-null = truthy
		default: return false;
	}
}

fn int EvalValue.to_int(EvalValue* self) {
	switch (self.tag) {
		case 'I': case 'B': case 'S': case 'C': return (int)self.raw;
		case 'J': return (int)self.raw;
		case 'Z': return self.raw != 0 ? 1 : 0;
		default: return 0;
	}
}

fn long EvalValue.to_long(EvalValue* self) {
	switch (self.tag) {
		case 'I': case 'B': case 'S': case 'C': case 'J': case 'Z': return self.raw;
		default: return 0;
	}
}

fn double EvalValue.to_double(EvalValue* self) {
	switch (self.tag) {
		case 'D':
			long bits = self.raw;
			return *((double*)&bits);
		case 'F':
			int fbits = (int)self.raw;
			return (double)*((float*)&fbits);
		case 'I': case 'B': case 'S': case 'C': return (double)(int)self.raw;
		case 'J': return (double)self.raw;
		default: return 0.0;
	}
}

fn bool EvalValue.is_numeric(EvalValue* self) {
	switch (self.tag) {
		case 'I': case 'J': case 'D': case 'F': case 'B': case 'S': case 'C': return true;
		default: return false;
	}
}

fn bool EvalValue.is_floating(EvalValue* self) {
	return self.tag == 'D' || self.tag == 'F';
}

// ── Expression tokens ───────────────────────────────────────────────

enum ExprTokenKind : char {
	IDENT,
	INT_LIT,
	LONG_LIT,
	DOUBLE_LIT,
	STRING_LIT,
	TRUE_LIT,
	FALSE_LIT,
	NULL_LIT,
	PLUS, MINUS, STAR, SLASH, PERCENT,
	EQ_EQ, BANG_EQ, LT, GT, LT_EQ, GT_EQ,
	AMP_AMP, PIPE_PIPE, BANG,
	DOT, COMMA,
	LPAREN, RPAREN,
	LBRACKET, RBRACKET,
	EOF,
}

struct ExprToken {
	ExprTokenKind kind;
	String text;    // slice into original expression
}

const int MAX_EXPR_TOKENS = 128;

struct ExprLexer {
	String src;
	usz pos;
	ExprToken[MAX_EXPR_TOKENS] tokens;
	int count;
}

fn void ExprLexer.init(ExprLexer* self, String src) {
	self.src = src;
	self.pos = 0;
	self.count = 0;
}

fn void ExprLexer.tokenize(ExprLexer* self) {
	while (self.pos < self.src.len && self.count < MAX_EXPR_TOKENS - 1) {
		char c = self.src[self.pos];

		// Skip whitespace
		if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
			self.pos++;
			continue;
		}

		// String literal
		if (c == '"') {
			usz start = self.pos;
			self.pos++;  // skip opening "
			while (self.pos < self.src.len && self.src[self.pos] != '"') {
				if (self.src[self.pos] == '\\') self.pos++;  // skip escape
				self.pos++;
			}
			if (self.pos < self.src.len) self.pos++;  // skip closing "
			self.add_token(STRING_LIT, self.src[start:self.pos - start]);
			continue;
		}

		// Number literal
		if (c >= '0' && c <= '9') {
			usz start = self.pos;
			bool is_float = false;
			while (self.pos < self.src.len && ((self.src[self.pos] >= '0' && self.src[self.pos] <= '9') || self.src[self.pos] == '.')) {
				if (self.src[self.pos] == '.') is_float = true;
				self.pos++;
			}
			// Check for L suffix (long literal)
			bool is_long = false;
			if (self.pos < self.src.len && (self.src[self.pos] == 'L' || self.src[self.pos] == 'l')) {
				is_long = true;
				self.pos++;
			}
			if (is_float) {
				self.add_token(DOUBLE_LIT, self.src[start:self.pos - start]);
			} else if (is_long) {
				self.add_token(LONG_LIT, self.src[start:self.pos - start - 1]);
			} else {
				self.add_token(INT_LIT, self.src[start:self.pos - start]);
			}
			continue;
		}

		// Identifier or keyword
		if (is_ident_start(c)) {
			usz start = self.pos;
			while (self.pos < self.src.len && is_ident_char(self.src[self.pos])) {
				self.pos++;
			}
			String word = self.src[start:self.pos - start];
			if (word == "true") { self.add_token(TRUE_LIT, word); }
			else if (word == "false") { self.add_token(FALSE_LIT, word); }
			else if (word == "null") { self.add_token(NULL_LIT, word); }
			else { self.add_token(IDENT, word); }
			continue;
		}

		// Two-character operators
		if (self.pos + 1 < self.src.len) {
			char c2 = self.src[self.pos + 1];
			if (c == '=' && c2 == '=') { self.add_token(EQ_EQ, "=="); self.pos += 2; continue; }
			if (c == '!' && c2 == '=') { self.add_token(BANG_EQ, "!="); self.pos += 2; continue; }
			if (c == '<' && c2 == '=') { self.add_token(LT_EQ, "<="); self.pos += 2; continue; }
			if (c == '>' && c2 == '=') { self.add_token(GT_EQ, ">="); self.pos += 2; continue; }
			if (c == '&' && c2 == '&') { self.add_token(AMP_AMP, "&&"); self.pos += 2; continue; }
			if (c == '|' && c2 == '|') { self.add_token(PIPE_PIPE, "||"); self.pos += 2; continue; }
		}

		// Single-character operators
		switch (c) {
			case '+': self.add_token(PLUS, "+"); self.pos++; continue;
			case '-': self.add_token(MINUS, "-"); self.pos++; continue;
			case '*': self.add_token(STAR, "*"); self.pos++; continue;
			case '/': self.add_token(SLASH, "/"); self.pos++; continue;
			case '%': self.add_token(PERCENT, "%"); self.pos++; continue;
			case '<': self.add_token(LT, "<"); self.pos++; continue;
			case '>': self.add_token(GT, ">"); self.pos++; continue;
			case '!': self.add_token(BANG, "!"); self.pos++; continue;
			case '.': self.add_token(DOT, "."); self.pos++; continue;
			case ',': self.add_token(COMMA, ","); self.pos++; continue;
			case '(': self.add_token(LPAREN, "("); self.pos++; continue;
			case ')': self.add_token(RPAREN, ")"); self.pos++; continue;
			case '[': self.add_token(LBRACKET, "["); self.pos++; continue;
			case ']': self.add_token(RBRACKET, "]"); self.pos++; continue;
			default: self.pos++;  // skip unknown char
		}
	}
	self.add_token(EOF, "");
}

fn void ExprLexer.add_token(ExprLexer* self, ExprTokenKind kind, String text) {
	if (self.count < MAX_EXPR_TOKENS) {
		self.tokens[self.count] = { .kind = kind, .text = text };
		self.count++;
	}
}

fn bool is_ident_start(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$';
}

fn bool is_ident_char(char c) {
	return is_ident_start(c) || (c >= '0' && c <= '9');
}

// ── Expression parser context ───────────────────────────────────────

struct EvalContext {
	JdwpConnection* conn;
	IdManager* id_mgr;
	int dap_frame_id;
	// Resolved frame info (cached)
	long thread_id;
	long frame_id;
	long class_id;
	long method_id;
	bool frame_resolved;
}

fn void EvalContext.resolve_frame(EvalContext* self) {
	if (self.frame_resolved) return;
	self.frame_resolved = true;
	if (try ref = self.id_mgr.get_frame(self.dap_frame_id)) {
		self.thread_id = ref.thread_id;
		self.frame_id = ref.frame_id;
		self.class_id = ref.class_id;
		self.method_id = ref.method_id;
	}
}

struct ExprParser {
	ExprToken* tokens;
	int count;
	int pos;
	EvalContext* ctx;
}

fn ExprToken* ExprParser.peek(ExprParser* self) {
	if (self.pos < self.count) return &self.tokens[self.pos];
	return null;
}

fn ExprToken* ExprParser.advance(ExprParser* self) {
	if (self.pos < self.count) {
		ExprToken* t = &self.tokens[self.pos];
		self.pos++;
		return t;
	}
	return null;
}

fn bool ExprParser.match_kind(ExprParser* self, ExprTokenKind kind) {
	if (self.pos < self.count && self.tokens[self.pos].kind == kind) {
		self.pos++;
		return true;
	}
	return false;
}

// ── Recursive descent expression parser ─────────────────────────────
// Precedence (low to high):
//   || -> && -> == != -> < > <= >= -> + - -> * / % -> unary(! -) -> postfix(. [] ())

fn EvalValue ExprParser.parse_expression(ExprParser* self) {
	return self.parse_or();
}

fn EvalValue ExprParser.parse_or(ExprParser* self) {
	EvalValue left = self.parse_and();
	while (self.peek() != null && self.peek().kind == PIPE_PIPE) {
		self.advance();
		EvalValue right = self.parse_and();
		left = eval_bool(left.is_truthy() || right.is_truthy());
	}
	return left;
}

fn EvalValue ExprParser.parse_and(ExprParser* self) {
	EvalValue left = self.parse_equality();
	while (self.peek() != null && self.peek().kind == AMP_AMP) {
		self.advance();
		EvalValue right = self.parse_equality();
		left = eval_bool(left.is_truthy() && right.is_truthy());
	}
	return left;
}

fn EvalValue ExprParser.parse_equality(ExprParser* self) {
	EvalValue left = self.parse_comparison();
	while (self.peek() != null) {
		ExprTokenKind k = self.peek().kind;
		if (k != EQ_EQ && k != BANG_EQ) break;
		self.advance();
		EvalValue right = self.parse_comparison();
		bool eq = values_equal(&left, &right);
		left = eval_bool(k == EQ_EQ ? eq : !eq);
	}
	return left;
}

fn EvalValue ExprParser.parse_comparison(ExprParser* self) {
	EvalValue left = self.parse_additive();
	while (self.peek() != null) {
		ExprTokenKind k = self.peek().kind;
		if (k != LT && k != GT && k != LT_EQ && k != GT_EQ) break;
		self.advance();
		EvalValue right = self.parse_additive();
		if (!left.is_numeric() || !right.is_numeric()) {
			left = eval_error("<cannot compare>");
			break;
		}
		double l = left.to_double();
		double r = right.to_double();
		bool result;
		switch (k) {
			case LT:    result = l < r;
			case GT:    result = l > r;
			case LT_EQ: result = l <= r;
			case GT_EQ: result = l >= r;
			default:    result = false;
		}
		left = eval_bool(result);
	}
	return left;
}

fn EvalValue ExprParser.parse_additive(ExprParser* self) {
	EvalValue left = self.parse_multiplicative();
	while (self.peek() != null) {
		ExprTokenKind k = self.peek().kind;
		if (k != PLUS && k != MINUS) break;
		self.advance();
		EvalValue right = self.parse_multiplicative();
		if (left.is_error) return left;
		if (right.is_error) return right;

		// String concatenation: if either side is a string object
		if (k == PLUS && (left.tag == 's' || right.tag == 's')) {
			left = string_concat(self.ctx, &left, &right);
			continue;
		}

		if (!left.is_numeric() || !right.is_numeric()) {
			return eval_error("<type mismatch>");
		}
		if (left.is_floating() || right.is_floating()) {
			double l = left.to_double();
			double r = right.to_double();
			double result = k == PLUS ? l + r : l - r;
			long bits = *((long*)&result);
			left = eval_double(bits);
		} else {
			long l = left.to_long();
			long r = right.to_long();
			long result = k == PLUS ? l + r : l - r;
			if (left.tag == 'J' || right.tag == 'J') {
				left = eval_long(result);
			} else {
				left = eval_int((int)result);
			}
		}
	}
	return left;
}

fn EvalValue ExprParser.parse_multiplicative(ExprParser* self) {
	EvalValue left = self.parse_unary();
	while (self.peek() != null) {
		ExprTokenKind k = self.peek().kind;
		if (k != STAR && k != SLASH && k != PERCENT) break;
		self.advance();
		EvalValue right = self.parse_unary();
		if (!left.is_numeric() || !right.is_numeric()) return eval_error("<type mismatch>");
		if (left.is_floating() || right.is_floating()) {
			double l = left.to_double();
			double r = right.to_double();
			double result;
			switch (k) {
				case STAR:    result = l * r;
				case SLASH:   result = r != 0 ? l / r : 0.0;
				case PERCENT: result = r != 0 ? l - (double)(long)(l / r) * r : 0.0;
				default: result = 0;
			}
			long bits = *((long*)&result);
			left = eval_double(bits);
		} else {
			long l = left.to_long();
			long r = right.to_long();
			long result;
			switch (k) {
				case STAR:    result = l * r;
				case SLASH:   result = r != 0 ? l / r : 0;
				case PERCENT: result = r != 0 ? l % r : 0;
				default: result = 0;
			}
			if (left.tag == 'J' || right.tag == 'J') {
				left = eval_long(result);
			} else {
				left = eval_int((int)result);
			}
		}
	}
	return left;
}

fn EvalValue ExprParser.parse_unary(ExprParser* self) {
	if (self.peek() != null) {
		if (self.peek().kind == BANG) {
			self.advance();
			EvalValue val = self.parse_unary();
			return eval_bool(!val.is_truthy());
		}
		if (self.peek().kind == MINUS) {
			self.advance();
			EvalValue val = self.parse_unary();
			if (val.is_floating()) {
				double d = -val.to_double();
				long bits = *((long*)&d);
				return eval_double(bits);
			}
			if (val.is_numeric()) {
				if (val.tag == 'J') return eval_long(-val.to_long());
				return eval_int(-val.to_int());
			}
			return eval_error("<cannot negate>");
		}
	}
	return self.parse_postfix();
}

fn EvalValue ExprParser.parse_postfix(ExprParser* self) {
	EvalValue val = self.parse_primary();

	while (self.peek() != null) {
		// Dot access: val.field or val.method(...)
		if (self.peek().kind == DOT) {
			self.advance();
			ExprToken* name_tok = self.advance();
			if (name_tok == null || name_tok.kind != IDENT) return eval_error("<expected field name>");

			// Check if it's a method call
			if (self.peek() != null && self.peek().kind == LPAREN) {
				self.advance();  // consume '('
				// Parse arguments
				EvalValue[8] args;
				int arg_count = 0;
				if (self.peek() != null && self.peek().kind != RPAREN) {
					args[arg_count] = self.parse_expression();
					arg_count++;
					while (self.peek() != null && self.peek().kind == COMMA && arg_count < 8) {
						self.advance();
						args[arg_count] = self.parse_expression();
						arg_count++;
					}
				}
				if (!self.match_kind(RPAREN)) return eval_error("<expected ')'>");
				val = invoke_method_on_value(self.ctx, &val, name_tok.text, args[:arg_count]);
			} else {
				// Field access
				val = read_field_from_value(self.ctx, &val, name_tok.text);
			}
			continue;
		}

		// Array index: val[expr]
		if (self.peek().kind == LBRACKET) {
			self.advance();
			EvalValue idx = self.parse_expression();
			if (!self.match_kind(RBRACKET)) return eval_error("<expected ']'>");
			val = read_array_element(self.ctx, &val, &idx);
			continue;
		}

		break;
	}

	return val;
}

fn EvalValue ExprParser.parse_primary(ExprParser* self) {
	ExprToken* tok = self.peek();
	if (tok == null) return eval_error("<unexpected end>");

	switch (tok.kind) {
		case INT_LIT:
			self.advance();
			int v = (int)(tok.text.to_int() ?? 0);
			return eval_int(v);

		case LONG_LIT:
			self.advance();
			long v = tok.text.to_long() ?? 0;
			return eval_long(v);

		case DOUBLE_LIT:
			self.advance();
			double v = tok.text.to_double() ?? 0.0;
			long bits = *((long*)&v);
			return eval_double(bits);

		case STRING_LIT:
			self.advance();
			// Strip quotes, create string in VM
			String content = tok.text.len >= 2 ? tok.text[1:tok.text.len - 2] : "";
			return create_vm_string(self.ctx, content);

		case TRUE_LIT:
			self.advance();
			return eval_bool(true);

		case FALSE_LIT:
			self.advance();
			return eval_bool(false);

		case NULL_LIT:
			self.advance();
			return eval_null();

		case IDENT:
			self.advance();
			if (tok.text == "this") {
				return resolve_this(self.ctx);
			}
			EvalValue local_val = resolve_local(self.ctx, tok.text);
			if (!local_val.is_error) return local_val;
			// Not a local — try resolving as class/object reference
			return resolve_static_class(self.ctx, tok.text);

		case LPAREN:
			self.advance();
			EvalValue val = self.parse_expression();
			if (!self.match_kind(RPAREN)) return eval_error("<expected ')'>");
			return val;

		default:
			self.advance();
			return eval_error("<unexpected token>");
	}
}

// ── Value operations ────────────────────────────────────────────────

fn bool values_equal(EvalValue* a, EvalValue* b) {
	// null checks
	if (a.tag == 'L' && a.raw == 0 && b.tag == 'L' && b.raw == 0) return true;
	if ((a.tag == 'L' && a.raw == 0) || (b.tag == 'L' && b.raw == 0)) {
		// One null, one not — check if other is also null-like object
		return a.raw == 0 && b.raw == 0;
	}
	// Both numeric
	if (a.is_numeric() && b.is_numeric()) {
		if (a.is_floating() || b.is_floating()) {
			return a.to_double() == b.to_double();
		}
		return a.to_long() == b.to_long();
	}
	// Same tag, same raw (e.g., same object reference)
	return a.tag == b.tag && a.raw == b.raw;
}

// ── JDWP value resolution helpers ───────────────────────────────────

fn EvalValue resolve_this(EvalContext* ctx) {
	ctx.resolve_frame();
	if (ctx.thread_id == 0) return eval_error("<no frame>");

	char[16] data;
	transport::put_long_be(data[..], 0, ctx.thread_id);
	transport::put_long_be(data[..], 8, ctx.frame_id);

	if (try id = ctx.conn.send_command(protocol::CS_STACK_FRAME, protocol::SF_THIS_OBJECT, data[:16])) {
		if (try reply = ctx.conn.read_reply()) {
			if (reply.error_code == 0 && reply.data.len >= 9) {
				char tag = reply.data[0];
				long object_id = transport::get_long_be(reply.data, 1);
				if (object_id == 0) return eval_null();
				if (tag == 's') return eval_string_obj(object_id);
				if (tag == '[') return eval_array_obj(object_id);
				return eval_object(object_id);
			}
		}
	}
	return eval_error("<cannot read this>");
}

fn EvalValue resolve_local(EvalContext* ctx, String name) {
	ctx.resolve_frame();
	if (ctx.class_id == 0 || ctx.method_id == 0) return eval_error("<no frame>");

	// Get variable table
	JdwpReply vt_reply;
	if (try r = protocol::get_variable_table(ctx.conn, ctx.class_id, ctx.method_id)) {
		vt_reply = r;
	} else {
		return eval_error("<cannot read variables>");
	}
	if (vt_reply.error_code != 0 || vt_reply.data.len < 8) return eval_error("<no variable table>");

	usz pos = 4;  // skip argCnt
	int slot_count = transport::get_int_be(vt_reply.data, pos); pos += 4;

	int target_slot = -1;
	char target_tag = 0;
	for (int i = 0; i < slot_count; i++) {
		if (pos + 8 > vt_reply.data.len) break;
		pos += 8; // skip codeIndex

		if (pos + 4 > vt_reply.data.len) break;
		int name_len = transport::get_int_be(vt_reply.data, pos); pos += 4;
		String var_name = "";
		if (name_len > 0 && pos + (usz)name_len <= vt_reply.data.len) {
			var_name = (String)vt_reply.data[pos:(usz)name_len];
		}
		pos += (usz)name_len;

		if (pos + 4 > vt_reply.data.len) break;
		int sig_len = transport::get_int_be(vt_reply.data, pos); pos += 4;
		String sig = "";
		if (sig_len > 0 && pos + (usz)sig_len <= vt_reply.data.len) {
			sig = (String)vt_reply.data[pos:(usz)sig_len];
		}
		pos += (usz)sig_len;

		if (pos + 8 > vt_reply.data.len) break;
		pos += 4; // skip length
		int slot = transport::get_int_be(vt_reply.data, pos); pos += 4;

		if (var_name == name) {
			target_slot = slot;
			target_tag = variables::sig_to_tag(sig);
			break;
		}
	}

	if (target_slot < 0) return eval_error("<not found>");

	int[1] slots = { target_slot };
	char[1] tags = { target_tag };
	if (try reply = protocol::get_frame_values(ctx.conn, ctx.thread_id, ctx.frame_id, slots[..], tags[..])) {
		if (reply.error_code == 0 && reply.data.len >= 5) {
			usz vpos = 4;
			char val_tag = reply.data[vpos]; vpos++;
			int val_size = variables::tag_value_size(val_tag);
			if (vpos + (usz)val_size <= reply.data.len) {
				return extract_eval_value(val_tag, reply.data, vpos);
			}
		}
	}
	return eval_error("<read error>");
}

// Try to resolve a name as a class/object reference.
// 1. Get current class signature to extract package prefix
// 2. Try L{package}/{name}; then L{name};
// 3. If class has INSTANCE static field (Kotlin object), return it as object
// 4. Otherwise return as class ref (tag 'T')
fn EvalValue resolve_static_class(EvalContext* ctx, String name) {
	ctx.resolve_frame();
	if (ctx.class_id == 0) return eval_error("<no frame>");

	// Get current class signature to extract package
	String pkg = "";
	if (try reply = protocol::get_reference_type_signature(ctx.conn, ctx.class_id)) {
		if (reply.error_code == 0 && reply.data.len >= 4) {
			int sig_len = transport::get_int_be(reply.data, 0);
			if (sig_len > 0 && 4 + (usz)sig_len <= reply.data.len) {
				String sig = (String)reply.data[4:(usz)sig_len];
				// sig like "Lurskog/oppdrag/OppdragTest;" — extract "urskog/oppdrag"
				if (sig.len > 1 && sig[0] == 'L') {
					String inner = sig[1..sig.len - 2];  // strip L and ;
					// Find last '/' for package
					usz last_slash = 0;
					bool found_slash = false;
					for (usz i = 0; i < inner.len; i++) {
						if (inner[i] == '/') { last_slash = i; found_slash = true; }
					}
					if (found_slash) {
						pkg = inner[:last_slash];
					}
				}
			}
		}
	}

	// Try with package prefix first, then without
	long type_id = try_resolve_class(ctx.conn, pkg, name);
	if (type_id == 0) return eval_error("<not found>");

	// Check for Kotlin object INSTANCE field
	EvalValue instance = try_read_static_field(ctx, type_id, "INSTANCE");
	if (!instance.is_error && instance.raw != 0) {
		return instance;  // Return the singleton object
	}

	return eval_class_ref(type_id);
}

fn long try_resolve_class(JdwpConnection* conn, String pkg, String name) {
	// Try progressively shorter package prefixes:
	// e.g. urskog/oppdrag → try Lurskog/oppdrag/Name; then Lurskog/Name; then LName;
	String current_pkg = pkg;
	while (current_pkg.len > 0) {
		DString sig;
		sig.tinit();
		sig.appendf("L%s/%s;", current_pkg, name);
		long id = lookup_class_by_sig(conn, sig.str_view());
		if (id != 0) return id;

		// Also try $Companion
		DString comp_sig;
		comp_sig.tinit();
		comp_sig.appendf("L%s/%s$Companion;", current_pkg, name);
		long comp_id = lookup_class_by_sig(conn, comp_sig.str_view());
		if (comp_id != 0) return comp_id;

		// Strip last package segment
		bool found = false;
		usz last_slash = 0;
		for (usz i = 0; i < current_pkg.len; i++) {
			if (current_pkg[i] == '/') { last_slash = i; found = true; }
		}
		if (found) {
			current_pkg = current_pkg[:last_slash];
		} else {
			break;  // No more segments to strip
		}
	}

	// Try default package (no package prefix)
	DString sig;
	sig.tinit();
	sig.appendf("L%s;", name);
	long id = lookup_class_by_sig(conn, sig.str_view());
	if (id != 0) return id;

	return 0;
}

fn long lookup_class_by_sig(JdwpConnection* conn, String signature) {
	if (try reply = protocol::get_classes_by_signature(conn, signature)) {
		if (reply.error_code == 0 && reply.data.len >= 4) {
			int count = transport::get_int_be(reply.data, 0);
			if (count > 0 && reply.data.len >= 13) {
				// typeTag(1) + typeID(8) + status(4)
				long type_id = transport::get_long_be(reply.data, 5);
				return type_id;
			}
		}
	}
	return 0;
}

fn EvalValue try_read_static_field(EvalContext* ctx, long type_id, String field_name) {
	// Get fields of the class
	char[8] type_data;
	transport::put_long_be(type_data[..], 0, type_id);
	if (try fid = ctx.conn.send_command(protocol::CS_REFERENCE_TYPE, protocol::RT_FIELDS, type_data[:8])) {
		if (try freply = ctx.conn.read_reply()) {
			if (freply.error_code != 0 || freply.data.len < 4) return eval_error("<no fields>");

			int field_count = transport::get_int_be(freply.data, 0);
			usz fpos = 4;

			for (int fi = 0; fi < field_count; fi++) {
				if (fpos + 8 > freply.data.len) break;
				long fid_val = transport::get_long_be(freply.data, fpos); fpos += 8;

				if (fpos + 4 > freply.data.len) break;
				int name_len = transport::get_int_be(freply.data, fpos); fpos += 4;
				String fname = "";
				if (name_len > 0 && fpos + (usz)name_len <= freply.data.len) {
					fname = (String)freply.data[fpos:(usz)name_len];
				}
				fpos += (usz)name_len;

				// Skip signature + modBits
				if (fpos + 4 > freply.data.len) break;
				int sig_len = transport::get_int_be(freply.data, fpos); fpos += 4;
				fpos += (usz)sig_len;
				if (fpos + 4 > freply.data.len) break;
				int mod_bits = transport::get_int_be(freply.data, fpos);
				fpos += 4;

				if (fname == field_name && (mod_bits & 0x0008) != 0) {  // ACC_STATIC
					// Read static field value via ReferenceType.GetValues
					return read_static_field_value(ctx, type_id, fid_val);
				}
			}
		}
	}
	return eval_error("<field not found>");
}

fn EvalValue read_static_field_value(EvalContext* ctx, long type_id, long field_id) {
	char[20] data;
	transport::put_long_be(data[..], 0, type_id);
	transport::put_int_be(data[..], 8, 1);  // field count
	transport::put_long_be(data[..], 12, field_id);

	if (try id = ctx.conn.send_command(protocol::CS_REFERENCE_TYPE, protocol::RT_GET_VALUES, data[:20])) {
		if (try reply = ctx.conn.read_reply()) {
			if (reply.error_code == 0 && reply.data.len >= 5) {
				usz vpos = 4;  // skip count
				char tag = reply.data[vpos]; vpos++;
				return extract_eval_value(tag, reply.data, vpos);
			}
		}
	}
	return eval_error("<read error>");
}

fn EvalValue extract_eval_value(char tag, char[] data, usz offset) {
	switch (tag) {
		case 'I':
			if (offset + 4 <= data.len) return eval_int(transport::get_int_be(data, offset));
		case 'J':
			if (offset + 8 <= data.len) return eval_long(transport::get_long_be(data, offset));
		case 'D':
			if (offset + 8 <= data.len) return eval_double(transport::get_long_be(data, offset));
		case 'F':
			if (offset + 4 <= data.len) return eval_float(transport::get_int_be(data, offset));
		case 'Z':
			if (offset < data.len) return eval_bool(data[offset] != 0);
		case 'B':
			if (offset < data.len) return { .tag = 'B', .raw = (long)(ichar)data[offset] };
		case 'S':
			if (offset + 2 <= data.len) return { .tag = 'S', .raw = (long)(short)transport::get_ushort_be(data, offset) };
		case 'C':
			if (offset + 2 <= data.len) return { .tag = 'C', .raw = (long)transport::get_ushort_be(data, offset) };
		case 's':
			if (offset + 8 <= data.len) return eval_string_obj(transport::get_long_be(data, offset));
		case 'L':
			if (offset + 8 <= data.len) {
				long id = transport::get_long_be(data, offset);
				return id == 0 ? eval_null() : eval_object(id);
			}
		case '[':
			if (offset + 8 <= data.len) {
				long id = transport::get_long_be(data, offset);
				return id == 0 ? eval_null() : eval_array_obj(id);
			}
		default:
			// pass through
	}
	return eval_error("<cannot read value>");
}

fn EvalValue read_field_from_value(EvalContext* ctx, EvalValue* obj, String field_name) {
	if (obj.is_error) return *obj;

	// Class reference — read static field
	if (obj.tag == 'T') {
		long type_id = obj.raw;
		EvalValue result = try_read_static_field(ctx, type_id, field_name);
		if (!result.is_error) return result;
		// Try companion object: ClassName$Companion.INSTANCE.field
		// Get signature of this class, append $Companion
		if (try reply = protocol::get_reference_type_signature(ctx.conn, type_id)) {
			if (reply.error_code == 0 && reply.data.len >= 4) {
				int sig_len = transport::get_int_be(reply.data, 0);
				if (sig_len > 0 && 4 + (usz)sig_len <= reply.data.len) {
					String sig = (String)reply.data[4:(usz)sig_len];
					// sig = "Lcom/example/Foo;" → "Lcom/example/Foo$Companion;"
					if (sig.len > 1 && sig[sig.len - 1] == ';') {
						DString comp_sig;
						comp_sig.tinit();
						comp_sig.appendf("%s$Companion;", sig[:sig.len - 1]);
						long comp_id = lookup_class_by_sig(ctx.conn, comp_sig.str_view());
						if (comp_id != 0) {
							EvalValue instance = try_read_static_field(ctx, comp_id, "INSTANCE");
							if (!instance.is_error && instance.raw != 0) {
								return read_field_from_value(ctx, &instance, field_name);
							}
						}
					}
				}
			}
		}
		return eval_error("<static field not found>");
	}

	if (obj.tag != 'L' && obj.tag != 's' && obj.tag != '[') return eval_error("<not an object>");
	if (obj.raw == 0) return eval_error("<null pointer>");

	long object_id = obj.raw;

	// Get reference type
	char[8] ref_data;
	transport::put_long_be(ref_data[..], 0, object_id);
	if (try id = ctx.conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_REFERENCE_TYPE, ref_data[:8])) {
		if (try reply = ctx.conn.read_reply()) {
			if (reply.error_code != 0 || reply.data.len < 9) return eval_error("<type error>");
			long type_id = transport::get_long_be(reply.data, 1);

			// Get fields
			char[8] type_data;
			transport::put_long_be(type_data[..], 0, type_id);
			if (try fid = ctx.conn.send_command(protocol::CS_REFERENCE_TYPE, protocol::RT_FIELDS, type_data[:8])) {
				if (try freply = ctx.conn.read_reply()) {
					if (freply.error_code != 0 || freply.data.len < 4) return eval_error("<no fields>");

					int field_count = transport::get_int_be(freply.data, 0);
					usz fpos = 4;

					for (int fi = 0; fi < field_count; fi++) {
						if (fpos + 8 > freply.data.len) break;
						long fid_val = transport::get_long_be(freply.data, fpos); fpos += 8;

						if (fpos + 4 > freply.data.len) break;
						int name_len = transport::get_int_be(freply.data, fpos); fpos += 4;
						String fname = "";
						if (name_len > 0 && fpos + (usz)name_len <= freply.data.len) {
							fname = (String)freply.data[fpos:(usz)name_len];
						}
						fpos += (usz)name_len;

					// Skip signature, read modBits
					if (fpos + 4 > freply.data.len) break;
					int sig_len = transport::get_int_be(freply.data, fpos); fpos += 4;
					fpos += (usz)sig_len;
					if (fpos + 4 > freply.data.len) break;
					int mod_bits = transport::get_int_be(freply.data, fpos);
					fpos += 4;

					if (fname == field_name) {
						// Static fields must use ReferenceType.GetValues, not ObjectReference.GetValues
						if ((mod_bits & 0x0008) != 0) {
							return read_static_field_value(ctx, type_id, fid_val);
						}
						return read_field_value_raw(ctx, object_id, fid_val);
					}
					}
				}
			}
		}
	}
	return eval_error("<field not found>");
}

fn EvalValue read_field_value_raw(EvalContext* ctx, long object_id, long field_id) {
	char[20] data;
	transport::put_long_be(data[..], 0, object_id);
	transport::put_int_be(data[..], 8, 1);
	transport::put_long_be(data[..], 12, field_id);

	if (try id = ctx.conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_GET_VALUES, data[:20])) {
		if (try reply = ctx.conn.read_reply()) {
			if (reply.error_code == 0 && reply.data.len >= 5) {
				usz vpos = 4;
				char tag = reply.data[vpos]; vpos++;
				return extract_eval_value(tag, reply.data, vpos);
			}
		}
	}
	return eval_error("<read error>");
}

fn EvalValue read_array_element(EvalContext* ctx, EvalValue* arr, EvalValue* idx) {
	if (arr.is_error) return *arr;
	if (arr.tag != '[') return eval_error("<not an array>");
	if (arr.raw == 0) return eval_error("<null array>");
	if (!idx.is_numeric()) return eval_error("<index not numeric>");

	int index = idx.to_int();
	if (try reply = protocol::get_array_values(ctx.conn, arr.raw, index, 1)) {
		if (reply.error_code != 0 || reply.data.len < 5) return eval_error("<array read error>");
		// ArrayRegion: tag(1) + length(4) + values
		char tag = reply.data[0];
		// int arr_len = transport::get_int_be(reply.data, 1);
		usz vpos = 5;
		// For primitive arrays, values are untagged. For object arrays, each has a tag.
		if (tag == 'L' || tag == '[' || tag == 's') {
			// Object array: each element is tagged-objectID
			if (vpos < reply.data.len) {
				char elem_tag = reply.data[vpos]; vpos++;
				return extract_eval_value(elem_tag, reply.data, vpos);
			}
		} else {
			// Primitive array: values are raw
			return extract_eval_value(tag, reply.data, vpos);
		}
	}
	return eval_error("<array error>");
}

fn EvalValue create_vm_string(EvalContext* ctx, String content) {
	if (try reply = protocol::create_string(ctx.conn, content)) {
		if (reply.error_code == 0 && reply.data.len >= 8) {
			long str_id = transport::get_long_be(reply.data, 0);
			return eval_string_obj(str_id);
		}
	}
	return eval_error("<cannot create string>");
}

fn EvalValue string_concat(EvalContext* ctx, EvalValue* left, EvalValue* right) {
	// Read both sides as strings, concatenate, create new VM string
	String l_str = eval_value_to_string(ctx, left);
	String r_str = eval_value_to_string(ctx, right);

	DString result;
	result.tinit();
	result.appendf("%s%s", l_str, r_str);
	return create_vm_string(ctx, result.str_view());
}

fn String eval_value_to_string(EvalContext* ctx, EvalValue* val) {
	if (val.is_error) return val.error_msg;
	switch (val.tag) {
		case 'I': case 'B': case 'S': case 'C':
			DString s; s.tinit();
			s.appendf("%d", val.to_int());
			return s.str_view();
		case 'J':
			DString s; s.tinit();
			s.appendf("%d", val.to_long());
			return s.str_view();
		case 'Z':
			return val.raw != 0 ? "true" : "false";
		case 'D':
			DString s; s.tinit();
			s.appendf("%g", val.to_double());
			return s.str_view();
		case 'F':
			DString s; s.tinit();
			int fbits = (int)val.raw;
			float fv = *((float*)&fbits);
			s.appendf("%g", fv);
			return s.str_view();
		case 's':
			if (val.raw == 0) return "null";
			if (try reply = protocol::get_string_value(ctx.conn, val.raw)) {
				if (reply.error_code == 0 && reply.data.len >= 4) {
					int len = transport::get_int_be(reply.data, 0);
					if (len > 0 && 4 + (usz)len <= reply.data.len) {
						return (String)reply.data[4:(usz)len];
					}
				}
			}
			return "<string?>";
		case 'L':
			return val.raw == 0 ? "null" : "Object";
		case '[':
			return val.raw == 0 ? "null" : "Array";
		case 'T':
			return "<class>";
		default:
			return "?";
	}
}

// ── Method signature helpers ────────────────────────────────────────

const int ACC_SYNTHETIC = 0x1000;
const int ACC_BRIDGE = 0x0040;

// Count parameters in a JVM method signature like "(II)V" → 2, "(Ljava/lang/String;I)V" → 2
fn int count_sig_params(String sig) {
	if (sig.len < 2 || sig[0] != '(') return -1;
	int count = 0;
	usz i = 1;
	while (i < sig.len && sig[i] != ')') {
		switch (sig[i]) {
			case 'B': case 'C': case 'D': case 'F':
			case 'I': case 'J': case 'S': case 'Z':
				count++;
				i++;
			case 'L':
				count++;
				// Skip to ';'
				while (i < sig.len && sig[i] != ';') i++;
				if (i < sig.len) i++;  // skip ';'
			case '[':
				// Array — skip dimensions, then the element type
				while (i < sig.len && sig[i] == '[') i++;
				if (i < sig.len && sig[i] == 'L') {
					while (i < sig.len && sig[i] != ';') i++;
					if (i < sig.len) i++;
				} else if (i < sig.len) {
					i++;  // primitive element
				}
				count++;
			default:
				i++;  // skip unknown
		}
	}
	return count;
}

// Find best matching method by name, arg count, skipping synthetic/bridge.
// Returns method ID or 0 if not found.
fn long find_method(JdwpConnection* conn, long type_id, String method_name, int wanted_args) {
	JdwpReply methods_reply;
	if (try r = protocol::get_methods(conn, type_id)) {
		methods_reply = r;
	} else {
		return 0;
	}
	if (methods_reply.error_code != 0 || methods_reply.data.len < 4) return 0;

	int method_count = transport::get_int_be(methods_reply.data, 0);
	usz mpos = 4;

	long exact_match = 0;     // name + arg count match, non-synthetic
	long name_match = 0;      // name match, non-synthetic (any arg count)
	long fallback_match = 0;  // name match including synthetic

	for (int mi = 0; mi < method_count; mi++) {
		if (mpos + 8 > methods_reply.data.len) break;
		long mid = transport::get_long_be(methods_reply.data, mpos); mpos += 8;

		if (mpos + 4 > methods_reply.data.len) break;
		int mname_len = transport::get_int_be(methods_reply.data, mpos); mpos += 4;
		String mname = "";
		if (mname_len > 0 && mpos + (usz)mname_len <= methods_reply.data.len) {
			mname = (String)methods_reply.data[mpos:(usz)mname_len];
		}
		mpos += (usz)mname_len;

		if (mpos + 4 > methods_reply.data.len) break;
		int sig_len = transport::get_int_be(methods_reply.data, mpos); mpos += 4;
		String sig = "";
		if (sig_len > 0 && mpos + (usz)sig_len <= methods_reply.data.len) {
			sig = (String)methods_reply.data[mpos:(usz)sig_len];
		}
		mpos += (usz)sig_len;

		if (mpos + 4 > methods_reply.data.len) break;
		int mod_bits = transport::get_int_be(methods_reply.data, mpos); mpos += 4;

		if (mname != method_name) continue;

		bool is_synthetic = (mod_bits & ACC_SYNTHETIC) != 0 || (mod_bits & ACC_BRIDGE) != 0;
		int param_count = count_sig_params(sig);

		if (!is_synthetic) {
			if (param_count == wanted_args && exact_match == 0) {
				exact_match = mid;
			}
			if (name_match == 0) {
				name_match = mid;
			}
		}
		if (fallback_match == 0) {
			fallback_match = mid;
		}
	}

	// Prefer: exact arg match > any non-synthetic > any match
	if (exact_match != 0) return exact_match;
	if (name_match != 0) return name_match;
	return fallback_match;
}

// ── Method invocation ───────────────────────────────────────────────

fn EvalValue invoke_method_on_value(EvalContext* ctx, EvalValue* obj, String method_name, EvalValue[] args) {
	if (obj.is_error) return *obj;

	// Class reference — invoke static method
	if (obj.tag == 'T') {
		return invoke_static_method_on_class(ctx, obj.raw, method_name, args);
	}

	if (obj.tag != 'L' && obj.tag != 's' && obj.tag != '[') return eval_error("<not an object>");
	if (obj.raw == 0) return eval_error("<null pointer>");

	ctx.resolve_frame();
	long object_id = obj.raw;

	// Get reference type
	char[8] ref_data;
	transport::put_long_be(ref_data[..], 0, object_id);
	long type_id = 0;
	if (try id = ctx.conn.send_command(protocol::CS_OBJECT_REFERENCE, protocol::OR_REFERENCE_TYPE, ref_data[:8])) {
		if (try reply = ctx.conn.read_reply()) {
			if (reply.error_code == 0 && reply.data.len >= 9) {
				type_id = transport::get_long_be(reply.data, 1);
			}
		}
	}
	if (type_id == 0) return eval_error("<cannot get type>");

	// Find method by name + arg count, skipping synthetic/bridge methods
	long target_method_id = find_method(ctx.conn, type_id, method_name, (int)args.len);
	if (target_method_id == 0) return eval_error("<method not found>");

	// Build argument arrays
	char[8] arg_tags;
	long[8] arg_values;
	int arg_count = (int)args.len;
	if (arg_count > 8) arg_count = 8;
	for (int i = 0; i < arg_count; i++) {
		arg_tags[i] = args[i].tag;
		arg_values[i] = args[i].raw;
	}

	// Invoke: resume all threads (options=0) for safety — complex methods may need
	// other threads for classloading, locks, JNI, etc.
	if (try reply = protocol::invoke_object_method(ctx.conn, object_id, ctx.thread_id, type_id, target_method_id, arg_tags[:arg_count], arg_values[:arg_count], 0x00)) {
		if (reply.error_code != 0) return eval_error("<invoke error>");
		// Reply: returnValue(tagged) + exception(tagged-objectID)
		if (reply.data.len >= 1) {
			char ret_tag = reply.data[0];
			int ret_size = variables::tag_value_size(ret_tag);
			if (1 + (usz)ret_size <= reply.data.len) {
				EvalValue result = extract_eval_value(ret_tag, reply.data, 1);
				// Check exception: after return value
				usz exc_pos = 1 + (usz)ret_size;
				if (exc_pos + 9 <= reply.data.len) {
					char exc_tag = reply.data[exc_pos];
					long exc_id = transport::get_long_be(reply.data, exc_pos + 1);
					if (exc_id != 0) {
						return eval_error("<exception thrown>");
					}
				}
				return result;
			}
		}
	}
	return eval_error("<invoke failed>");
}

fn EvalValue invoke_static_method_on_class(EvalContext* ctx, long type_id, String method_name, EvalValue[] args) {
	ctx.resolve_frame();

	// Find method by name + arg count, skipping synthetic/bridge methods
	long target_method_id = find_method(ctx.conn, type_id, method_name, (int)args.len);
	if (target_method_id == 0) return eval_error("<method not found>");

	char[8] arg_tags;
	long[8] arg_values;
	int arg_count = (int)args.len;
	if (arg_count > 8) arg_count = 8;
	for (int i = 0; i < arg_count; i++) {
		arg_tags[i] = args[i].tag;
		arg_values[i] = args[i].raw;
	}

	// Invoke: resume all threads (options=0)
	if (try reply = protocol::invoke_static_method(ctx.conn, type_id, ctx.thread_id, target_method_id, arg_tags[:arg_count], arg_values[:arg_count], 0x00)) {
		if (reply.error_code != 0) return eval_error("<invoke error>");
		if (reply.data.len >= 1) {
			char ret_tag = reply.data[0];
			int ret_size = variables::tag_value_size(ret_tag);
			if (1 + (usz)ret_size <= reply.data.len) {
				EvalValue result = extract_eval_value(ret_tag, reply.data, 1);
				usz exc_pos = 1 + (usz)ret_size;
				if (exc_pos + 9 <= reply.data.len) {
					long exc_id = transport::get_long_be(reply.data, exc_pos + 1);
					if (exc_id != 0) return eval_error("<exception thrown>");
				}
				return result;
			}
		}
	}
	return eval_error("<static invoke failed>");
}

// ── Format EvalValue for DAP display ────────────────────────────────

fn String format_eval_value(EvalContext* ctx, EvalValue* val) {
	if (val.is_error) return val.error_msg;
	return eval_value_to_string(ctx, val);
}

// ── Public API: Handle evaluate request ─────────────────────────────

fn Object* handle_evaluate(JdwpConnection* conn, IdManager* id_mgr, Object* args) {
	Object* body = object::new_obj(tmem);

	String expression = args.get_string("expression") ?? "";
	int frame_id = (int)(args.get_int("frameId") ?? 0);

	if (expression.len == 0) {
		body.set("result", "");
		body.set("variablesReference", 0);
		return body;
	}

	// Tokenize and parse expression
	ExprLexer lexer;
	lexer.init(expression);
	lexer.tokenize();

	EvalContext ctx = {
		.conn = conn,
		.id_mgr = id_mgr,
		.dap_frame_id = frame_id,
	};

	ExprParser parser = {
		.tokens = &lexer.tokens[0],
		.count = lexer.count,
		.pos = 0,
		.ctx = &ctx,
	};

	EvalValue result = parser.parse_expression();

	// Format result
	String result_str = format_eval_value(&ctx, &result);
	body.set("result", result_str);

	// If result is an object, register variablesReference for expansion
	int var_ref = 0;
	if (!result.is_error && (result.tag == 'L' || result.tag == '[' || result.tag == 's') && result.raw != 0) {
		ctx.resolve_frame();
		VarRef vr;
		vr.thread_id = ctx.thread_id;
		vr.frame_id = ctx.frame_id;
		vr.scope = ScopeKind.THIS_OBJECT;
		vr.object_id = result.raw;
		var_ref = id_mgr.register_var_ref(vr);
	}
	body.set("variablesReference", var_ref);
	return body;
}

// ── Evaluate condition for conditional breakpoints ──────────────────

// Evaluate a condition expression in the context of a suspended thread/frame.
// Returns true if condition is truthy (breakpoint should stop).
// Returns true on error (fail-safe: stop on evaluation errors).
fn bool evaluate_condition(JdwpConnection* conn, IdManager* id_mgr, long thread_id, String condition) {
	if (condition.len == 0) return true;

	// We need a frame to evaluate in — get top frame
	int dap_frame_id = 0;
	if (try reply = protocol::get_thread_frames(conn, thread_id, 0, 1)) {
		if (reply.error_code == 0 && reply.data.len >= 12) {
			int frame_count = transport::get_int_be(reply.data, 0);
			if (frame_count > 0) {
				// frame: frameID(8) + location(1+8+8+8)
				long jdwp_frame_id = transport::get_long_be(reply.data, 4);
				// Read location to get class_id + method_id
				usz loc_pos = 12;
				char type_tag = reply.data[loc_pos]; loc_pos++;
				long class_id = transport::get_long_be(reply.data, loc_pos); loc_pos += 8;
				long method_id = transport::get_long_be(reply.data, loc_pos);

				FrameRef fref;
				fref.thread_id = thread_id;
				fref.frame_id = jdwp_frame_id;
				fref.class_id = class_id;
				fref.method_id = method_id;
				dap_frame_id = id_mgr.register_frame(fref);
			}
		}
	}

	ExprLexer lexer;
	lexer.init(condition);
	lexer.tokenize();

	EvalContext ctx = {
		.conn = conn,
		.id_mgr = id_mgr,
		.dap_frame_id = dap_frame_id,
	};

	ExprParser parser = {
		.tokens = &lexer.tokens[0],
		.count = lexer.count,
		.pos = 0,
		.ctx = &ctx,
	};

	EvalValue result = parser.parse_expression();

	if (result.is_error) {
		log::err("[dap] Condition eval error: %s (expr=%s)", result.error_msg, condition);
		return true;  // fail-safe: stop on error
	}

	return result.is_truthy();
}

// ── Evaluate expression to string (for logpoints) ──────────────────

// Evaluate an expression and return its string representation.
// Returns "<error>" on evaluation failure.
fn String evaluate_to_string(JdwpConnection* conn, IdManager* id_mgr, long thread_id, String expression) {
	if (expression.len == 0) return "";

	// Get top frame
	int dap_frame_id = 0;
	if (try reply = protocol::get_thread_frames(conn, thread_id, 0, 1)) {
		if (reply.error_code == 0 && reply.data.len >= 12) {
			int frame_count = transport::get_int_be(reply.data, 0);
			if (frame_count > 0) {
				long jdwp_frame_id = transport::get_long_be(reply.data, 4);
				usz loc_pos = 12;
				char type_tag = reply.data[loc_pos]; loc_pos++;
				long class_id = transport::get_long_be(reply.data, loc_pos); loc_pos += 8;
				long method_id = transport::get_long_be(reply.data, loc_pos);

				FrameRef fref;
				fref.thread_id = thread_id;
				fref.frame_id = jdwp_frame_id;
				fref.class_id = class_id;
				fref.method_id = method_id;
				dap_frame_id = id_mgr.register_frame(fref);
			}
		}
	}

	ExprLexer lexer;
	lexer.init(expression);
	lexer.tokenize();

	EvalContext ctx = {
		.conn = conn,
		.id_mgr = id_mgr,
		.dap_frame_id = dap_frame_id,
	};

	ExprParser parser = {
		.tokens = &lexer.tokens[0],
		.count = lexer.count,
		.pos = 0,
		.ctx = &ctx,
	};

	EvalValue result = parser.parse_expression();

	if (result.is_error) {
		log::err("[dap] Logpoint eval error: %s (expr=%s)", result.error_msg, expression);
		return "<error>";
	}

	return format_eval_value(&ctx, &result);
}
