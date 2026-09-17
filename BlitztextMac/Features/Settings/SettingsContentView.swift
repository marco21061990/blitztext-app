import SwiftUI
import AppKit

struct SettingsContentView: View {
    @Bindable var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Two-tab segmented picker
            Picker("", selection: $selectedTab) {
                Text("Anpassen").tag(0)
                Text("Zugang").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                if selectedTab == 0 {
                    CustomizeSettingsView(appState: appState)
                } else {
                    AccessSettingsView(appState: appState)
                }
            }
        }
        .onAppear {
            appState.refreshAccessibilityPermission()
            selectedTab = defaultTabSelection
        }
    }

    private var defaultTabSelection: Int {
        if !appState.accessibilityPermissionGranted {
            return 1
        }
        if appState.isConfigured && !BlitztextInstallLocationService.shouldOfferMoveToApplications {
            return 0
        }
        return 1
    }
}

// MARK: - Section Label (quiet style)

private struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - API Usage Section (local estimate)

/// Compact, read-only view of locally recorded OpenAI usage and estimated cost.
/// Reads the shared `OpenAIUsageStore`, so it updates live when new usage is
/// recorded while settings are open. All figures are local estimates.
struct APIUsageSection: View {
    private var store: OpenAIUsageStore { OpenAIUsageStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "API-Verbrauch")

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Zuletzt")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
                Text(lastActionText)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            usageRow(label: "Heute", totals: store.todayTotals)
            usageRow(label: "Dieser Monat", totals: store.monthTotals)

            Text("Lokale Schätzung in USD. Erfasst nur Blitztext-Aufrufe ab Aktivierung dieser Funktion, ohne frühere Nutzung. Maßgeblich ist deine OpenAI-Abrechnung.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link("OpenAI Usage Dashboard öffnen", destination: OpenAIPricing.usageDashboardURL)
                .font(.system(size: 10.5, weight: .medium))
        }
    }

    private func usageRow(label: String, totals: OpenAIUsageTotals) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(summaryText(for: totals))
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting

    private var lastActionText: String {
        guard let record = store.lastRecord else {
            return "Noch keine Aufrufe erfasst."
        }
        let kind = record.kind == .transcription ? "Transkription" : "Textbearbeitung"
        let relative = Self.relativeFormatter.localizedString(for: record.timestamp, relativeTo: Date())
        return "\(kind) · \(record.model) · \(relative)"
    }

    private func summaryText(for totals: OpenAIUsageTotals) -> String {
        guard !totals.isEmpty else { return "Keine Aufrufe." }

        var parts: [String] = ["\(totals.callCount)×"]
        if totals.audioSeconds > 0 {
            parts.append(Self.audioText(seconds: totals.audioSeconds))
        }
        if totals.inputTokens > 0 || totals.outputTokens > 0 {
            parts.append("\(Self.decimal(totals.inputTokens))/\(Self.decimal(totals.outputTokens)) Tokens")
        }
        if totals.hasCostEstimate {
            parts.append("≈ \(Self.usdText(totals.estimatedCostUSD)) USD")
        }
        return parts.joined(separator: " · ")
    }

    private static func audioText(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 60 {
            return "\(total / 60) min \(total % 60) s"
        }
        return "\(total) s"
    }

    private static func decimal(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func usdText(_ value: Double) -> String {
        usdFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.4f", value)
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "de_DE")
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "de_DE")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - Access Settings (Tab 1: Zugang)

struct AccessSettingsView: View {
    private static let openAIAPIKeyPattern = #"^sk-[A-Za-z0-9_-]{20,}$"#

    @Bindable var appState: AppState

    private enum FieldFocus {
        case openAIAPIKey
    }

    @State private var launchAtLoginService = LaunchAtLoginService()
    @State private var currentInstallLocation = BlitztextInstallLocationService.currentInstallLocation
    @State private var openAIAPIKey = ""
    @State private var editingAPIKey = false
    @State private var saved = false
    @State private var saveErrorText: String?
    @State private var isTestingOpenAIAPIKey = false
    @State private var openAIAPIKeyTestText: String?
    @State private var openAIAPIKeyTestSucceeded = false
    @State private var installActionErrorText: String?
    @State private var showCleanupOptions = false
    @State private var deleteLocalDataOnCleanup = true
    @State private var cleanupStatusText: String?
    @State private var cleanupErrorText: String?
    @FocusState private var focusedField: FieldFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Berechtigungen")

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: appState.accessibilityPermissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(appState.accessibilityPermissionGranted ? .green : .orange)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.accessibilityPermissionGranted ? "Direktes Einfügen ist freigegeben." : "Direktes Einfügen ist noch nicht freigegeben.")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("Öffne Bedienungshilfen und aktiviere Blitztext. Falls Blitztext schon aktiv ist, einmal aus- und wieder einschalten.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button("Bedienungshilfen öffnen") {
                        appState.requestAccessibilityPermission()
                    }
                    .buttonStyle(SubtleButtonStyle())

                    Button("Erneut prüfen") {
                        appState.refreshAccessibilityPermission()
                    }
                    .buttonStyle(SubtleButtonStyle())

                    Button("Einfügen testen") {
                        appState.testAutoPaste()
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "OpenAI API Key")
                    Spacer()
                    if appState.hasValue(for: .openAIAPIKey) && !editingAPIKey {
                        Button("Aendern") { editingAPIKey = true }
                            .font(.system(size: 10, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                }

                if appState.hasValue(for: .openAIAPIKey) && !editingAPIKey {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.8))
                        Text(appState.apiKeyDisplayValue(for: .openAIAPIKey))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                } else {
                    HStack(spacing: 8) {
                        SecureField("sk-...", text: $openAIAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                            .focused($focusedField, equals: .openAIAPIKey)

                        Button("Einfuegen") {
                            pasteAPIKeyFromClipboard()
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }
                }

                Text("Dein Key bleibt lokal in dieser App. Audio und Text werden direkt an die OpenAI API gesendet.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(isTestingOpenAIAPIKey ? "Teste..." : "OpenAI Key testen") {
                        testOpenAIAPIKey()
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(isTestingOpenAIAPIKey)

                    if let openAIAPIKeyTestText {
                        Text(openAIAPIKeyTestText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(openAIAPIKeyTestSucceeded ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            APIUsageSection()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Installation")

                Text(installationHeadline)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(installationDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(BlitztextInstallLocationService.bundleURL.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !BlitztextInstallLocationService.otherInstalledBundleURLs.isEmpty {
                    Text("Weitere Blitztext-Kopien auf diesem Mac können doppelte Login-Items auslösen.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if BlitztextInstallLocationService.shouldOfferMoveToApplications {
                        Button("Nach /Applications bewegen") {
                            moveToApplications()
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }

                    Button("Im Finder zeigen") {
                        revealInFinder(urls: [BlitztextInstallLocationService.bundleURL])
                    }
                    .buttonStyle(SubtleButtonStyle())

                    if !BlitztextInstallLocationService.otherInstalledBundleURLs.isEmpty {
                        Button("Weitere Kopien zeigen") {
                            revealInFinder(urls: BlitztextInstallLocationService.otherInstalledBundleURLs)
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }
                }

                if let installActionErrorText {
                    Text(installActionErrorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Updates")

                Text("Diese Preview hat keinen oeffentlichen Update-Feed. Baue neue Versionen selbst aus dem Repo.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !currentInstallLocation.isCanonicalInstall {
                    Text("Hotkeys und Login-Start laufen am stabilsten, wenn Blitztext aus /Applications gestartet wird.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Updates sind in dieser Preview manuell: pull, build, starten.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            // Launch at Login
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Beim Anmelden")

                Toggle("Blitztext automatisch starten", isOn: Binding(
                    get: { launchAtLoginService.isEnabled },
                    set: { launchAtLoginService.setEnabled($0) }
                ))
                .toggleStyle(.switch)

                Text(launchAtLoginService.errorText ?? launchAtLoginService.helperText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(
                        launchAtLoginService.errorText == nil
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.red)
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let saveErrorText {
                Text(saveErrorText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Hinweis")

                Text("Fuer direktes Einfuegen: Blitztext einmal nach /Applications legen und danach Mikrofon sowie Bedienungshilfen erlauben.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Sauber Entfernen")

                Text("Vor dem Löschen Blitztext erst auf diesem Mac bereinigen. So verschwinden Anmeldestart und lokale Daten sauber aus dem Weg.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showCleanupOptions {
                    Toggle("Zugangsdaten und Einstellungen dieses Macs löschen", isOn: $deleteLocalDataOnCleanup)
                        .toggleStyle(.switch)

                    Text("Danach Blitztext beenden und die App aus /Applications löschen. Bereits verwaiste alte Login-Items können in den Systemeinstellungen einmalig manuell entfernt werden.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Abbrechen") {
                            showCleanupOptions = false
                        }
                        .buttonStyle(SubtleButtonStyle())

                        Button("Jetzt bereinigen") {
                            runCleanup()
                        }
                        .buttonStyle(SubtleButtonStyle())
                        .foregroundStyle(.red)
                    }
                } else {
                    Button("Entfernung vorbereiten") {
                        showCleanupOptions = true
                    }
                    .buttonStyle(SubtleButtonStyle())
                }

                if let cleanupStatusText {
                    Text(cleanupStatusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let cleanupErrorText {
                    Text(cleanupErrorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Save button (right-aligned, text only)
            HStack {
                Spacer()
                Button {
                    save()
                } label: {
                    if saved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("Gespeichert")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                    } else {
                        Text("Speichern")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(SubtleButtonStyle())
                .animation(.easeInOut(duration: 0.2), value: saved)
            }
        }
        .padding(16)
        .onAppear {
            launchAtLoginService.refresh()
            refreshInstallState()
            load()
            if !appState.hasValue(for: .openAIAPIKey) {
                editingAPIKey = true
                focusedField = .openAIAPIKey
            }
        }
    }

    private func load() {
        openAIAPIKey = ""
    }

    private func save() {
        saveErrorText = nil
        openAIAPIKeyTestText = nil
        cleanupStatusText = nil
        cleanupErrorText = nil
        KeychainService.invalidateCache()
        let trimmedAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if editingAPIKey || !appState.hasValue(for: .openAIAPIKey) {
            guard !trimmedAPIKey.isEmpty else {
                saveErrorText = "Bitte trage deinen OpenAI API Key ein."
                return
            }
            do {
                try KeychainService.save(key: .openAIAPIKey, value: trimmedAPIKey)
                openAIAPIKey = ""
                editingAPIKey = false
                openAIAPIKeyTestText = nil
            } catch {
                saveErrorText = "OpenAI API Key konnte nicht gespeichert werden."
                return
            }
        }

        KeychainService.invalidateCache()
        if !appState.hasValue(for: .openAIAPIKey) {
            saveErrorText = "OpenAI API Key wurde nicht persistent gespeichert. Bitte App neu starten und erneut versuchen."
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) { saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.2)) { saved = false }
        }
    }

    private func pasteAPIKeyFromClipboard() {
        guard let rawText = NSPasteboard.general.string(forType: .string) else {
            saveErrorText = "Zwischenablage enthält keinen Text."
            return
        }

        let firstLine = rawText.components(separatedBy: .newlines).first ?? rawText
        let trimmedKey = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.range(of: Self.openAIAPIKeyPattern, options: .regularExpression) != nil else {
            saveErrorText = "Zwischenablage enthält keinen plausiblen OpenAI API Key."
            return
        }

        openAIAPIKey = trimmedKey
        NSPasteboard.general.clearContents()
        saveErrorText = nil
        openAIAPIKeyTestText = nil
    }

    private func testOpenAIAPIKey() {
        guard !isTestingOpenAIAPIKey else { return }

        saveErrorText = nil
        cleanupStatusText = nil
        cleanupErrorText = nil

        guard appState.hasValue(for: .openAIAPIKey), !editingAPIKey else {
            openAIAPIKeyTestSucceeded = false
            openAIAPIKeyTestText = "Bitte zuerst OpenAI API Key speichern."
            return
        }

        isTestingOpenAIAPIKey = true
        openAIAPIKeyTestSucceeded = false
        openAIAPIKeyTestText = "Teste OpenAI API..."

        Task {
            let result = await OpenAIKeyValidationService.validateStoredKey()
            await MainActor.run {
                isTestingOpenAIAPIKey = false
                switch result {
                case .success(let message):
                    openAIAPIKeyTestSucceeded = true
                    openAIAPIKeyTestText = message
                case .failure(let message):
                    openAIAPIKeyTestSucceeded = false
                    openAIAPIKeyTestText = message
                }
            }
        }
    }

    private var installationHeadline: String {
        switch currentInstallLocation {
        case .applications:
            return "Blitztext liegt am richtigen Ort."
        case .userApplications:
            return "Blitztext liegt noch in ~/Applications."
        case .outsideApplications:
            return "Blitztext liegt noch nicht in /Applications."
        case .unknown:
            return "Der Installationsort konnte nicht sicher erkannt werden."
        }
    }

    private var installationDetail: String {
        switch currentInstallLocation {
        case .applications:
            if BlitztextInstallLocationService.otherInstalledBundleURLs.isEmpty {
                return "Für stabile Login-Items und Updates nur diese Kopie weiterverwenden."
            }
            return "Diese Kopie ist korrekt. Zusätzliche Kopien solltest du später entfernen."
        case .userApplications:
            return "Fuer stabile Hotkeys und Login-Items sollte Blitztext nur aus /Applications laufen."
        case .outsideApplications:
            return "Verschiebe Blitztext einmal nach /Applications, damit Anmeldestart und Hotkeys sauber bleiben."
        case .unknown:
            return "Öffne Blitztext möglichst direkt aus /Applications."
        }
    }

    private func refreshInstallState() {
        currentInstallLocation = BlitztextInstallLocationService.currentInstallLocation
        installActionErrorText = nil
    }

    private func moveToApplications() {
        installActionErrorText = nil

        do {
            try BlitztextInstallLocationService.moveToApplicationsAndRelaunch()
        } catch {
            installActionErrorText = error.localizedDescription
        }
    }

    private func runCleanup() {
        cleanupStatusText = nil
        cleanupErrorText = nil

        if deleteLocalDataOnCleanup {
            // The filesystem cleanup removes Application Support, but the
            // process-local store would otherwise retain and later rewrite its
            // records after cleanup.
            OpenAIUsageStore.shared.clear()
        }

        let report = deleteLocalDataOnCleanup
            ? BlitztextCleanupService.cleanupUserData()
            : BlitztextCleanupService.removeLaunchAtLoginRegistration()

        KeychainService.invalidateCache()
        launchAtLoginService.refresh()
        refreshInstallState()

        if deleteLocalDataOnCleanup {
            openAIAPIKey = ""
            editingAPIKey = true
        }

        if report.failedItems.isEmpty {
            cleanupStatusText = deleteLocalDataOnCleanup
                ? "Anmeldestart und lokale Daten wurden bereinigt. Jetzt Blitztext beenden und aus /Applications löschen."
                : "Anmeldestart wurde deaktiviert. Jetzt Blitztext beenden und aus /Applications löschen."
            showCleanupOptions = false

            let urlsToReveal = report.knownInstallBundleURLs.isEmpty
                ? [BlitztextInstallLocationService.bundleURL]
                : report.knownInstallBundleURLs
            revealInFinder(urls: urlsToReveal)
            return
        }

        let failureSummary = report.failedItems
            .map { "\($0.url.lastPathComponent): \($0.errorDescription)" }
            .joined(separator: "\n")
        cleanupErrorText = "Nicht alles konnte bereinigt werden:\n\(failureSummary)"
    }

    private func revealInFinder(urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

// MARK: - Customize Settings (Tab 2: Anpassen)

struct CustomizeSettingsView: View {
    @Bindable var appState: AppState
    @State private var newTerm = ""
    @State private var recordingWorkflow: WorkflowType?
    @State private var shortcutErrors: [WorkflowType: String] = [:]

    private var installedLocalModels: [LocalTranscriptionModel] {
        LocalTranscriptionService.installedModels()
    }

    private var localModelOptions: [LocalTranscriptionModel] {
        LocalTranscriptionService.modelOptions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // MARK: Lokaler Modus
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Sicherer Lokaler Modus")

                Toggle("Sicherer Lokaler Modus", isOn: $appState.appSettings.secureLocalModeEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: appState.appSettings.secureLocalModeEnabled) { _, newValue in
                        if newValue && !appState.selectedLocalModelIsInstalled {
                            appState.installSelectedLocalModel()
                        }
                    }

                HStack(spacing: 6) {
                    Image(systemName: appState.selectedLocalModelIsInstalled ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(appState.selectedLocalModelIsInstalled ? .green : .blue)
                    Text(appState.selectedLocalModelIsInstalled ? "\(installedLocalModels.count) lokales WhisperKit-Modell installiert." : "Das ausgewählte Modell wird beim Installieren lokal gespeichert.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("Lokales Modell")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: Binding(
                        get: { appState.selectedLocalModelName },
                        set: { appState.appSettings.selectedLocalTranscriptionModelName = $0 }
                    )) {
                        ForEach(localModelOptions) { model in
                            Text("\(model.displayName) · \(model.installStateLabel)").tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(appState.isDownloadingLocalModel)
                }

                if let progress = appState.localModelDownloadProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                        Text(appState.localModelDownloadStatusText ?? "Modell wird geladen...")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        Button(appState.localModelDownloadButtonTitle) {
                            appState.installSelectedLocalModel()
                        }
                        .controlSize(.small)
                        .disabled(appState.selectedLocalModelIsInstalled)

                        Link("Modellseite", destination: LocalTranscriptionService.modelPageURL(for: appState.selectedLocalModelName))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                }

                if let errorText = appState.localModelDownloadErrorText {
                    Text(errorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // MARK: Medien während Diktat
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Medien während Diktat")

                Toggle("Wiedergabe automatisch pausieren", isOn: $appState.appSettings.pauseMediaDuringDictation)
                    .toggleStyle(.switch)

                Text("Blitztext pausiert vor der Aufnahme nur eine aktive Wiedergabe in Spotify oder YouTube in Chrome und stellt ausschließlich diese Pause wieder her.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("YouTube in Chrome benötigt Bedienungshilfen. Spotify kann beim ersten Zugriff eine Automation-Freigabe verlangen. Fehlt eine Freigabe, läuft die Aufnahme trotzdem weiter.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if appState.appSettings.pauseMediaDuringDictation {
                    VStack(alignment: .leading, spacing: 6) {
                        if !appState.accessibilityPermissionGranted {
                            Button("Bedienungshilfen öffnen") {
                                appState.requestAccessibilityPermission()
                            }
                            .buttonStyle(SubtleButtonStyle())
                        }

                        Button("Spotify-Automation öffnen") {
                            AccessibilityPermissionService.openAutomationSystemSettings()
                        }
                        .buttonStyle(SubtleButtonStyle())
                    }
                }
            }

            // MARK: Tastenkuerzel
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Tastenk\u{00FC}rzel")

                VStack(spacing: 8) {
                    ForEach(WorkflowType.allCases) { type in
                        shortcutRow(for: type)
                    }
                }

                HStack(spacing: 8) {
                    Button("Alle Standardbelegungen") {
                        resetAllShortcuts()
                    }
                    .controlSize(.small)

                    Spacer()
                }

                Text("Escape bleibt fest zum Abbrechen reserviert. Medientasten und einzelne Tasten ohne Modifier werden nicht verwendet. Änderungen gelten sofort; laufende Aufnahmen bleiben unberührt.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Mode picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Modus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.appSettings.hotkeyMode) {
                        ForEach(HotkeyMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // MARK: Blitztext+
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext+")

                // Tone
                VStack(alignment: .leading, spacing: 8) {
                    Text("Schreibstil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.textImprovementSettings.tone) {
                        ForEach(TextImprovementSettings.TextTone.allCases) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // System Prompt
                VStack(alignment: .leading, spacing: 8) {
                    Text("Eigene Anweisung")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $appState.textImprovementSettings.systemPrompt)
                        .font(.system(size: 11))
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                        .overlay(alignment: .topLeading) {
                            if appState.textImprovementSettings.systemPrompt.isEmpty {
                                Text("z.B. \"Schreibe pr\u{00E4}gnant und ohne F\u{00FC}llw\u{00F6}rter.\"")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                // Context
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kontext")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("z.B. \"E-Mails im Bereich Unternehmensberatung\"", text: $appState.textImprovementSettings.context)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }

            // MARK: Blitztext $%&!
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext $%&!")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Eigene Anweisung")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $appState.dampfAblassenSettings.systemPrompt)
                        .font(.system(size: 11))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                        .overlay(alignment: .topLeading) {
                            if appState.dampfAblassenSettings.systemPrompt.isEmpty {
                                Text("z.B. \"Formuliere den Text sachlich und freundlich um.\"")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }

            // MARK: Blitztext :)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Blitztext :)")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Emoji-Dichte")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $appState.emojiTextSettings.emojiDensity) {
                        ForEach(EmojiTextSettings.EmojiDensity.allCases) { density in
                            Text(density.displayName).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // MARK: Eigennamen
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Eigennamen")

                // Term chips
                if !appState.textImprovementSettings.customTerms.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(appState.textImprovementSettings.customTerms, id: \.self) { term in
                            HStack(spacing: 3) {
                                Text(term)
                                    .font(.system(size: 10.5))
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        appState.textImprovementSettings.customTerms.removeAll { $0 == term }
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(SubtleButtonStyle())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
                            )
                        }
                    }
                }

                HStack(spacing: 6) {
                    TextField("Neuer Begriff", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { addTerm() }

                    Button { addTerm() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue.opacity(0.7))
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

        }
        .padding(16)
        .onDisappear {
            appState.setShortcutCaptureActive(false)
            recordingWorkflow = nil
        }
    }

    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !appState.textImprovementSettings.customTerms.contains(trimmed) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            appState.textImprovementSettings.customTerms.append(trimmed)
        }
        newTerm = ""
    }

    private func shortcutRow(for type: WorkflowType) -> some View {
        let binding = appState.shortcutBinding(for: type)
        let isRecording = recordingWorkflow == type
        let anotherWorkflowIsRecording = recordingWorkflow != nil && !isRecording

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: type.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(type == .localTranscription ? .green : .secondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.displayName(for: type))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(appState.workflowSubtitle(for: type))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 8) {
                Text("Tastenkürzel")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .leading)

                ZStack(alignment: .leading) {
                    if !isRecording {
                        HotkeyBadge(label: binding.displayLabel, enabled: binding.isEnabled)
                            .padding(.leading, 7)
                            .allowsHitTesting(false)
                    }

                    ShortcutRecorderField(
                        binding: binding,
                        isRecording: isRecording,
                        onBegin: { beginShortcutRecording(for: type) },
                        onFinish: { candidate, captureError in
                            finishShortcutRecording(
                                for: type,
                                candidate: candidate,
                                captureError: captureError
                            )
                        }
                    )
                    .opacity(isRecording ? 1 : 0.01)
                    .accessibilityLabel("Tastenkürzel für \(appState.displayName(for: type))")
                }
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)

                Toggle(
                    "Aktiv",
                    isOn: Binding(
                        get: { appState.shortcutBinding(for: type).isEnabled },
                        set: { isEnabled in
                            updateShortcutEnabled(for: type, isEnabled: isEnabled)
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Tastenkürzel aktivieren oder deaktivieren")
            }

            HStack(spacing: 8) {
                Button(isRecording ? "Abbrechen" : "Ändern") {
                    if isRecording {
                        cancelShortcutRecording(for: type)
                    } else {
                        _ = beginShortcutRecording(for: type)
                    }
                }
                .buttonStyle(SubtleButtonStyle())
                .foregroundStyle(isRecording ? .orange : .blue)
                .disabled(anotherWorkflowIsRecording)

                Button {
                    resetShortcut(for: type)
                } label: {
                    Text("Zurücksetzen")
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(isRecording || anotherWorkflowIsRecording)

                Spacer(minLength: 0)
            }

            Group {
                if let errorText = shortcutErrors[type] {
                    Text(errorText)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(" ")
                        .font(.system(size: 10))
                        .foregroundStyle(.clear)
                }
            }
            .frame(minHeight: 15, alignment: .top)
            .padding(.leading, 30)
            .accessibilityHidden(shortcutErrors[type] == nil)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(isRecording ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isRecording ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07),
                    lineWidth: isRecording ? 1.2 : 0.5
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isRecording)
    }

    private func beginShortcutRecording(for type: WorkflowType) -> Bool {
        guard recordingWorkflow == nil || recordingWorkflow == type else { return false }
        recordingWorkflow = type
        shortcutErrors[type] = nil
        appState.setShortcutCaptureActive(true)
        return true
    }

    private func cancelShortcutRecording(for type: WorkflowType) {
        guard recordingWorkflow == type else { return }

        appState.setShortcutCaptureActive(false)
        recordingWorkflow = nil
        shortcutErrors[type] = nil
    }

    private func finishShortcutRecording(
        for type: WorkflowType,
        candidate: ShortcutBinding?,
        captureError: ShortcutConfigurationError?
    ) {
        guard recordingWorkflow == type else { return }

        appState.setShortcutCaptureActive(false)
        recordingWorkflow = nil

        if let captureError {
            shortcutErrors[type] = captureError.localizedDescription
            return
        }

        guard let candidate else { return }

        switch appState.updateShortcut(for: type, binding: candidate) {
        case .applied:
            shortcutErrors[type] = nil
        case .rejected(let error):
            shortcutErrors[type] = error.localizedDescription
        }
    }

    private func updateShortcutEnabled(for type: WorkflowType, isEnabled: Bool) {
        switch appState.setShortcutEnabled(for: type, isEnabled: isEnabled) {
        case .applied:
            shortcutErrors[type] = nil
        case .rejected(let error):
            shortcutErrors[type] = error.localizedDescription
        }
    }

    private func resetShortcut(for type: WorkflowType) {
        guard recordingWorkflow == nil else { return }

        switch appState.resetShortcut(for: type) {
        case .applied:
            shortcutErrors[type] = nil
        case .rejected(let error):
            shortcutErrors[type] = error.localizedDescription
        }
    }

    private func resetAllShortcuts() {
        guard recordingWorkflow == nil else { return }

        switch appState.resetAllShortcuts() {
        case .applied:
            shortcutErrors.removeAll()
        case .rejected(let error):
            for type in WorkflowType.allCases {
                shortcutErrors[type] = error.localizedDescription
            }
        }
    }
}

// MARK: - Shortcut Recorder

private struct ShortcutRecorderField: NSViewRepresentable {
    let binding: ShortcutBinding
    let isRecording: Bool
    let onBegin: () -> Bool
    let onFinish: (ShortcutBinding?, ShortcutConfigurationError?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.update(
            binding: binding,
            isRecording: isRecording,
            onBegin: onBegin,
            onFinish: onFinish
        )
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.update(
            binding: binding,
            isRecording: isRecording,
            onBegin: onBegin,
            onFinish: onFinish
        )
    }
}

private final class ShortcutRecorderNSView: NSView {
    private var displayedBinding = ShortcutBinding(isEnabled: false)
    private var isCapturing = false
    private var pendingKeyCode: UInt16?
    private var pendingKeyLabel: String?
    private var pendingModifiers: NSEvent.ModifierFlags = []
    private var capturedModifiers: NSEvent.ModifierFlags = []
    private var systemDefinedMonitor: Any?

    private var onBegin: (() -> Bool)?
    private var onFinish: ((ShortcutBinding?, ShortcutConfigurationError?) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let systemDefinedMonitor {
            NSEvent.removeMonitor(systemDefinedMonitor)
            self.systemDefinedMonitor = nil
        }

        guard window != nil else { return }
        systemDefinedMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, self.isCapturing else { return event }
            self.finish(candidate: nil, error: .unsupportedKey)
            return nil
        }
    }

    deinit {
        if let systemDefinedMonitor {
            NSEvent.removeMonitor(systemDefinedMonitor)
        }
    }

    func update(
        binding: ShortcutBinding,
        isRecording: Bool,
        onBegin: @escaping () -> Bool,
        onFinish: @escaping (ShortcutBinding?, ShortcutConfigurationError?) -> Void
    ) {
        displayedBinding = binding
        self.onBegin = onBegin
        self.onFinish = onFinish

        if isRecording, !isCapturing {
            beginCapture()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCapturing else { return }
                self.window?.makeFirstResponder(self)
            }
        } else if !isRecording, isCapturing {
            endCapture()
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard onBegin?() ?? false else { return }
        window?.makeFirstResponder(self)
        beginCapture()
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else { return }

        if event.keyCode == 53 {
            finish(candidate: nil, error: nil)
            return
        }

        guard !event.isARepeat else { return }
        guard ShortcutConfiguration.isSupportedStandardKey(for: event) else {
            finish(candidate: nil, error: .unsupportedKey)
            return
        }

        pendingKeyCode = event.keyCode
        pendingKeyLabel = ShortcutConfiguration.keyLabel(for: event)
        pendingModifiers = event.modifierFlags.intersection(ShortcutConfiguration.workflowModifierMask)
    }

    override func keyUp(with event: NSEvent) {
        guard isCapturing,
              let pendingKeyCode,
              pendingKeyCode == event.keyCode else {
            return
        }

        let candidate = ShortcutBinding(
            keyCode: pendingKeyCode,
            modifiers: pendingModifiers,
            keyLabel: pendingKeyLabel,
            isEnabled: true
        )
        finish(candidate: candidate, error: ShortcutConfiguration.validationError(for: candidate))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCapturing, pendingKeyCode == nil else { return }

        let flags = event.modifierFlags.intersection(ShortcutConfiguration.workflowModifierMask)
        if flags.isEmpty {
            guard !capturedModifiers.isEmpty else { return }
            let candidate = ShortcutBinding(modifiers: capturedModifiers, isEnabled: true)
            finish(candidate: candidate, error: ShortcutConfiguration.validationError(for: candidate))
        } else {
            capturedModifiers.formUnion(flags)
        }
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        pendingKeyCode = nil
        pendingKeyLabel = nil
        pendingModifiers = []
        capturedModifiers = []
        needsDisplay = true
    }

    private func endCapture() {
        isCapturing = false
        pendingKeyCode = nil
        pendingKeyLabel = nil
        pendingModifiers = []
        capturedModifiers = []
        needsDisplay = true
    }

    private func finish(candidate: ShortcutBinding?, error: ShortcutConfigurationError?) {
        guard isCapturing else { return }
        endCapture()
        onFinish?(candidate, error)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        (isCapturing ? NSColor.selectedControlColor : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isCapturing ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isCapturing ? 1.5 : 0.5
        path.stroke()

        let title = isCapturing ? "Kombination drücken …" : displayedBinding.displayLabel
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let color = isCapturing ? NSColor.controlTextColor : NSColor.secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let textSize = title.size(withAttributes: attributes)
        let point = CGPoint(
            x: max(bounds.midX - textSize.width / 2, 6),
            y: bounds.midY - textSize.height / 2
        )
        title.draw(at: point, withAttributes: attributes)
    }
}

// MARK: - Flow Layout (for term tags)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
