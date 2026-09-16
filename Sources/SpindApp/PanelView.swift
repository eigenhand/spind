// Spind — Copyright (C) 2026 Christoph Lindl-Guk
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

import SwiftUI
import AppKit
import SpindCore

/// The window shown when clicking the menu bar icon — cloud-drive style.
struct PanelView: View {
    @ObservedObject var controller: SyncController
    @Environment(\.openSettings) private var openSettings
    @State private var confirmQuit = false
    @State private var confirmDeletions = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .confirmationDialog(
            "Spind beenden?", isPresented: $confirmQuit, titleVisibility: .visible
        ) {
            Button("Beenden", role: .destructive) { NSApplication.shared.terminate(nil) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Solange Spind nicht läuft, werden keine Änderungen übertragen.")
        }
        .confirmationDialog(
            "\(controller.pendingBulkDeletions ?? 0) Löschungen wirklich übertragen?",
            isPresented: $confirmDeletions, titleVisibility: .visible
        ) {
            Button("Löschungen übertragen", role: .destructive) {
                controller.confirmBulkDeletions()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Prüfe vorher, ob dein Ordner vollständig ist – etwa nach einem Umzug oder wenn eine Festplatte nicht eingebunden war. Gelöschte Dateien lassen sich über die Versionen zurückholen.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.15, green: 0.45, blue: 0.95),
                                     Color(red: 0.25, green: 0.75, blue: 0.95)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .shadow(color: .blue.opacity(0.35), radius: 5, y: 2)
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Spind")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    statusDot
                    Text(controller.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if case .syncing = controller.status {
                SpinningSyncIcon()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        switch controller.status {
        case .idle: return .green
        case .syncing: return .blue
        case .paused: return .orange
        case .offline: return .gray
        case .error: return .red
        case .notConfigured: return .gray
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if case .notConfigured = controller.status {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32)).foregroundStyle(.blue.gradient)
                Text("Willkommen bei Spind").font(.callout.weight(.medium))
                Text("In vier Schritten eingerichtet – Schlüssel erzeuge ich für dich.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Jetzt einrichten") {
                    SetupWizardManager.open(controller: controller)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30).padding(.horizontal, 24)
        } else if case .error(let message) = controller.status {
            VStack(spacing: 12) {
                emptyState(
                    symbol: "exclamationmark.triangle.fill", tint: .red,
                    title: String(localized: "Sync angehalten"), subtitle: message
                )
                if let count = controller.pendingBulkDeletions {
                    Button("\(count) Löschungen bestätigen", role: .destructive) {
                        confirmDeletions = true
                    }
                    .padding(.bottom, 16)
                }
            }
        } else if case .offline = controller.status {
            emptyState(
                symbol: "wifi.slash", tint: .gray,
                title: String(localized: "Keine Verbindung"),
                subtitle: String(localized: "Spind macht weiter, sobald das Netzwerk zurück ist.")
            )
        } else if controller.isPaused {
            emptyState(
                symbol: "pause.circle.fill", tint: .orange,
                title: String(localized: "Pausiert"),
                subtitle: String(localized: "Änderungen werden gesammelt, aber nicht übertragen.")
            )
        } else if !controller.folderSyncEnabled && controller.transfers.isEmpty {
            emptyState(
                symbol: "folder.badge.questionmark", tint: .orange,
                title: String(localized: "Ordner-Sync ist aus"),
                subtitle: String(localized: "Nur das Finder-Laufwerk ist aktiv. Dein Ordner \(controller.localRootURL?.lastPathComponent ?? "") wird nicht abgeglichen.")
            )
        } else if controller.transfers.isEmpty && controller.entries.isEmpty {
            emptyState(
                symbol: "checkmark.circle.fill", tint: .green,
                title: String(localized: "Alles synchron"),
                subtitle: String(localized: "Änderungen werden automatisch übertragen.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !controller.transfers.isEmpty {
                        sectionHeader(String(localized: "Übertragungen"))
                        VStack(spacing: 8) {
                            ForEach(controller.transfers) { transfer in
                                TransferRow(transfer: transfer)
                            }
                        }
                    }
                    if !controller.entries.isEmpty {
                        sectionHeader(String(localized: "Aktivität"))
                        VStack(spacing: 0) {
                            ForEach(controller.entries.prefix(12)) { entry in
                                ActivityRow(entry: entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 380)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.tertiary)
    }

    private func emptyState(
        symbol: String, tint: Color, title: String, subtitle: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(tint.gradient)
            Text(title)
                .font(.callout.weight(.medium))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(symbol: "arrow.triangle.2.circlepath", help: "Jetzt synchronisieren") {
                controller.syncNow()
            }
            .disabled(controller.isPaused)
            FooterButton(
                symbol: controller.isPaused ? "play.fill" : "pause.fill",
                help: controller.isPaused ? "Fortsetzen" : "Pausieren"
            ) {
                controller.togglePause()
            }
            FooterButton(symbol: "folder", help: "Spind im Finder öffnen") {
                if let url = controller.driveURL ?? controller.localRootURL {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
            FooterButton(symbol: "gearshape", help: "Einstellungen") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            FooterButton(symbol: "power", help: "Spind beenden") {
                confirmQuit = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Components

struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct SpinningSyncIcon: View {
    @State private var isSpinning = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.blue)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                .linear(duration: 1.4).repeatForever(autoreverses: false),
                value: isSpinning
            )
            .onAppear { isSpinning = true }
    }
}

struct TransferRow: View {
    let transfer: FileTransfer

    private var fileName: String {
        (transfer.id as NSString).lastPathComponent
    }

    private var directionColor: Color {
        transfer.direction == .upload ? .blue : .green
    }

    var body: some View {
        HStack(spacing: 10) {
            fileIcon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fileName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(transfer.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: transfer.fraction)
                    .progressViewStyle(.linear)
                    .tint(directionColor)
                    .controlSize(.small)
                HStack {
                    Text("\(format(transfer.transferred)) von \(format(transfer.total))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: transfer.direction == .upload
                          ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(directionColor)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.55))
        )
    }

    private var fileIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(directionColor.opacity(0.14))
                .frame(width: 32, height: 32)
            Image(systemName: symbolForFile(fileName))
                .font(.system(size: 14))
                .foregroundStyle(directionColor)
        }
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(entry.kind.tint.opacity(0.14))
                    .frame(width: 26, height: 26)
                Image(systemName: entry.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.kind.tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.kind.label.isEmpty {
                    Text(entry.kind.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(relative(entry.date))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale.current
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

func symbolForFile(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": return "photo"
    case "mov", "mp4", "avi", "mkv": return "film"
    case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
    case "pdf": return "doc.richtext"
    case "doc", "docx", "pages", "txt", "md", "rtf": return "doc.text"
    case "xls", "xlsx", "numbers", "csv": return "tablecells"
    case "ppt", "pptx", "key": return "rectangle.on.rectangle"
    case "zip", "tar", "gz", "7z", "rar", "dmg": return "shippingbox"
    case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "sh": return "chevron.left.forwardslash.chevron.right"
    case "sketch", "fig", "psd", "ai": return "paintbrush.pointed"
    case "": return "doc"
    default: return "doc"
    }
}
