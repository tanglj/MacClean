import Foundation

public struct ApplicationNameMapping: Sendable {
    private struct Payload: Decodable {
        let applications: [String: String]
        let aliases: [String: String]
    }

    private let namesByIdentifier: [String: String]
    private let identifiersByAlias: [String: String]

    public static let shared = load()

    public func name(for bundleIdentifier: String) -> String? {
        namesByIdentifier[normalizedIdentifier(bundleIdentifier)]
    }

    public func bundleIdentifier(matching value: String) -> String? {
        let identifier = normalizedIdentifier(value)
        if namesByIdentifier[identifier] != nil {
            return identifier
        }
        return identifiersByAlias[normalizedAlias(value)]
    }

    public func displayName(for value: String) -> String? {
        guard let identifier = bundleIdentifier(matching: value) else { return nil }
        return name(for: identifier)
    }

    private static func load() -> ApplicationNameMapping {
        guard let url = Bundle.module.url(forResource: "ApplicationNameMappings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return ApplicationNameMapping(namesByIdentifier: [:], identifiersByAlias: [:])
        }

        let canonicalIdentifiers = Dictionary(uniqueKeysWithValues: payload.applications.keys.map { (normalizedIdentifier($0), $0) })
        let names = Dictionary(uniqueKeysWithValues: payload.applications.map { (normalizedIdentifier($0.key), $0.value) })
        var aliases: [String: String] = [:]
        for (alias, identifier) in payload.aliases {
            let normalizedIdentifier = normalizedIdentifier(identifier)
            guard canonicalIdentifiers[normalizedIdentifier] != nil else { continue }
            aliases[normalizedAlias(alias)] = canonicalIdentifiers[normalizedIdentifier]!
        }
        return ApplicationNameMapping(namesByIdentifier: names, identifiersByAlias: aliases)
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.lowercased()
    }

    private static func normalizedAlias(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func normalizedIdentifier(_ value: String) -> String {
        Self.normalizedIdentifier(value)
    }

    private func normalizedAlias(_ value: String) -> String {
        Self.normalizedAlias(value)
    }
}
