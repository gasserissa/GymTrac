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

// MARK: - ContentView
struct ContentView: View {
    @AppStorage("appTitle") private var appTitle: String = "Sessions Tracker" // Editable title
    @State private var sessions: [Session] = []
    @State private var note: String = ""
    @State private var editing: Session? = nil
    @State private var showResetAlert = false
    @State private var showTitleEdit = false
    @State private var lastActionSession: Session? = nil
    @State private var lastActionWasAdd = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.08)
                    .ignoresSafeArea()
                    .onTapGesture { hideKeyboard() }

                VStack(spacing: 14) {
                    // Title
                    HStack {
                        Text(appTitle)
                            .font(.largeTitle).bold()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        Button {
                            showTitleEdit = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                    .padding(.horizontal)

                    // Summary
                    SummaryCard(sessions: sessions)

                    // History
                    HistoryList(
                        sessions: $sessions,
                        onDeleteOffsets: deleteSessionOffsets,
                        onEdit: { s in editing = s },
                        onDeleteSingle: deleteSingle
                    )

                    Spacer()

                    // Notes field
                    TextField("Notes (optional)", text: $note, axis: .vertical)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.15)))
                        .padding(.horizontal)
                        .submitLabel(.done)
                        .onSubmit {
                            addSession()
                            hideKeyboard()
                        }
                }

                // Undo button (bottom left)
                VStack {
                    Spacer()
                    HStack {
                        if lastActionSession != nil {
                            Button {
                                undoLastAction()
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                                    .background(Circle().fill(Color.blue))
                            }
                            .padding(.leading, 20)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 80) // Above the + button
                }
            }
            .navigationBarHidden(false)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showResetAlert = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(.red)
                    }
                }
            }
            .alert("Reset All History?", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    sessions.removeAll()
                    saveSessions()
                }
            } message: {
                Text("This will permanently delete all logged sessions.")
            }
            .sheet(isPresented: $showTitleEdit) {
                EditTitleSheet(title: $appTitle)
            }
            .onAppear(perform: loadSessions)

            // + Button
            .safeAreaInset(edge: .bottom) {
                Button(action: {
                    addSession()
                    hideKeyboard()
                }) {
                    Text("+")
                        .font(.title).bold()
                        .foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .background(Circle().fill(Color.red))
                        .shadow(radius: 4)
                }
                .padding(.bottom, 8)
            }

            // Edit sheet
            .sheet(item: $editing) { s in
                EditSessionSheet(session: s) { updated in
                    if let idx = sessions.firstIndex(where: { $0.id == updated.id }) {
                        sessions[idx] = updated
                        saveSessions()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.red)
    }

    // MARK: - Actions
    func addSession() {
        let new = Session(date: Date(), note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        sessions.insert(new, at: 0)
        lastActionSession = new
        lastActionWasAdd = true
        note = ""
        saveSessions()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func deleteSessionOffsets(_ offsets: IndexSet) {
        if let first = offsets.first {
            lastActionSession = sessions[first]
            lastActionWasAdd = false
        }
        sessions.remove(atOffsets: offsets)
        saveSessions()
    }

    func deleteSingle(_ session: Session) {
        if let idx = sessions.firstIndex(of: session) {
            lastActionSession = sessions[idx]
            lastActionWasAdd = false
            sessions.remove(at: idx)
            saveSessions()
        }
    }

    func undoLastAction() {
        guard let last = lastActionSession else { return }
        if lastActionWasAdd {
            sessions.removeAll { $0.id == last.id }
        } else {
            sessions.insert(last, at: 0)
        }
        lastActionSession = nil
        saveSessions()
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

// MARK: - Summary Card with extra stats
struct SummaryCard: View {
    let sessions: [Session]
    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let todayCount = sessions.filter { Calendar.current.isDate($0.date, inSameDayAs: today) }.count
        let weekCount = sessions.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .weekOfYear) }.count
        let monthCount = sessions.filter { Calendar.current.isDate($0.date, equalTo: Date(), toGranularity: .month) }.count

        return VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline)
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
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal)
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).opacity(0.85)
            Text("\(value)").font(.title2).bold()
        }
    }
}

// MARK: - History List
struct HistoryList: View {
    @Binding var sessions: [Session]
    var onDeleteOffsets: (IndexSet) -> Void
    var onEdit: (Session) -> Void
    var onDeleteSingle: (Session) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline).padding(.horizontal)

            if sessions.isEmpty {
                Text("No sessions yet. Tap “+” to add.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            } else {
                List {
                    ForEach(sessions) { s in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.date.formatted(date: .abbreviated, time: .shortened)).bold()
                                if !s.note.isEmpty {
                                    Text(s.note).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            HStack(spacing: 12) {
                                Button { onEdit(s) } label: {
                                    Image(systemName: "pencil")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) { onDeleteSingle(s) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .listRowBackground(Color(white: 0.12))
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
                .frame(maxHeight: 360)
                .background(Color.clear)
            }
        }
    }
}

// MARK: - Edit Session Sheet
struct EditSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    var session: Session
    var onSave: (Session) -> Void

    @State private var date: Date
    @State private var note: String

    init(session: Session, onSave: @escaping (Session) -> Void) {
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
                        onSave(Session(id: session.id, date: date, note: note))
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

// MARK: - Edit Title Sheet
struct EditTitleSheet: View {
    @Binding var title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("App Title", text: $title)
            }
            .navigationTitle("Edit Title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}

