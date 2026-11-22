import SwiftUI
import SwiftData

struct ExerciseLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseDef.name) private var exercises: [ExerciseDef]

    @State private var showAddSheet = false

    var body: some View {
        List {
            ForEach(exercises) { exercise in
                NavigationLink {
                    AddEditExerciseView(existing: exercise)
                } label: {
                    ExerciseDefRow(def: exercise)
                }
            }
            .onDelete { offsets in
                for i in offsets { context.delete(exercises[i]) }
                try? context.save()
            }
        }
        .navigationTitle("Exercises")
        .overlay {
            if exercises.isEmpty {
                ContentUnavailableView(
                    "No exercises",
                    systemImage: "dumbbell",
                    description: Text("Tap + to add your first exercise.")
                )
            }
        }
        .toolbar {
            // Both on the trailing side: this screen is pushed, so the
            // leading slot belongs to the back button.
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(exercises.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add exercise")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                AddEditExerciseView()
            }
        }
    }
}

// MARK: - Shared row

struct ExerciseDefRow: View {
    let def: ExerciseDef

    var body: some View {
        HStack(spacing: 12) {
            if let data = def.photoData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: def.sfSymbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(AppTab.train.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(AppTab.train.tint.opacity(0.16), lineWidth: 0.75)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(def.name)
                if !def.primaryMuscles.isEmpty {
                    Text(def.primaryMuscles.map(\.displayName).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
