import SwiftUI
import UIKit

/// Meal photos saved for later analysis. Opened from the "n pending" badge on
/// the camera: shows why each one is still waiting, retries on demand and lets
/// the user drop photos they no longer want logged.
struct PendingMealsSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    private var queue: PendingMealQueue { services.pendingMeals }

    @State private var consentRequest: AIConsentRequest?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(queue.pending) { meal in
                        PendingMealRow(meal: meal)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { queue.pending[$0] }
                        for meal in doomed {
                            queue.discard(meal)
                        }
                    }
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Pending meals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if queue.isAISharingAllowed {
                        Button("Retry") {
                            Task { await queue.retryAll() }
                        }
                        .disabled(!queue.isOnline || queue.isProcessing)
                    } else {
                        // Allowing starts the queue on its own.
                        Button("Allow AI") {
                            consentRequest = AIConsentRequest()
                        }
                    }
                }
            }
            // Everything analysed or discarded: nothing left to show.
            .onChange(of: queue.pending.isEmpty) { _, isEmpty in
                if isEmpty { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .aiConsentSheet($consentRequest)
    }

    private var footer: String {
        if !queue.isAISharingAllowed {
            return "Sharing with AI is off, so these photos stay on this iPhone and aren’t analysed. Allow it to analyse them, or swipe left to discard a photo."
        }
        if !queue.isOnline {
            return "You’re offline. These photos are analysed and logged automatically when you’re back online."
        }
        return "Analysed photos are logged with the AI’s typical serving size. Swipe left to discard a photo."
    }
}

private struct PendingMealRow: View {
    @Environment(AppServices.self) private var services
    let meal: PendingMealQueue.PendingMeal
    @State private var image: UIImage?

    private var queue: PendingMealQueue { services.pendingMeals }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(meal.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.medium))
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if queue.processingID == meal.id {
                ProgressView()
            }
        }
        .task(id: meal.id) {
            image = queue.image(for: meal)
        }
    }

    @ViewBuilder
    private var status: some View {
        if queue.processingID == meal.id {
            Text("Analysing…")
        } else if !queue.isAISharingAllowed {
            Text("Waiting for sharing with AI")
        } else if !queue.isOnline {
            Text("Waiting for network")
        } else if let error = meal.lastError {
            Text(meal.attempts >= PendingMealQueue.maxAttempts
                 ? "Stopped retrying: \(error)"
                 : "Failed: \(error)")
        } else {
            Text("Waiting to be analysed")
        }
    }
}
