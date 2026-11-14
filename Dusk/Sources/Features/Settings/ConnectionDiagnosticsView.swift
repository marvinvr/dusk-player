import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What the last connection selection saw, per server: every candidate URL,
/// how it answered, its latency, and which one won. Deliberately plain — it is
/// a support tool ("tell me what your phone sees"), reached from the bottom of
/// Server Priority. URLs never carry the token.
struct ConnectionDiagnosticsView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(ServerConnectionCoordinator.self) private var connections
    @State private var isTesting = false
    @State private var didCopy = false

    private var pool: ServerPool { plexService.pool }

    private var serverIDs: [String] {
        pool.priorityOrderedIdentifiers.filter { pool.state(for: $0) != .disabled }
    }

    private var reportText: String {
        serverIDs.map { serverID in
            let state = Self.stateText(pool.state(for: serverID))
            guard let report = pool.reports[serverID] else {
                return "\(pool.displayName(for: serverID)): \(state), no selection recorded yet"
            }
            return "State: \(state)\n" + report.text
        }
        .joined(separator: "\n\n")
    }

    var body: some View {
        content
            .duskSettingsPageBackground()
            .duskNavigationTitle("Connection Diagnostics")
            .duskNavigationBarTitleDisplayModeInline()
    }

    private func testAll() {
        guard !isTesting else { return }
        isTesting = true
        Task {
            await pool.diagnoseAll()
            isTesting = false
        }
    }

    private func reselect() {
        guard !isTesting else { return }
        isTesting = true
        Task {
            await connections.refresh(trigger: "Diagnostics re-select")
            isTesting = false
        }
    }

    // MARK: - iOS

    #if !os(tvOS)
    private var content: some View {
        SettingsList {
            Section {
                Button("Test Every Connection", action: testAll)
                Button("Re-select Now", action: reselect)
                Button(didCopy ? "Copied" : "Copy Report") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportText, forType: .string)
                    #else
                    UIPasteboard.general.string = reportText
                    #endif
                    didCopy = true
                }
                if isTesting {
                    HStack {
                        ProgressView()
                        Text("Probing…").foregroundStyle(Color.duskTextSecondary)
                    }
                }
            }
            .duskSettingsRowBackground()

            ForEach(serverIDs, id: \.self) { serverID in
                Section {
                    if let report = pool.reports[serverID] {
                        Text("\(report.trigger) · \(report.startedAt.formatted(date: .omitted, time: .standard)) · \(Self.milliseconds(report.duration))")
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                        ForEach(report.entries) { entry in
                            DiagnosticsEntryRow(entry: entry)
                        }
                    } else {
                        Text("No selection recorded yet this launch.")
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                } header: {
                    Text("\(pool.displayName(for: serverID)) · \(Self.stateText(pool.state(for: serverID), compact: true))")
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .duskSettingsRowBackground()
            }
        }
        .duskSettingsScrollBackgroundHidden()
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(title: "Connections") {
                    TVSettingsActionRow(title: "Test Every Connection", isLoading: isTesting, action: testAll)
                    TVSettingsActionRow(title: "Re-select Now", action: reselect)
                }

                ForEach(serverIDs, id: \.self) { serverID in
                    TVSettingsSection(
                        title: "\(pool.displayName(for: serverID)) · \(Self.stateText(pool.state(for: serverID), compact: true))"
                    ) {
                        if let report = pool.reports[serverID] {
                            Text("\(report.trigger) · \(report.startedAt.formatted(date: .omitted, time: .standard)) · \(Self.milliseconds(report.duration))")
                                .font(.caption)
                                .foregroundStyle(Color.duskTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            ForEach(report.entries) { entry in
                                DiagnosticsEntryRow(entry: entry)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                                    .focusable()
                            }
                        } else {
                            Text("No selection recorded yet this launch.")
                                .foregroundStyle(Color.duskTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 16)
                                .focusable()
                        }
                    }
                }
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }
    #endif

    // MARK: - Copy

    static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded())) ms"
    }

    static func stateText(_ state: ServerConnectionState, compact: Bool = false) -> String {
        switch state {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case let .connected(connection):
            compact ? "Connected" : "Connected · \(connection.baseURL.absoluteString)"
        case .unauthorized: "Token rejected"
        case let .offline(reason): "Offline · \(reason)"
        case .disabled: "Off"
        }
    }
}

private struct DiagnosticsEntryRow: View {
    let entry: ConnectionReport.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.isChosen ? Color.duskTextPrimary : Color.duskTextSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.url.absoluteString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("\(entry.locality.label) · \(entry.isSecure ? "https" : "http") · \(entry.source.label) · \(entry.outcome.summary)")
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        if entry.isChosen { return "checkmark.circle.fill" }
        switch entry.outcome {
        case .reachable: return "circle"
        case .skipped: return "minus.circle"
        default: return "xmark.circle"
        }
    }
}
