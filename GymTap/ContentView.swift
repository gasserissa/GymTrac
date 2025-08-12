import SwiftUI

// MARK: - Helpers
extension View {
    /// Dismisses the keyboard from anywhere in SwiftUI
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

// MARK: - Model
struct Session: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var note: String
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
    @AppStorage("appAppearance") private var appAppearance: String = "dark" // "light" or "dark"

    @State private var sessions: [Session] = []
    @State private var note: String = ""
    @State private var editing: Session? = nil
    @State private var showResetAlert = false
    @State private var showSettings = false
    @State private var undoStack: [UndoOp] = []

    // Map stored string -> ColorScheme
    private var selectedColorScheme: ColorScheme {
        appAppearance == "light" ? .light : .dark
    }

    // Dynamic colors (adapt automatically to light/dark)
    private var appBG: Color { Color(.systemBackground) }
    private var cardBG: Color { Color(.secondarySystemBackground) }
    private var listRowBG: Color { Color(.secondarySystemBackground) }

    var body: some View {
        NavigationStack {
            ZStack {
                appBG.ignoresSafeArea() // adaptive background
                    .onTapGesture { hideKeyboard() }

                VStack(spacing: 14) {
                    // Title row with Reset next to title
                    HStack(spacing: 10) {
                        Text(appTitle)
                            .font(.largeTitle).bold()
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)

                        Button {
                            showResetAlert = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("Reset All History")
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
                        rowBG: listRowBG
                    )

                    Spacer()

                    // Notes (optional) above the buttons
                    TextField("Notes (optional)", text: $note, axis: .vertical)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(cardBG) // adaptive field bg
                        )
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
            // Settings icon (gear) top-right
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .alert("Reset All History?", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    sessions.removeAll()
                    undoStack.removeAll()
                    saveSessions()
                }
            } message: {
                Text("This will permanently delete all logged sessions.")
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(title: $appTitle, appearance: $appAppearance)
            }
            .onAppear(perform: loadSessions)

            // Bottom controls: Undo bottom-left (icon only), + centered
            .safeAreaInset(edge: .bottom) {
                ZStack {
                    // Undo bottom-left
                    HStack {
                        Button(action: { undoLastAction() }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.title2)
                                .foregroundStyle(.primary) // adaptive icon color
                        }
                        .padding(.leading, 20)
                        .accessibilityLabel("Undo")
                        Spacer()
                    }

                    // + centered
                    Button(action: {
                        addSession()
                        hideKeyboard()
                    }) {
                        // keep white glyph for contrast on red
                        Image(systemName: "plus")
                            .font(.title).bold()
                            .foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                            .background(Circle().fill(Color.red))
                            .shadow(radius: 4)
                    }
                    .accessibilityLabel("Log Session")
                }
                .padding(.bottom, 8)
            }

            // Edit sheet (returns updated + original for undo)
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
        .preferredColorScheme(selectedColorScheme) // applies user choice
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

// MARK: - Summary Card (adaptive colors)
struct SummaryCard: View {
    let sessions: [Session]
    var cardBG: Color

    var body: some View {
        let todayCount = sessions.filter { Calendar.current.isDate($0.date, inSameDayAs: Date()) }.count
        let weekCount  = sessions.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }.count
        let monthCount = sessions.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }.count

        return VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline).foregroundStyle(.primary)
            HStack {
                StatTile(title: "Total", value: sessions.count)
                Spacer()
                StatTile(title: "Today", value: todayCount)
                Spacer()
                StatTile(title: "Week", value: weekCount)
                Spacer()
                StatTile(title: "Month", value: monthCount)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(cardBG) // adaptive
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal)
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title2).bold().foregroundStyle(.primary)
        }
    }
}

// MARK: - History List (adaptive row background)
struct HistoryList: View {
    @Binding var sessions: [Session]
    var onDeleteOffsets: (IndexSet) -> Void
    var onEdit: (Session) -> Void
    var onDeleteSingle: (Session) -> Void
    var rowBG: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline).padding(.horizontal).foregroundStyle(.primary)

            if sessions.isEmpty {
                Text("No sessions yet. Tap “+” to add.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            } else {
                List {
                    ForEach(sessions) { s in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.date.formatted(date: .abbreviated, time: .shortened))
                                    .bold()
                                    .foregroundStyle(.primary)
                                if !s.note.isEmpty {
                                    Text(s.note).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            HStack(spacing: 12) {
                                Button { onEdit(s) } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) { onDeleteSingle(s) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .listRowBackground(rowBG) // adaptive
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { onEdit(s) } label: { Image(systemName: "pencil") }.tint(.blue)
                            Button(role: .destructive) { onDeleteSingle(s) } label: { Image(systemName: "trash") }
                        }
                        .onTapGesture { onEdit(s) }
                    }
                    .onDelete(perform: onDeleteOffsets)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden) // use our own bg, not default
                .background(.clear)
                .frame(maxHeight: 360)
            }
        }
    }
}

// MARK: - Edit Session Sheet (returns updated + original for undo)
struct EditSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    var session: Session
    var onSave: (Session, Session) -> Void

    @State private var date: Date
    @State private var note: String

    init(session: Session, onSave: @escaping (Session, Session) -> Void) {
        self.session = session
        self.onSave = onSave
        _date = State(initialValue: session.date)
        _note = State(initialValue: session.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date & time", selection: $date)
                TextField("Notes (optional)", text: $note, axis: .vertical)
            }
            .navigationTitle("Edit session")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updated = Session(id: session.id, date: date, note: note)
                        onSave(updated, session)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Settings Sheet (Title + Appearance)
struct SettingsSheet: View {
    @Binding var title: String
    @Binding var appearance: String // "light" or "dark"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("App Title", text: $title)
                }
                Section("Appearance") {
                    Picker("Mode", selection: $appearance) {
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
}
//V1.2
