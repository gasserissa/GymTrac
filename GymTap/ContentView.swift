import SwiftUI

// MARK: - Helpers
extension View {
    /// Dismisses the keyboard from anywhere in SwiftUI
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

/// Localized string in a specific locale (uses your in-app language)
func L10N(_ key: String, _ locale: Locale) -> String {
    if let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }
    return NSLocalizedString(key, comment: "")
}

/// Time only, honoring AM/PM overrides from Localizable.strings (keys: "am_symbol", "pm_symbol")
private func localizedTime(_ date: Date, locale: Locale) -> String {
    let df = DateFormatter()
    df.locale = locale
    df.dateStyle = .none
    df.timeStyle = .short
    let am = L10N("am_symbol", locale)
    let pm = L10N("pm_symbol", locale)
    if am != "am_symbol" { df.amSymbol = am }
    if pm != "pm_symbol" { df.pmSymbol = pm }
    return df.string(from: date)
}

/// Build ET text as a plain String (keeps SwiftUI view-builder happy)
private func buildETText(start: Date, end: Date, locale: Locale) -> String {
    let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
    if sameDay {
        return "ET: " + localizedTime(end, locale: locale)
    } else {
        let datePart = end.formatted(date: .abbreviated, time: .omitted)
        let timePart = localizedTime(end, locale: locale)
        return "ET: " + datePart + ", " + timePart
    }
}

// MARK: - Model
struct Session: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date                  // start time
    var note: String
    var endDate: Date? = nil        // optional end time
}

// MARK: - Undo stack
fileprivate struct RemovedItem: Equatable {
    let session: Session
    let index: Int
}
fileprivate enum UndoOp: Equatable {
    case added(Session)
    case deleted([RemovedItem])
    case edited(before: Session, index: Int)
}

// MARK: - ContentView
struct ContentView: View {
    @AppStorage("appTitle") private var appTitle: String = "Sessions Tracker"
    @AppStorage("appAppearance") private var appAppearance: String = "dark"   // "light"|"dark"
    @AppStorage("appLanguage")  private var appLanguage: String  = "en"       // "en"|"ar"

    @State private var sessions: [Session] = []
    @State private var note: String = ""
    @State private var editing: Session? = nil
    @State private var showResetAlert = false
    @State private var showSettings = false
    @State private var undoStack: [UndoOp] = []

    private var selectedColorScheme: ColorScheme { appAppearance == "light" ? .light : .dark }
    private var selectedLocale: Locale { Locale(identifier: appLanguage) }

    // Adaptive colors
    private var appBG: Color { Color(.systemBackground) }
    private var cardBG: Color { Color(.secondarySystemBackground) }
    private var listRowBG: Color { Color(.secondarySystemBackground) }

    var body: some View {
        NavigationStack {
            ZStack {
                appBG.ignoresSafeArea()
                    .onTapGesture { hideKeyboard() }

                VStack(spacing: 14) {
                    // Title + Reset
                    HStack(spacing: 10) {
                        Text(appTitle)
                            .font(.largeTitle).bold()
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)

                        Button { showResetAlert = true } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel(Text("reset_all_history_a11y"))
                    }
                    .padding(.horizontal)

                    // Summary
                    SummaryCard(sessions: sessions, cardBG: cardBG)

                    // History
                    HistoryList(
                        sessions: $sessions,
                        onDeleteOffsets: deleteSessionOffsets,
                        onEdit: { s in editing = s },
                        onDeleteSingle: deleteSingle,
                        onEnd: endSession,
                        rowBG: listRowBG,
                        locale: selectedLocale
                    )

                    Spacer()

                    // Notes (optional)
                    TextField(LocalizedStringKey("notes_placeholder"), text: $note, axis: .vertical)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(cardBG))
                        .foregroundStyle(.primary)
                        .padding(.horizontal)
                        .submitLabel(.done)
                        .onSubmit {
                            addSession()
                            hideKeyboard()
                        }
                }
            }
            .navigationBarHidden(false)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel(Text("settings"))
                }
            }
            .alert(Text("reset_all_history_title"), isPresented: $showResetAlert) {
                Button(LocalizedStringKey("cancel"), role: .cancel) { }
                Button(LocalizedStringKey("reset"), role: .destructive) {
                    sessions.removeAll()
                    undoStack.removeAll()
                    saveSessions()
                }
            } message: {
                Text("reset_all_history_message")
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(title: $appTitle, appearance: $appAppearance, language: $appLanguage)
            }
            .onAppear(perform: loadSessions)

            // Bottom controls
            .safeAreaInset(edge: .bottom) {
                ZStack {
                    // Undo bottom-left
                    HStack {
                        Button(action: { undoLastAction() }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.title2)
                                .foregroundStyle(.primary)
                        }
                        .padding(.leading, 20)
                        .accessibilityLabel(Text("undo_a11y"))
                        Spacer()
                    }

                    // + centered
                    Button(action: {
                        addSession()
                        hideKeyboard()
                    }) {
                        Image(systemName: "plus")
                            .font(.title).bold()
                            .foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                            .background(Circle().fill(Color.red))
                            .shadow(radius: 4)
                    }
                    .accessibilityLabel(Text("log_session_a11y"))
                }
                .padding(.bottom, 8)
            }

            // Edit sheet (supports end time)
            .sheet(item: $editing) { s in
                EditSessionSheet(session: s) { updated, original in
                    if let idx = sessions.firstIndex(where: { $0.id == original.id }) {
                        undoStack.append(.edited(before: original, index: idx))
                        sessions[idx] = updated
                        saveSessions()
                    }
                }
            }
        }
        .preferredColorScheme(selectedColorScheme)
        .environment(\.locale, selectedLocale)
        .tint(.red)
    }

    // MARK: - Actions
    func addSession() {
        let new = Session(date: Date(), note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        sessions.insert(new, at: 0)
        undoStack.append(.added(new))
        note = ""
        saveSessions()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func endSession(_ session: Session) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let before = sessions[idx]
        var after = before
        after.endDate = Date()
        undoStack.append(.edited(before: before, index: idx))
        sessions[idx] = after
        saveSessions()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    func deleteSessionOffsets(_ offsets: IndexSet) {
        let removed: [RemovedItem] = offsets.sorted().map { idx in
            RemovedItem(session: sessions[idx], index: idx)
        }
        undoStack.append(.deleted(removed))
        sessions.remove(atOffsets: offsets)
        saveSessions()
    }

    func deleteSingle(_ session: Session) {
        if let idx = sessions.firstIndex(of: session) {
            undoStack.append(.deleted([RemovedItem(session: session, index: idx)]))
            sessions.remove(at: idx)
            saveSessions()
        }
    }

    func undoLastAction() {
        guard let op = undoStack.popLast() else { return }
        switch op {
        case .added(let s):
            sessions.removeAll { $0.id == s.id }
        case .deleted(let items):
            for item in items.sorted(by: { $0.index < $1.index }) {
                let i = min(item.index, sessions.count)
                sessions.insert(item.session, at: i)
            }
        case .edited(let before, let index):
            if let currentIdx = sessions.firstIndex(where: { $0.id == before.id }) {
                sessions[currentIdx] = before
            } else {
                let i = min(index, sessions.count)
                sessions.insert(before, at: i)
            }
        }
        saveSessions()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Persistence (with iCloud sync)
    func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: "sessions")
            NSUbiquitousKeyValueStore.default.set(data, forKey: "sessions")
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    func loadSessions() {
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: "sessions") ??
            UserDefaults.standard.data(forKey: "sessions"),
           let arr = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = arr
        }
    }
}

// MARK: - Duration formatting
private func formattedDuration(from start: Date, to end: Date, locale: Locale) -> String? {
    guard end >= start else { return nil }
    let f = DateComponentsFormatter()
    f.allowedUnits = [.hour, .minute]
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    f.calendar = Calendar(identifier: .gregorian)
    f.calendar?.locale = locale
    return f.string(from: start, to: end)
}

// MARK: - Summary Card
struct SummaryCard: View {
    let sessions: [Session]
    var cardBG: Color

    var body: some View {
        let todayCount = sessions.filter { Calendar.current.isDate($0.date, inSameDayAs: Date()) }.count
        let weekCount  = sessions.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }.count
        let monthCount = sessions.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }.count

        return VStack(alignment: .leading, spacing: 10) {
            Text("summary").font(.headline).foregroundStyle(.primary)
            HStack {
                StatTile(title: "total", value: sessions.count)
                Spacer()
                StatTile(title: "today", value: todayCount)
                Spacer()
                StatTile(title: "week", value: weekCount)
                Spacer()
                StatTile(title: "month", value: monthCount)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal)
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title2).bold().foregroundStyle(.primary)
        }
    }
}

// MARK: - History List
struct HistoryList: View {
    @Binding var sessions: [Session]
    var onDeleteOffsets: (IndexSet) -> Void
    var onEdit: (Session) -> Void
    var onDeleteSingle: (Session) -> Void
    var onEnd: (Session) -> Void
    var rowBG: Color
    var locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("history").font(.headline).padding(.horizontal).foregroundStyle(.primary)

            if sessions.isEmpty {
                Text("empty_history_hint")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            } else {
                List {
                    ForEach(sessions) { s in
                        HStack(alignment: .top, spacing: 12) {
                            // LEFT: content
                            VStack(alignment: .leading, spacing: 6) {

                                // Line 1: date + duration (if ET exists)
                                HStack(spacing: 8) {
                                    Text(s.date.formatted(date: .abbreviated, time: .omitted))
                                        .bold()
                                        .foregroundStyle(.primary)

                                    if let end = s.endDate,
                                       let d = formattedDuration(from: s.date, to: end, locale: locale) {
                                        Text("(\(d))")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                // Line 2: ST (and End button if no ET)
                                HStack {
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("ST: \(localizedTime(s.date, locale: locale))")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                    }
                                    Spacer()
                                    if s.endDate == nil {
                                        Button { onEnd(s) } label: {
                                            Text(LocalizedStringKey("end"))
                                                .font(.subheadline).bold()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.red)
                                        .controlSize(.mini)
                                    }
                                }

                                // Line 3: ET (single line)
                                if let end = s.endDate {
                                    let etText = buildETText(start: s.date, end: end, locale: locale)
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(etText)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                            .padding(.trailing, 2)
                                    }
                                    .padding(.top, 2)
                                }

                                // Line 4: Note
                                if !s.note.isEmpty {
                                    Text(s.note)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 8)

                            // RIGHT: actions pinned to bottom
                            VStack {
                                Spacer(minLength: 0)
                                HStack(spacing: 12) {
                                    Button { onEdit(s) } label: { Image(systemName: "pencil") }
                                        .buttonStyle(.bordered)
                                    Button(role: .destructive) { onDeleteSingle(s) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .listRowBackground(rowBG)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { onEdit(s) } label: { Image(systemName: "pencil") }.tint(.blue)
                            Button(role: .destructive) { onDeleteSingle(s) } label: { Image(systemName: "trash") }
                        }
                        .onTapGesture { onEdit(s) }
                    }
                    .onDelete(perform: onDeleteOffsets)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(.clear)
                .frame(maxHeight: 360)
            }
        }
    }
}

// MARK: - Edit Session Sheet
struct EditSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    var session: Session
    var onSave: (Session, Session) -> Void

    @State private var date: Date
    @State private var note: String
    @State private var hasEndTime: Bool
    @State private var endDate: Date

    init(session: Session, onSave: @escaping (Session, Session) -> Void) {
        self.session = session
        self.onSave = onSave
        _date = State(initialValue: session.date)
        _note = State(initialValue: session.note)
        _hasEndTime = State(initialValue: session.endDate != nil)
        _endDate = State(initialValue: session.endDate ?? session.date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(LocalizedStringKey("date_time"), selection: $date)
                    TextField(LocalizedStringKey("notes_placeholder"), text: $note, axis: .vertical)
                }
                Section {
                    Toggle(LocalizedStringKey("end_time"), isOn: $hasEndTime)
                    if hasEndTime {
                        DatePicker(LocalizedStringKey("end_time"), selection: $endDate)
                    } else if session.endDate != nil {
                        Button(role: .destructive) {
                            hasEndTime = false
                        } label: {
                            Text(LocalizedStringKey("clear_end_time"))
                        }
                    }
                }
            }
            .navigationTitle(Text("edit_session"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey("save")) {
                        var updated = Session(id: session.id, date: date, note: note)
                        updated.endDate = hasEndTime ? endDate : nil
                        onSave(updated, session)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("cancel")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Settings Sheet (Title + Appearance + Language)
struct SettingsSheet: View {
    @Binding var title: String
    @Binding var appearance: String // "light"|"dark"
    @Binding var language: String   // "en"|"ar"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(LocalizedStringKey("Title")) {
                    TextField(LocalizedStringKey("app_title"), text: $title)
                }
                Section(LocalizedStringKey("appearance")) {
                    Picker(LocalizedStringKey("mode"), selection: $appearance) {
                        Text("light").tag("light")
                        Text("dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section(LocalizedStringKey("language")) {
                    Picker(LocalizedStringKey("language"), selection: $language) {
                        Text("English").tag("en")
                        Text("العربية").tag("ar")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(Text("settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(LocalizedStringKey("done")) { dismiss() } }
                ToolbarItem(placement: .cancellationAction) { Button(LocalizedStringKey("cancel")) { dismiss() } }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
}

