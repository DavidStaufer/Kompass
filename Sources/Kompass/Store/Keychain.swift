import Foundation
import Security

/// Speichert Zugangsdaten (DeepSeek-Key, WueCampus-Zugang) im Schlüsselbund statt im Klartext.
enum Keychain {
    private static let service = "de.staufer.kompass"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for account: String, label: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = label
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum Secrets {
    static let deepSeekAccount = "deepseek-api-key"
    private static var cached: String??

    /// DeepSeek ist während der Entwicklung aus: kein Schlüsselbund-Zugriff, keine API-Kosten –
    /// Lernmaterial erstellt Claude. Einschalten: Einstellungen → KI.
    static let deepSeekEnabledKey = "kompass.deepSeekEnabled"
    static var deepSeekEnabled: Bool { Paths.isDemo || UserDefaults.standard.bool(forKey: deepSeekEnabledKey) }

    static var deepSeekKey: String? {
        get {
            if Paths.isDemo { return UserDefaults.standard.string(forKey: "kompass.demoKey") }
            guard deepSeekEnabled else { return nil }
            if let c = cached { return c }
            let v = Keychain.get(deepSeekAccount)
            cached = .some(v)
            return v
        }
        set {
            guard !Paths.isDemo else { return }
            let v = newValue?.trimmed
            Keychain.set(v, for: deepSeekAccount, label: "Kompass – DeepSeek API-Key")
            cached = .some(v?.nilIfEmpty)
        }
    }

    static var hasDeepSeekKey: Bool { !(deepSeekKey ?? "").trimmed.isEmpty }
}
