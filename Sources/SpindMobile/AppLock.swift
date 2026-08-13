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

import LocalAuthentication
import SwiftUI

/// Freiwillige Sperre vor der App. Sie schützt, was **in dieser App** zu
/// sehen ist — den Serverzugang, den Papierkorb, den Verlauf. Die Dateien
/// selbst liegen in der Dateien-App und bleiben dort sichtbar; das sagt die
/// Oberfläche auch, sonst wäre es Beruhigung statt Schutz.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    private static let key = "appLockEnabled"

    @Published private(set) var locked: Bool
    @Published private(set) var failure: String?

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.key)
            if !enabled { locked = false }
        }
    }

    private init() {
        let on = UserDefaults.standard.bool(forKey: Self.key)
        enabled = on
        locked = on
    }

    /// Gibt es überhaupt Face ID, Touch ID oder wenigstens einen Code?
    var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Wie die Sperre auf diesem Gerät heißt.
    var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Code"
        }
    }

    func lock() {
        if enabled { locked = true }
    }

    func unlock() async {
        guard locked else { return }
        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        do {
            // deviceOwnerAuthentication und nicht …WithBiometrics: Bei einer
            // Maske oder nassen Fingern bleibt der Gerätecode als Weg —
            // sonst sperrt man sich aus der eigenen App aus.
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Spind entsperren"
            )
            locked = !ok
            failure = nil
        } catch {
            failure = (error as? LAError)?.code == .userCancel
                ? nil
                : error.localizedDescription
        }
    }
}

struct LockView: View {
    @ObservedObject var lock = AppLock.shared

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("Spind ist gesperrt")
                    .font(.title3.weight(.semibold))
                if let failure = lock.failure {
                    Text(failure)
                        .font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Mit \(lock.methodName) entsperren", systemImage: "faceid")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
        }
        .task { await lock.unlock() }
    }
}
