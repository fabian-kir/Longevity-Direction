import SwiftUI

/// An AI action waiting on the user's answer in `AIConsentSheet`.
struct AIConsentRequest: Identifiable {
    let id = UUID()
    var onAllow: () -> Void = {}
    var onNotNow: () -> Void = {}
}

extension View {
    /// Presents the AI sharing sheet for a pending request.
    func aiConsentSheet(_ request: Binding<AIConsentRequest?>) -> some View {
        sheet(item: request) { request in
            AIConsentSheet(onAllow: request.onAllow, onNotNow: request.onNotNow)
        }
    }
}

/// Asks before anything is sent to OpenRouter. Every line here must stay true
/// to what `OpenRouterClient` actually sends; when that changes, update this
/// copy and bump `AIDataConsent.latestVersion` so users are asked again.
struct AIConsentSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var onAllow: () -> Void = {}
    var onNotNow: () -> Void = {}

    /// Set once a button is tapped, so swiping the sheet away counts as "Not now".
    @State private var answered = false

    private static let privacyPolicy = URL(string: "https://openrouter.ai/privacy")!

    private var isGranted: Bool { services.openRouter.consent.isGranted }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Some features use an AI service outside this app.")
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    item("camera", "Meal photos, when you log a meal by photo.")
                    item("dumbbell", "Exercise names, when an exercise gets an icon or muscle groups.")
                } header: {
                    Text("What gets sent")
                } footer: {
                    Text("Photos are resized and sent without location data.")
                }

                Section("Who gets it") {
                    Text("OpenRouter, which passes each request to an AI model provider it picks. Requests are billed to your own API key under OpenRouter’s terms.")
                    Link(destination: Self.privacyPolicy) {
                        Label("OpenRouter privacy policy", systemImage: "arrow.up.right.square")
                    }
                }

                Section("Never leaves this iPhone") {
                    stays("Apple Health data")
                    stays("Bloodwork")
                    stays("Symptom logs and Digestion Insights")
                }

                Section {
                    item("barcode", "Barcode numbers and food-search text are looked up in Open Food Facts.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("You can change this later in Settings.")
                }
            }
            .navigationTitle("Sharing with AI")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom) { buttons }
        }
        .onDisappear {
            if !answered { onNotNow() }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 8) {
            if isGranted {
                Button {
                    answered = true
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button {
                    answered = true
                    services.allowAISharing()
                    dismiss()
                    onAllow()
                } label: {
                    Text("Allow")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.glassProminent)

                Button {
                    answered = true
                    dismiss()
                    onNotNow()
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
    }

    private func item(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }

    private func stays(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
