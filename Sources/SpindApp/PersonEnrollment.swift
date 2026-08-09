// Spind — Copyright (C) 2026 eigenhand
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public
// License along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import SpindCore

/// Zugang für eine andere Person: ein eigener Storage-Box-Subaccount mit
/// eigenem Verzeichnis und eigenem Schlüssel. Anders als beim eigenen
/// Zweitgerät sieht die Person nur diesen einen Ordner — und der Zugang
/// lässt sich jederzeit einzeln widerrufen, ohne eigene Geräte zu stören.
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

    /// Legt Subaccount + Ordner an, hinterlegt den Schlüssel im Zuhause des
    /// Subaccounts und liefert den fertigen Kopplungscode.
    static func createAccess(
        folder: String, label: String, readonly: Bool,
        pair: SSHKeyGen.KeyPair, config: SpindConfig
    ) async throws -> PairingCode {
        guard config.isHetznerBox else { throw PersonError.notAStorageBox }
        let relative = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        // 1. Ordner sicherstellen und Schlüssel dort hinterlegen — der
        //    Subaccount landet beim Login genau darin.
        let client = StorageBoxClient(config: config)
        try await client.connect()
        defer { Task { await client.disconnect() } }
        var root = config.remoteRoot
        if root.hasSuffix("/") { root = String(root.dropLast()) }
        let remoteFolder = root.isEmpty ? relative : root + "/" + relative
        try await client.run("mkdir -p -- \(StorageBoxClient.quote(remoteFolder))")

        // 2. Subaccount mit genau diesem Zuhause anlegen.
        let api = try HetznerAPI()
        let box = try await api.findBox(forUser: config.username)
        let home = box.username + "/" + relative
        let description = descriptionPrefix + label
        try await api.createSubaccount(
            boxID: box.id, homeDirectory: home,
            password: ShareManager.generatePassword(),
            description: description, readonly: readonly, sshEnabled: true
        )

        // 3. Auf das Erscheinen warten (Anlage ist asynchron).
        var created: HetznerAPI.Subaccount?
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(3))
            created = try? await api.subaccounts(boxID: box.id)
                .first { $0.description == description }
            if created != nil { break }
        }
        guard let account = created else { throw PersonError.notReady }

        // 4. Schlüssel in das Zuhause des Subaccounts schreiben.
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
