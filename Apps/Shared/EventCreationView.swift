import EventKit
import Foundation
import SwiftUI

struct EventCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var errorMessage: String?
    @State private var isSaving = false
    private let store = EKEventStore()

    init(text: String) {
        _title = State(initialValue: text)
        let detected = Self.detectDate(in: text)
        _start = State(initialValue: detected)
        _end = State(initialValue: detected.addingTimeInterval(3_600))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Event title", text: $title)
                DatePicker("Starts", selection: $start)
                DatePicker("Ends", selection: $end, in: start...)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Add to Calendar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Event") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start || isSaving)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 280)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let granted = try await store.requestWriteOnlyAccessToEvents()
            guard granted, let calendar = store.defaultCalendarForNewEvents else {
                errorMessage = "Calendar access isn't available. Check permission in Settings."
                return
            }
            let event = EKEvent(eventStore: store)
            event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            event.startDate = start
            event.endDate = end
            event.calendar = calendar
            try store.save(event, span: .thisEvent)
            dismiss()
        } catch { errorMessage = "Couldn't add this event. Please try again." }
    }

    private static func detectDate(in text: String) -> Date {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let result = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let date = result.date, date > .now { return date }
        let lower = text.lowercased()
        let base = lower.contains("tomorrow") ? Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now : .now
        let pattern = #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#
        if let range = lower.range(of: pattern, options: .regularExpression) {
            let match = String(lower[range])
            let digits = match.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if let hourText = digits.first, let rawHour = Int(hourText), rawHour <= 12 {
                let hour = (rawHour % 12) + (match.contains("pm") ? 12 : 0)
                let minute = digits.count > 1 ? Int(digits[1]) ?? 0 : 0
                if let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base) { return date }
            }
        }
        return Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    }
}
