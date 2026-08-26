import Foundation
import Security
import LocalAuthentication

enum KeychainError: Error, LocalizedError {
    case accessControl
    case status(OSStatus)
    case notFound
    case userCanceled
    case biometryUnavailable

    var errorDescription: String? {
        switch self {
        case .accessControl:
            return "Could not create keychain access control."
        case .status(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "code \(s)"
            return "Keychain error: \(msg)"
        case .notFound:
            return "No Touch ID key is stored. Unlock with your master password and re-enable Touch ID in Settings."
        case .userCanceled:
            return "Canceled."
        case .biometryUnavailable:
            return "Touch ID is not available on this Mac."
        }
    }
}

/// Stores the vault's symmetric key so it can be released with Touch ID.
///
/// Preferred path: the data-protection keychain with an OS-enforced
/// `.biometryCurrentSet` access control. Ad-hoc-signed local builds cannot use
/// that keychain (missing entitlement), so there is a fallback that stores the
/// key in the login keychain and gates access behind an explicit LAContext
/// biometry check in-app.
enum KeychainService {

    private static let service = "com.secretsvault.app"
    private static let account = "vault-master-key"

    static var biometryAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static func storeKey(_ keyData: Data) throws {
        deleteKey()

        var acErr: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &acErr
        ) else { throw KeychainError.accessControl }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: keyData
        ]
        var status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecMissingEntitlement || status == errSecParam {
            // Fallback for ad-hoc signed builds: login keychain item,
            // biometry enforced in-app (see fetchKey).
            query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            query.removeValue(forKey: kSecAttrAccessControl as String)
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func fetchKey(reason: String) async throws -> Data {
        let context = LAContext()
        context.localizedReason = reason

        // Try the data-protection keychain first (Touch ID enforced by the OS).
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.notFound }
            return data
        case errSecUserCanceled, errSecAuthFailed:
            throw status == errSecUserCanceled ? KeychainError.userCanceled : KeychainError.status(status)
        case errSecItemNotFound, errSecMissingEntitlement, errSecParam:
            break // fall through to the login-keychain path
        default:
            throw KeychainError.status(status)
        }

        // Login-keychain fallback: require biometry in-app, then read the item.
        guard biometryAvailable else { throw KeychainError.biometryUnavailable }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                      localizedReason: reason)
            guard ok else { throw KeychainError.userCanceled }
        } catch let e as LAError where e.code == .userCancel || e.code == .systemCancel || e.code == .appCancel {
            throw KeychainError.userCanceled
        }

        query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        query.removeValue(forKey: kSecUseAuthenticationContext as String)
        item = nil
        status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.notFound }
            return data
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecUserCanceled:
            throw KeychainError.userCanceled
        default:
            throw KeychainError.status(status)
        }
    }

    static func deleteKey() {
        for useDataProtection in [true, false] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            if useDataProtection {
                query[kSecUseDataProtectionKeychain as String] = true
            }
            SecItemDelete(query as CFDictionary)
        }
    }
}
