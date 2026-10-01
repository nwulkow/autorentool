import SwiftUI

/// Settings → Backups: every book version that a save, sync, rename or
/// delete replaced (`BackupStore`). Restoring always creates a *new* book
/// ("<title> (restored <date>)"), so it can never overwrite anything either.
struct BackupsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var groups: [BackupStore.BookBackups] = []
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("Every version that a save, sync, rename or delete would replace is kept here. Restoring creates a new book and never overwrites anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if groups.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section(group.base) {
                    ForEach(group.snapshots) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                                Text("\(String(localized: String.LocalizationValue(snapshot.reason))) · \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.size), countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore as copy") { restore(snapshot) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Backups")
        .onAppear { groups = BackupStore.bookBackups() }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func restore(_ snapshot: BackupStore.Snapshot) {
        guard let data = try? Data(contentsOf: snapshot.url),
              var book = try? JSONDecoder().decode(Book.self, from: data) else {
            message = String(localized: "This backup is not a readable book.")
            return
        }
        let stamp = snapshot.date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        book.title = "\(book.title) (restored \(stamp))"
        guard env.bookStore.load(filename: book.filename) == nil else {
            message = String(localized: "Already restored.")
            return
        }
        env.bookStore.save(book)
        message = String(localized: "Restored as “\(book.title)”")
    }
}
