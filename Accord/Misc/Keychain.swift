import Foundation
import Security

final class KeychainManager {
    /// In-memory copy so the current session keeps working even if the keychain write fails
    /// (e.g. when the app is signed with a different team than the original keychain access group).
    private static var memoryCache: [String: Data] = [:]
    private static let cacheLock = NSLock()

    private class func baseQuery(_ key: String) -> [String: Any] {
        // NOTE: no kSecAttrAccessGroup here. The old hardcoded "group.evelyn.accord" group only
        // works with the original developer's signing team; with any other team SecItemAdd fails
        // with errSecMissingEntitlement and the token silently never gets stored.
        [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrAccount as String: key,
        ]
    }

    @discardableResult class func save(key: String, data: Data) -> OSStatus {
        cacheLock.lock()
        if data.isEmpty {
            memoryCache.removeValue(forKey: key)
        } else {
            memoryCache[key] = data
        }
        cacheLock.unlock()

        return DispatchQueue.global().sync {
            let query = baseQuery(key)
            SecItemDelete(query as CFDictionary)
            guard !data.isEmpty else { return noErr }
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                print("[Keychain] failed to save \(key): OSStatus \(status)")
            }
            return status
        }
    }

    class func load(key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = kCFBooleanTrue!
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var dataTypeRef: AnyObject?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == noErr, let data = dataTypeRef as? Data, !data.isEmpty {
            return data
        }
        if status != errSecItemNotFound {
            print("[Keychain] failed to load \(key): OSStatus \(status)")
        }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return memoryCache[key]
    }

    deinit {
        print("login ended")
    }
}
