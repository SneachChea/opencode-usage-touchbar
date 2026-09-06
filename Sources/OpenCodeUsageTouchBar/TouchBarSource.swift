import Foundation

enum TouchBarSource: String {
    case codex
    case openCodeGo

    func available(codex: Bool, go: Bool) -> TouchBarSource? {
        switch (codex, go) {
        case (true, true): return self
        case (true, false): return .codex
        case (false, true): return .openCodeGo
        case (false, false): return nil
        }
    }
}
