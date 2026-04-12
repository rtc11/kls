module kls::lsp::types;

struct Position {
	uint line;
	uint character;
}

struct Range {
	Position start;
	Position end;
}

struct Location {
	String uri;
	Range range;
}

struct TextDocumentIdentifier {
	String uri;
}

struct VersionedTextDocumentIdentifier {
	String uri;
	int version;
}

struct TextDocumentItem {
	String uri;
	String language_id;
	int version;
	String text;
}

// DiagnosticSeverity: ordinals 0..3, LSP values are ordinal + 1
enum DiagnosticSeverity : int (int lsp_value) {
	ERROR       { 1 },
	WARNING     { 2 },
	INFORMATION { 3 },
	HINT        { 4 },
}

struct Diagnostic {
	Range range;
	DiagnosticSeverity severity;
	String source;
	String message;
}

// TextDocumentSyncKind
const int SYNC_NONE = 0;
const int SYNC_FULL = 1;
const int SYNC_INCREMENTAL = 2;
