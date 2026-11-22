import SwiftUI

/// A form row with a whole-number field, where 0 shows as empty.
/// Writes on every keystroke, so closing a sheet never drops a value being typed.
struct WholeNumberFieldRow: View {
    let title: String
    let unit: String
    let placeholder: String
    @Binding var value: Double

    @State private var text = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 90)
                .onChange(of: text) { _, newText in
                    value = Double(newText.filter(\.isNumber)) ?? 0
                }
            // Hidden while empty, so a placeholder such as "Off" doesn't read "Off kcal".
            if !text.isEmpty {
                Text(unit)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            text = value > 0 ? String(Int(value.rounded())) : ""
        }
    }
}
