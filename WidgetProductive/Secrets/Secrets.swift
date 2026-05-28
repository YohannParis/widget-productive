import Foundation
import Security

// MARK: - Secrets

/// Build-config switch: DEBUG reads `.env`; RELEASE uses Keychain + UserDefaults.
enum Secrets {

    // MARK: Keys

    enum Key: String {
        case authToken            = "PRODUCTIVE_AUTH_TOKEN"
        case orgID                = "PRODUCTIVE_ORG_ID"
        case email                = "PRODUCTIVE_EMAIL"
        case personID             = "PRODUCTIVE_PERSON_ID"
        case defaultServiceID     = "PRODUCTIVE_DEFAULT_SERVICE_ID"
        case defaultServiceLabel  = "PRODUCTIVE_DEFAULT_SERVICE_LABEL"
        case careDayEventID       = "PRODUCTIVE_CARE_DAY_EVENT_ID"
        case vacationEventID      = "PRODUCTIVE_VACATION_EVENT_ID"
        case attendanceEmail      = "ATTENDANCE_EMAIL"
    }

    // MARK: Public API

    static func authToken() throws -> String {
#if DEBUG
        try dotenv(key: .authToken)
#else
        try keychain(key: .authToken)
#endif
    }

    static func orgID() throws -> String {
#if DEBUG
        try dotenv(key: .orgID)
#else
        try userDefaults(key: .orgID)
#endif
    }

    static func email() throws -> String {
#if DEBUG
        try dotenv(key: .email)
#else
        try userDefaults(key: .email)
#endif
    }

    static func personID() throws -> String? {
#if DEBUG
        try? dotenv(key: .personID)
#else
        UserDefaults.standard.string(forKey: Key.personID.rawValue)
#endif
    }

    static func defaultServiceID() throws -> String? {
#if DEBUG
        try? dotenv(key: .defaultServiceID)
#else
        UserDefaults.standard.string(forKey: Key.defaultServiceID.rawValue)
#endif
    }

    static func defaultServiceLabel() -> String? {
#if DEBUG
        try? dotenv(key: .defaultServiceLabel)
#else
        UserDefaults.standard.string(forKey: Key.defaultServiceLabel.rawValue)
#endif
    }

    static func careDayEventID() throws -> String? {
#if DEBUG
        try? dotenv(key: .careDayEventID)
#else
        UserDefaults.standard.string(forKey: Key.careDayEventID.rawValue)
#endif
    }

    static func vacationEventID() throws -> String? {
#if DEBUG
        try? dotenv(key: .vacationEventID)
#else
        UserDefaults.standard.string(forKey: Key.vacationEventID.rawValue)
#endif
    }

    static func attendanceEmail() -> String? {
#if DEBUG
        try? dotenv(key: .attendanceEmail)
#else
        UserDefaults.standard.string(forKey: Key.attendanceEmail.rawValue)
#endif
    }

    // MARK: RELEASE: Keychain

    static func storeAuthToken(_ token: String) throws {
        try keychainStore(key: .authToken, value: token)
    }

    static func deleteAuthToken() throws {
        try keychainDelete(key: .authToken)
    }

    // MARK: RELEASE: UserDefaults (non-secrets)

    static func store(orgID: String)              { UserDefaults.standard.set(orgID, forKey: Key.orgID.rawValue) }
    static func store(email: String)              { UserDefaults.standard.set(email, forKey: Key.email.rawValue) }
    static func store(personID: String)           { UserDefaults.standard.set(personID, forKey: Key.personID.rawValue) }
    static func store(defaultServiceID: String)   { UserDefaults.standard.set(defaultServiceID, forKey: Key.defaultServiceID.rawValue) }
    static func store(defaultServiceLabel: String){ UserDefaults.standard.set(defaultServiceLabel, forKey: Key.defaultServiceLabel.rawValue) }
    static func store(careDayEventID: String)     { UserDefaults.standard.set(careDayEventID, forKey: Key.careDayEventID.rawValue) }
    static func store(vacationEventID: String)    { UserDefaults.standard.set(vacationEventID, forKey: Key.vacationEventID.rawValue) }
    static func store(attendanceEmail: String)    { UserDefaults.standard.set(attendanceEmail, forKey: Key.attendanceEmail.rawValue) }
}

// MARK: - Errors

extension Secrets {
    enum SecretsError: Error, LocalizedError {
        case missingKey(String)
        case keychainError(OSStatus)
        case keychainDataCorrupt

        var errorDescription: String? {
            switch self {
            case .missingKey(let k): ".env is missing key: \(k)"
            case .keychainError(let s): "Keychain error: \(s)"
            case .keychainDataCorrupt: "Keychain value is not valid UTF-8"
            }
        }
    }
}

// MARK: - Private helpers

private extension Secrets {
    // nonisolated(unsafe): .env is read-only after first load; concurrent reads are safe.
    nonisolated(unsafe) static var _dotenvCache: [String: String]? = nil
    static let keychainService = "paris.yohann.WidgetProductive"

    // MARK: .env loader (DEBUG only)

    static func dotenv(key: Key) throws -> String {
        let env = try loadDotenv()
        guard let value = env[key.rawValue] else {
            throw SecretsError.missingKey(key.rawValue)
        }
        return value
    }

    static func loadDotenv() throws -> [String: String] {
        if let cached = _dotenvCache { return cached }
        let fm = FileManager.default

        // 1. Walk up from CWD (reliable for CLI tools run from the project root).
        var dir = fm.currentDirectoryPath
        for _ in 0..<8 {
            let candidate = (dir as NSString).appendingPathComponent(".env")
            if fm.fileExists(atPath: candidate) {
                let parsed = try parseDotenv(at: candidate)
                _dotenvCache = parsed
                return parsed
            }
            dir = (dir as NSString).deletingLastPathComponent
        }

        // 2. Walk up from bundle (works for app bundle in DerivedData layout).
        dir = Bundle.main.bundlePath
        for _ in 0..<8 {
            let candidate = (dir as NSString).appendingPathComponent(".env")
            if fm.fileExists(atPath: candidate) {
                let parsed = try parseDotenv(at: candidate)
                _dotenvCache = parsed
                return parsed
            }
            dir = (dir as NSString).deletingLastPathComponent
        }

        // 3. Source-relative fallback using #filePath (absolute at compile time).
        let sourceDir = URL(filePath: #filePath).deletingLastPathComponent()
                                                .deletingLastPathComponent()
                                                .deletingLastPathComponent()
        let candidate = sourceDir.appending(path: ".env").path(percentEncoded: false)
        if fm.fileExists(atPath: candidate) {
            let parsed = try parseDotenv(at: candidate)
            _dotenvCache = parsed
            return parsed
        }
        throw SecretsError.missingKey(".env file not found")
    }

    static func parseDotenv(at path: String) throws -> [String: String] {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        var result: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eqRange = trimmed.range(of: "=") else { continue }
            let k = String(trimmed[trimmed.startIndex..<eqRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
            var v = String(trimmed[eqRange.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) ||
               (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            result[k] = v
        }
        return result
    }

    // MARK: Keychain (RELEASE only)

    static func userDefaults(key: Key) throws -> String {
        guard let v = UserDefaults.standard.string(forKey: key.rawValue) else {
            throw SecretsError.missingKey(key.rawValue)
        }
        return v
    }

    static func keychain(key: Key) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw SecretsError.keychainError(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretsError.keychainDataCorrupt
        }
        return value
    }

    static func keychainStore(key: Key, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key.rawValue
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretsError.keychainError(status) }
    }

    static func keychainDelete(key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsError.keychainError(status)
        }
    }
}

// MARK: - Test seam (parseDotenv exposed for unit tests)

extension Secrets {
    enum Testable {
        static func parseDotenv(at path: String) throws -> [String: String] {
            try Secrets.parseDotenv(at: path)
        }
    }
}
