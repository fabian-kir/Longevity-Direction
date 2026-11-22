import SwiftUI

struct DigestionOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    let onStart: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "heart.text.clipboard")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Finds ingredients your symptoms tend to follow, and roughly how long after eating.")
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section("What it can't do") {
                    limit("It can't diagnose anything.")
                    limit("It can't see effects that build up over days or weeks.")
                    limit("It can't tell apart foods you always eat together.")
                    limit("It doesn't replace a doctor.")
                    Text("Results are statistics. AI meal recognition makes mistakes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("What it needs from you") {
                    need("Log every symptom. A day without an entry counts as a good day.")
                    need("Log your meals, including snacks and drinks.")
                    need("Fix the meal time if you log a meal later.")
                    need("Check detected allergens on meals you cooked.")
                    need("Expect weeks to months, not days.")
                }
                Section {
                    Label {
                        Text("Talk to your doctor before changing your diet based on these results.")
                            .font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "stethoscope")
                            .foregroundStyle(.tint)
                    }
                }
                Section {
                    NavigationLink("How this works") { DigestionHowItWorksView() }
                }
            }
            .navigationTitle("Digestion Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                Button {
                    onStart()
                    dismiss()
                } label: {
                    Text("Start tracking")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal)
                .padding(.vertical, 9)
            }
        }
    }

    private func limit(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private func need(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        }
    }
}
