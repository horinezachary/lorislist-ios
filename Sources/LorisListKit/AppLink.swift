import Foundation

/// A link from one of the site's emails that the app can handle itself.
///
/// The emails link to the website: `/share/<key>` for an invitation and
/// `/passwordReset/<token>` for a password reset. When the app is installed and the site vouches
/// for it (see the server's `appLinks` setting), iOS opens those links here instead of Safari.
public enum AppLink: Equatable, Hashable, Identifiable, Sendable {
    case invitation(key: String)
    case passwordReset(token: String)

    public var id: String {
        switch self {
        case .invitation(let key): return "invitation-\(key)"
        case .passwordReset(let token): return "reset-\(token)"
        }
    }

    /// Reads a link, or returns nil for anything else (other sites, other pages, odd shapes).
    /// `siteHosts` are the hosts that count as Lori's List, such as `lorislist.horinetech.com`.
    public static func parse(_ url: URL, siteHosts: Set<String>) -> AppLink? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              siteHosts.contains(host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, isToken(parts[1]) else { return nil }
        switch parts[0] {
        case "share": return .invitation(key: parts[1])
        case "passwordReset": return .passwordReset(token: parts[1])
        default: return nil
        }
    }

    /// The hosts to accept, taken from the API address (`https://host/api/v1`).
    public static func siteHosts(forAPI baseURL: URL) -> Set<String> {
        guard let host = baseURL.host?.lowercased() else { return [] }
        return [host]
    }

    /// The server makes these from 16 random bytes (32 hex digits). Anything that is not plain
    /// letters, digits, "-" or "_" is not one of ours.
    static func isToken(_ text: String) -> Bool {
        guard (8...128).contains(text.count) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))) || scalar == "-" || scalar == "_"
        }
    }
}
