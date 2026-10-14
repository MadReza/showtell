import Foundation

/// The language you dictate in. English runs on Parakeet with your words boosted; French runs on
/// Apple's on-device recogniser (macOS 26).
///
/// One French: Apple's France and Québec recognisers wrote the same words on every test clip,
/// Québec phrasing included, so a second choice would change nothing.
public enum DictationLanguage: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case french = "fr"

    /// In Settings, menus and the bar.
    public var name: String {
        switch self {
        case .english: return "English"
        case .french: return "Français"
        }
    }

    /// The locale the recogniser is given (BCP 47).
    public var localeIdentifier: String {
        switch self {
        case .english: return "en-US"
        case .french: return "fr-CA"
        }
    }

    /// How far the live transcript trails the audio: Parakeet streaming 2.08 s; Apple's recogniser
    /// with fast results sends a guess about once a second.
    public var transcriptLag: Double { isEnglish ? 2.1 : 1.0 }

    public var isEnglish: Bool { self == .english }
    public var isFrench: Bool { self == .french }

    /// The next (`step` 1) or previous (-1) language, wrapping around.
    public func moved(by step: Int) -> DictationLanguage {
        let all = Self.allCases
        let i = all.firstIndex(of: self)!
        return all[((i + step) % all.count + all.count) % all.count]
    }
}
