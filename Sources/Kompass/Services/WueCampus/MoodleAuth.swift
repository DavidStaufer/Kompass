import Foundation
import AuthenticationServices
import CryptoKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Anmeldung bei WueCampus über den Uni-Login (Shibboleth) – wie bei der Moodle-App.
/// Das Passwort wird nur auf der Uni-Seite eingegeben; Kompass erhält einen Zugangsschlüssel (Token).
@MainActor
final class MoodleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    struct AuthError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func login(site: URL) async throws -> String {
        let passport = String(Double.random(in: 1...10_000_000))
        var comps = URLComponents(url: site.appendingPathComponent("admin/tool/mobile/launch.php"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "service", value: "moodle_mobile_app"),
            URLQueryItem(name: "passport", value: passport),
            URLQueryItem(name: "urlscheme", value: "moodlemobile")
        ]
        guard let url = comps.url else { throw AuthError(message: "Ungültige WueCampus-Adresse.") }

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "moodlemobile") { url, error in
                if let url { cont.resume(returning: url) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: AuthError(message: "Anmeldung abgebrochen."))
                } else {
                    cont.resume(throwing: error ?? AuthError(message: "Anmeldung fehlgeschlagen."))
                }
            }
            s.presentationContextProvider = self
            // Gemeinsame Browser-Cookies: Wer im Browser schon beim Uni-Login ist, muss sich nicht erneut anmelden.
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { cont.resume(throwing: AuthError(message: "Das Anmeldefenster konnte nicht geöffnet werden.")) }
        }
        return try Self.parseToken(callback: callback, site: site, passport: passport)
    }

    /// moodlemobile://token=BASE64(signatur:::token[:::privatetoken])
    static func parseToken(callback: URL, site: URL, passport: String?) throws -> String {
        let s = callback.absoluteString
        guard let range = s.range(of: "token=") else { throw AuthError(message: "WueCampus hat keinen Zugangsschlüssel geliefert.") }
        var b64 = String(s[range.upperBound...]).removingPercentEncoding ?? ""
        b64 = b64.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let decoded = String(data: data, encoding: .utf8) else {
            throw AuthError(message: "Der Zugangsschlüssel von WueCampus ist unlesbar.")
        }
        let parts = decoded.components(separatedBy: ":::")
        guard parts.count >= 2, !parts[1].isEmpty else { throw AuthError(message: "Der Zugangsschlüssel von WueCampus ist unvollständig.") }
        if let passport {
            // Signatur = md5(Seiten-URL + passport) – schützt vor untergeschobenen Schlüsseln
            let candidates = [site.absoluteString, site.absoluteString.hasSuffix("/") ? String(site.absoluteString.dropLast()) : site.absoluteString + "/"]
            let ok = candidates.contains { md5($0 + passport) == parts[0] }
            if !ok { throw AuthError(message: "Der Zugangsschlüssel konnte nicht überprüft werden.") }
        }
        return parts[1]
    }

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #endif
        }
    }
}
