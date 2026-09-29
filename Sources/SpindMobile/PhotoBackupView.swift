// Spind — Copyright (C) 2026 Christoph Lindl-Guk
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import SpindCore

struct PhotoBackupView: View {
    let config: SpindConfig

    @ObservedObject private var backup = PhotoBackup.shared
    @State private var askAboutExisting = false

    var body: some View {
        Form {
            if backup.run != nil { progressSection }
            switchSection
            targetSection
            scopeSection
            actionSection
        }
        .navigationTitle("Fotos")
        .navigationBarTitleDisplayMode(.inline)
        .task { backup.countWaiting() }
        .confirmationDialog(
            "Auch die vorhandenen Aufnahmen mitnehmen?",
            isPresented: $askAboutExisting, titleVisibility: .visible
        ) {
            Button("Alle sichern") { start(existing: true) }
            Button("Nur neue ab jetzt") { start(existing: false) }
            Button("Abbrechen", role: .cancel) { backup.settings.enabled = false }
        } message: {
            Text(backup.waiting.map {
                "In deiner Mediathek liegen \($0) Aufnahmen. Alle zu sichern kann "
                + "dauern und braucht Platz auf der Box."
            } ?? "Alles Vorhandene zu sichern kann dauern und braucht Platz auf der Box.")
        }
    }

    // MARK: - Upload in progress

    @ViewBuilder
    private var progressSection: some View {
        if let run = backup.run {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(run.done) von \(run.total)")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Spacer()
                        if run.failed > 0 {
                            Text("\(run.failed) übersprungen")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    ProgressView(value: run.fraction)
                    // Several transfers run at once — naming "this one"
                    // would be a lie, so name the last one finished.
                    Text(run.current.map { "zuletzt: \($0)" } ?? "Wird vorbereitet …")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 4)
                Button("Anhalten", role: .destructive) { backup.pause() }
            } header: {
                Text("Läuft")
            } footer: {
                Label("Lass die App offen und den Bildschirm an, bis es fertig ist – "
                      + "im Hintergrund friert iOS den Upload ein. Der Bildschirm "
                      + "bleibt so lange von selbst wach.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Settings

    private var switchSection: some View {
        Section {
            Toggle("Fotos sichern", isOn: Binding(
                get: { backup.settings.enabled },
                set: { on in
                    backup.settings.enabled = on
                    if on { askAboutExisting = true }
                }
            ))
            if let waiting = backup.waiting, backup.run == nil {
                LabeledContent("Wartet", value: waiting == 0
                               ? "nichts – alles gesichert"
                               : "\(waiting) Aufnahmen")
            }
        } footer: {
            Text("Neue Aufnahmen landen von selbst im Spind, sobald die App offen ist oder iOS sie im Hintergrund weckt. Nichts wird vom iPhone gelöscht.")
        }
    }

    private var targetSection: some View {
        Section("Zielordner") {
            TextField("Bilder", text: Binding(
                get: { backup.settings.folder },
                set: { backup.settings.folder = $0 }
            ))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            Picker("Aufteilung", selection: Binding(
                get: { backup.settings.layout },
                set: { backup.settings.layout = $0 }
            )) {
                ForEach(PhotoLayout.allCases, id: \.self) { layout in
                    Text(layout.label).tag(layout)
                }
            }
            .pickerStyle(.navigationLink)
            LabeledContent("Beispiel") {
                Text(example)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
    }

    private var scopeSection: some View {
        Section {
            Toggle("Videos mitnehmen", isOn: Binding(
                get: { backup.settings.includeVideos },
                set: { backup.settings.includeVideos = $0; backup.countWaiting() }
            ))
            Toggle("Nur im WLAN", isOn: Binding(
                get: { backup.settings.wifiOnly },
                set: { backup.settings.wifiOnly = $0 }
            ))
        } footer: {
            Text("Videos sind groß – im Mobilfunk kostet das Datenvolumen und Akku. »Jetzt sichern« von Hand läuft auch ohne WLAN.")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await backup.run(config: config, manual: true) }
            } label: {
                HStack {
                    if backup.running { ProgressView().padding(.trailing, 4) }
                    Text("Jetzt sichern")
                }
            }
            .disabled(backup.running)
            if let status = backup.status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            if let last = backup.settings.lastUploaded {
                LabeledContent("Zuletzt gesichert", value: Recovery.moment(last))
            }
        } footer: {
            Text("Offene Aufnahmen gehen durch, solange diese App vorn ist – beim Verlassen hält es an und macht später weiter. Wenn iOS die App im Hintergrund weckt, sind es bis zu \(PhotoBackup.batchSize) pro Weckruf. Ein zweites Mal hochgeladen wird nichts.")
        }
    }

    // MARK: -

    /// "Only new": the state is set to now, everything older counts as
    /// done. Otherwise the first run takes the whole library along.
    private func start(existing: Bool) {
        backup.markExisting(asDone: !existing)
        Task { await backup.run(config: config, manual: true) }
    }

    /// Shows with today as an example where a picture would land — that
    /// explains the split better than any description.
    private var example: String {
        backup.settings.layout.path(
            for: Date(),
            folder: backup.settings.folder.isEmpty ? "Bilder" : backup.settings.folder,
            fileName: "IMG_0042.HEIC"
        )
    }
}
