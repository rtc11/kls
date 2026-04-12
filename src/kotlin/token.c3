module kls::kotlin::token;

enum TokenKind : int {
	// Special
	EOF,
	ERROR,
	WHITESPACE,
	NEWLINE,
	LINE_COMMENT,
	BLOCK_COMMENT,

	// Literals
	INTEGER_LITERAL,
	FLOAT_LITERAL,
	CHARACTER_LITERAL,
	STRING_OPEN,
	STRING_CLOSE,
	STRING_CONTENT,
	STRING_TEMPLATE_REF,   // $identifier
	STRING_TEMPLATE_START, // ${
	MULTILINE_STRING_OPEN,
	MULTILINE_STRING_CLOSE,
	BOOLEAN_LITERAL,
	NULL_LITERAL,

	// Identifiers
	IDENTIFIER,

	// Hard Keywords
	KW_PACKAGE,
	KW_IMPORT,
	KW_CLASS,
	KW_INTERFACE,
	KW_FUN,
	KW_OBJECT,
	KW_VAL,
	KW_VAR,
	KW_TYPEALIAS,
	KW_CONSTRUCTOR,
	KW_BY,
	KW_COMPANION,
	KW_INIT,
	KW_THIS,
	KW_SUPER,
	KW_TYPEOF,
	KW_WHERE,
	KW_IF,
	KW_ELSE,
	KW_WHEN,
	KW_TRY,
	KW_CATCH,
	KW_FINALLY,
	KW_FOR,
	KW_DO,
	KW_WHILE,
	KW_THROW,
	KW_RETURN,
	KW_CONTINUE,
	KW_BREAK,
	KW_AS,
	KW_IS,
	KW_IN,
	KW_OUT,
	KW_DYNAMIC,

	// Soft Keywords (context-dependent)
	KW_ABSTRACT,
	KW_ANNOTATION,
	KW_DATA,
	KW_ENUM,
	KW_EXTERNAL,
	KW_FINAL,
	KW_INFIX,
	KW_INLINE,
	KW_INNER,
	KW_INTERNAL,
	KW_LATEINIT,
	KW_NOINLINE,
	KW_OPEN,
	KW_OPERATOR,
	KW_OVERRIDE,
	KW_PRIVATE,
	KW_PROTECTED,
	KW_PUBLIC,
	KW_REIFIED,
	KW_SEALED,
	KW_SUSPEND,
	KW_TAILREC,
	KW_VARARG,
	KW_CROSSINLINE,
	KW_CONST,
	KW_EXPECT,
	KW_ACTUAL,
	KW_VALUE,

	// Soft keywords (property/accessor)
	KW_GET,
	KW_SET,
	KW_FIELD,
	KW_PROPERTY,
	KW_RECEIVER,
	KW_PARAM,
	KW_SETPARAM,
	KW_DELEGATE,
	KW_FILE,

	// Operators
	DOT,           // .
	COMMA,         // ,
	LPAREN,        // (
	RPAREN,        // )
	LSQUARE,       // [
	RSQUARE,       // ]
	LCURL,         // {
	RCURL,         // }
	MULT,          // *
	MOD,           // %
	DIV,           // /
	ADD,           // +
	SUB,           // -
	INCR,          // ++
	DECR,          // --
	CONJ,          // &&
	DISJ,          // ||
	EXCL,          // !
	COLON,         // :
	SEMICOLON,     // ;
	ASSIGNMENT,    // =
	ADD_ASSIGN,    // +=
	SUB_ASSIGN,    // -=
	MULT_ASSIGN,   // *=
	DIV_ASSIGN,    // /=
	MOD_ASSIGN,    // %=
	ARROW,         // ->
	DOUBLE_ARROW,  // =>
	RANGE,         // ..
	COLONCOLON,    // ::
	HASH,          // #
	AT,            // @
	QUEST,         // ?
	SAFE_CALL,     // ?.
	ELVIS,         // ?:
	NOT_NULL,      // !!
	LANGLE,        // <
	RANGLE,        // >
	LE,            // <=
	GE,            // >=
	EXCL_EQ,       // !=
	EXCL_EQEQ,    // !==
	EQEQ,         // ==
	EQEQEQ,       // ===
	AS_SAFE,       // as?
	NOT_IS,        // !is
	NOT_IN,        // !in
}

struct Token {
	TokenKind kind;
	String text;
	uint line;
	uint col;
	uint offset;
	uint len;
}

struct TokenSpan {
	uint start;
	uint end;
}
