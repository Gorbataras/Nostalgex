import Foundation

public protocol CredentialStoring: Sendable {
    @discardableResult
    func save(key: String, value: String) -> Bool
    func load(key: String) -> String?
    func delete(key: String)
}

public struct KeychainCredentialStore: CredentialStoring {
    public init() {}

    @discardableResult
    public func save(key: String, value: String) -> Bool { KeychainService.save(key: key, value: value) }
    public func load(key: String) -> String? { KeychainService.load(key: key) }
    public func delete(key: String) { KeychainService.delete(key: key) }
}

