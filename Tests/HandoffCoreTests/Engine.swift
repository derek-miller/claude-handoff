import Testing

// The engine behaviour suite. Tests run one at a time because the engine's fs, clock, process and fetch
// tables are process-wide; Sandboxed gives each test fresh tables and a temporary HOME.
@Suite(.serialized, Sandboxed())
enum Engine {}
