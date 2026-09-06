import Foundation

@main
struct VerifyTouchBarSource {
    static func main() {
        for source in [TouchBarSource.codex, .openCodeGo] {
            assert(source.available(codex: true, go: true) == source)
            assert(source.available(codex: true, go: false) == .codex)
            assert(source.available(codex: false, go: true) == .openCodeGo)
            assert(source.available(codex: false, go: false) == nil)
        }
        assert(TouchBarSource(rawValue: "codex") == .codex)
        assert(TouchBarSource(rawValue: "openCodeGo") == .openCodeGo)
        assert(TouchBarSource(rawValue: "bogus") == nil)
        print("OK: source availability and fallback")
    }
}
