import SwiftUI
import HealthKit

struct DataExportView: View {
    @Environment(AppServices.self) private var services

    @State private var exportURL: URL?
    @State private var showDeleteConfirm = false
    @State private var showExportError = false
    @State private var exportError: String?

    @State private var apiKeyInput: String = ""
    @State private var apiSaved: Bool = false
    @State private var aiConsentRequest: AIConsentRequest?

    @State private var scheduled: [NotificationManager.ScheduledNotification] = []
    @State private var scheduledLoaded = false

    @State private var showDigestionOnboarding = false
    @State private var showStopDigestionConfirm = false

    var body: some View {
        Form {
            Section("Privacy") {
                Text("Your data stays on this iPhone. No cloud sync. No analytics. No account. AI features send meal photos and exercise names to OpenRouter, only if you allow it (see below).")
                    .font(.subheadline)
            }

            Section("Apple Health") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(services.healthKit.isAvailable
                         ? (services.healthKit.authorizationRequested ? "Permissions requested" : "Not requested")
                         : "Unavailable on this device")
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Last read")
                    Spacer()
                    Text(services.healthKit.lastSyncDate.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        await services.healthKit.requestAuthorization()
                        await services.refresh()
                    }
                } label: {
                    Label("Re-check Apple Health permissions", systemImage: "heart.text.square")
                }
                if let error = services.healthKit.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("OpenRouter (nutrition AI)") {
                HStack {
                    Text("API key")
                    Spacer()
                    Text(services.openRouter.hasAPIKey ? "Set" : "Not set")
                        .foregroundStyle(services.openRouter.hasAPIKey ? .green : .secondary)
                }
                SecureField("sk-or-…", text: $apiKeyInput)
                HStack {
                    Button {
                        services.openRouter.setAPIKey(apiKeyInput)
                        apiKeyInput = ""
                        apiSaved = true
                        if !services.openRouter.consent.isGranted {
                            aiConsentRequest = AIConsentRequest()
                        }
                    } label: { Text("Save key") }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)

                    if services.openRouter.hasAPIKey {
                        Button(role: .destructive) {
                            services.openRouter.setAPIKey("")
                        } label: { Text("Remove key") }
                        .buttonStyle(.bordered)
                    }
                }
                LabeledContent("Model") {
                    Text("\(Image(systemName: "wand.and.stars")) \(HealthThresholds.OpenRouter.autoModelDisplayName)")
                }

                LabeledContent("Sharing with AI") {
                    Text(aiSharingLabel)
                        .foregroundStyle(aiSharingColor)
                }
                Button {
                    aiConsentRequest = AIConsentRequest()
                } label: {
                    Label(services.openRouter.consent.isGranted ? "What gets shared" : "Allow sharing with AI…",
                          systemImage: "sparkles")
                }
                if services.openRouter.consent.isGranted {
                    Button(role: .destructive) {
                        services.stopAISharing()
                    } label: {
                        Label("Stop sharing with AI", systemImage: "hand.raised")
                    }
                }

                if let digest = services.nutritionDigest {
                    HStack {
                        Text("Nutrition cost this month")
                        Spacer()
                        Text(String(format: "$%.4f", digest.costThisMonthUSD)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Nutrition cost all-time")
                        Spacer()
                        Text(String(format: "$%.4f", digest.costAllTimeUSD)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                let exDigest = services.exerciseImageDigest
                HStack {
                    Text("Exercise icons all-time")
                    Spacer()
                    Text(String(format: "$%.4f (%d icons)", exDigest.totalCostUSD, exDigest.defsWithGeneratedImage))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if exDigest.defsWithGeneratedImage > 0 {
                    HStack {
                        Text("Exercise icon tokens")
                        Spacer()
                        Text("\(exDigest.totalInputTokens) in · \(exDigest.totalOutputTokens) out")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Text("Get a key at openrouter.ai → top right → Keys → Create. All AI features (meal photos, muscle tagging, exercise icons) run in OpenRouter's Auto mode (\(HealthThresholds.OpenRouter.autoModel)): OpenRouter picks the model for each request, so newer models are used automatically. Costs shown are what OpenRouter actually charged. Nothing is sent until you allow sharing with AI.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let err = services.openRouter.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(notificationStatusLabel).foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        await services.notifications.requestAuthorization()
                        await reloadScheduled()
                    }
                } label: {
                    Label("Re-request permission", systemImage: "bell")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("The app reschedules these every time it refreshes priorities. Anything you don't want, mute the whole app in iOS Settings.")
            }

            Section {
                notificationTypeRow(
                    icon: "exclamationmark.circle",
                    tint: .orange,
                    title: "Priority reminders",
                    detail: "One per due item at 9:00 AM. Lookahead is 14 days for high-impact items (BP, nicotine, cardio, strength, body, sleep, bloodwork) and 7 days for the rest. Cadence tightens automatically when a high-impact metric trends the wrong way, even before status flips."
                )
                notificationTypeRow(
                    icon: "calendar",
                    tint: .blue,
                    title: "Weekly review",
                    detail: "Every Sunday at 6:00 PM, summarising what to focus on this week."
                )
                notificationTypeRow(
                    icon: "fork.knife",
                    tint: .green,
                    title: "Nutrition check",
                    detail: "8:00 PM, only on days when protein / fibre / omega-3 are off-track. Skipped if you've already logged today."
                )
            } header: {
                Text("What you'll get")
            } footer: {
                Text("Items overdue beyond their next-check date are pulled forward to today so they actually fire.")
            }

            Section {
                if !scheduledLoaded {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else if scheduled.isEmpty {
                    Text("Nothing scheduled right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scheduled) { item in
                        ScheduledNotificationRow(item: item)
                    }
                }
                Button {
                    Task { await reloadScheduled() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
            } header: {
                Text("Currently scheduled")
            } footer: {
                Text("Live from iOS. Updated when priorities refresh or when you tap Refresh above.")
            }

            Section {
                Link(destination: URL(string: "https://world.openfoodfacts.org")!) {
                    Label("Open Food Facts", systemImage: "barcode")
                }
            } header: {
                Text("Data sources")
            } footer: {
                Text("Barcode and product search data © Open Food Facts contributors, available under the Open Database License (ODbL).")
            }

            Section {
                Toggle("Track digestion", isOn: Binding(
                    get: { services.isTrackingDigestion },
                    set: { on in
                        if on { showDigestionOnboarding = true }
                        else { showStopDigestionConfirm = true }
                    }
                ))
                if services.isTrackingDigestion {
                    NavigationLink("Open Digestion Insights") {
                        DigestionInsightsView()
                    }
                }
                DigestionRunSettingsRows()
            } header: {
                Text("Digestion Insights")
            } footer: {
                Text("Optional. Looks for ingredients your symptoms tend to follow. Symptom data stays on this iPhone.")
            }

            Section("Export") {
                Button {
                    do {
                        let payload = ExportService.makePayload(store: services.store)
                        exportURL = try ExportService.writeJSON(payload)
                    } catch {
                        exportError = error.localizedDescription
                        showExportError = true
                    }
                } label: {
                    Label("Export JSON…", systemImage: "square.and.arrow.up")
                }
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Share file: \(url.lastPathComponent)", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            }

            Section("Danger zone") {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete all local data", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Settings")
        .task { await reloadScheduled() }
        .aiConsentSheet($aiConsentRequest)
        .sheet(isPresented: $showDigestionOnboarding) {
            DigestionOnboardingView { services.startDigestionTracking() }
        }
        .confirmationDialog("Stop tracking digestion?", isPresented: $showStopDigestionConfirm, titleVisibility: .visible) {
            Button("Stop tracking", role: .destructive) { services.stopDigestionTracking() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your logged symptoms stay on this iPhone. Days until you start again are not analysed.")
        }
        .alert("Delete everything?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await services.deleteAllLocalData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all manual entries, snapshots, and priority history from this device. Apple Health data is untouched.")
        }
        .alert("Export failed", isPresented: $showExportError, presenting: exportError) { _ in
            Button("OK", role: .cancel) {}
        } message: { e in
            Text(e)
        }
    }

    private var aiSharingLabel: String {
        let consent = services.openRouter.consent
        if consent.isGranted { return "Allowed" }
        if consent.needsRenewal { return "Needs your OK again" }
        return "Off"
    }

    private var aiSharingColor: Color {
        let consent = services.openRouter.consent
        if consent.isGranted { return .green }
        if consent.needsRenewal { return .orange }
        return .secondary
    }

    private func reloadScheduled() async {
        scheduled = await services.notifications.pendingNotifications()
        scheduledLoaded = true
    }

    private func notificationTypeRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(tint)
                .glassEffect(.regular.tint(tint.opacity(0.22)), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var notificationStatusLabel: String {
        switch services.notifications.authorizationStatus {
        case .authorized:    "Allowed"
        case .provisional:   "Allowed (quiet)"
        case .denied:        "Denied — change in Settings"
        case .notDetermined: "Not requested"
        case .ephemeral:     "Ephemeral"
        @unknown default:    "Unknown"
        }
    }
}

// MARK: - Scheduled notification row

private struct ScheduledNotificationRow: View {
    let item: NotificationManager.ScheduledNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kindIcon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(kindTint)
                .glassEffect(.regular.tint(kindTint.opacity(0.22)), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if let date = item.fireDate {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(fireDateLabel(date))
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(kindTint)
                    .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var kindIcon: String {
        switch item.kind {
        case .priority:      "exclamationmark.circle"
        case .weeklyReview:  "calendar"
        case .nutrition:     "fork.knife"
        case .other:         "bell"
        }
    }

    private var kindTint: Color {
        switch item.kind {
        case .priority:      .orange
        case .weeklyReview:  .blue
        case .nutrition:     .green
        case .other:         .gray
        }
    }

    private func fireDateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(date)         { day = "Today" }
        else if cal.isDateInTomorrow(date) { day = "Tomorrow" }
        else if date.timeIntervalSinceNow < 7 * 24 * 3600 {
            day = date.formatted(.dateTime.weekday(.wide))
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        }
        let time = date.formatted(.dateTime.hour().minute())
        return "\(day) · \(time)"
    }
}
