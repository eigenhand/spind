// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SpindCore

/// Access for another person: a storage box subaccount of their own,
/// with its own directory and its own key. Unlike a second device of
/// your own, the person sees only this one folder — and the access can
/// be revoked on its own at any time, without disturbing your devices.
enum PersonEnrollment {
    static let descriptionPrefix = "Spind-Zugang: "

    enum PersonError: LocalizedError {
        case notAStorageBox
        case notReady

        var errorDescription: String? {
            switch self {
            case .notAStorageBox:
                return "Eigene Zugänge gibt es nur mit einer Hetzner Storage Box "
                    + "(sie entstehen als Subaccount). Für andere Server lege den "
                    + "Zugang direkt auf dem Server an."
            case .notReady:
                return "Der Zugang wurde angelegt, ist aber noch nicht abrufbar. "
                    + "Versuche es in einer Minute erneut."
            }
        }
    }

    /// Creates the subaccount and folder, puts the key into the
    /// subaccount's home and returns the finished pairing code.
    static func createAccess(
        folder: String, label: String, readonly: Bool,
        pair: SSHKeyGen.KeyPair, config: SpindConfig
    ) async throws -> PairingCode {
        guard config.isHetznerBox else { throw PersonError.notAStorageBox }
        let relative = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        // 1. Make sure the folder exists and put the key there — the
        //    subaccount lands exactly inside it on login.
        let client = StorageBoxClient(config: config)
        try await client.connect()
        defer { Task { await client.disconnect() } }
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        let remoteFolder = root.isEmpty ? relative : root + "/" + relative
        try await client.run("mkdir -p -- \(StorageBoxClient.quote(remoteFolder))")

        // 2. Create the subaccount with precisely that home.
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: config.username)
        let used = try await api.subaccounts(boxID: box.id).count
        guard ShareRules.remainingSlots(used: used) > 0 else {
            throw HetznerAPI.APIError.limitReached(used: used)
        }
        let home = box.username + "/" + relative
        let description = descriptionPrefix + label
        try await api.createSubaccount(
            boxID: box.id, homeDirectory: home,
            password: ShareManager.generatePassword(),
            description: description, readonly: readonly, sshEnabled: true
        )

        // 3. Wait for it to appear (creation is asynchronous).
        var created: HetznerAPI.Subaccount?
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(3))
            created = try? await api.subaccounts(boxID: box.id)
                .first { $0.description == description }
            if created != nil { break }
        }
        guard let account = created else { throw PersonError.notReady }

        // 4. Write the key into the subaccount's home.
        var keyConfig = config
        keyConfig.remoteRoot = remoteFolder
        let keyClient = StorageBoxClient(config: keyConfig)
        try await keyClient.connect()
        try await DeviceEnrollment.addAuthorizedKey(
            pair.publicLine, client: keyClient, home: remoteFolder
        )
        await keyClient.disconnect()

        var accessConfig = config
        accessConfig.username = account.username
        accessConfig.host = account.server
        return PairingCode(config: accessConfig, pair: pair)
    }
}
