/// Winlink Nachrichten-Übersicht und Detailansicht.
///
/// Zeigt Inbox, Outbox, Sent und Archiv mit Nachrichten an.
/// Ermöglicht Lesen, Antworten, Archivieren und Löschen.

import SwiftUI

// MARK: - Message List View

struct MessageListView: View {
    @State private var selectedFolder: WinlinkFolder = .inbox
    @State private var messages: [WinlinkMessage] = []
    @State private var showingCompose = false
    @State private var selectedMessage: WinlinkMessage?

    private let mailbox = WinlinkMailbox.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // MARK: - Ordner-Tabs
                Picker("Ordner", selection: $selectedFolder) {
                    ForEach(WinlinkFolder.allCases, id: \.self) { folder in
                        Label(folder.rawValue, systemImage: folder.systemImage)
                            .tag(folder)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 4)

                // MARK: - Nachrichtenliste
                if messages.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: selectedFolder.systemImage)
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Keine Nachrichten")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(emptyText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding()
                } else {
                    List {
                        ForEach(messages) { message in
                            MessageRow(message: message)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedMessage = message
                                    if !message.isRead && message.folder == .inbox {
                                        mailbox.markRead(messageId: message.messageId)
                                    }
                                }
                        }
                        .onDelete { indexSet in
                            deleteMessages(at: indexSet)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Winlink Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingCompose = true }) {
                        Image(systemName: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: refreshMessages) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showingCompose) {
                ComposeView()
            }
            .sheet(item: $selectedMessage) { message in
                MessageDetailView(message: message)
            }
            .onChange(of: selectedFolder) { _ in
                refreshMessages()
            }
            .onAppear {
                refreshMessages()
            }
        }
    }

    private var emptyText: String {
        switch selectedFolder {
        case .inbox: return "Verbinden Sie sich mit einem\nRMS-Gateway um Nachrichten abzurufen."
        case .outbox: return "Verfassen Sie eine Nachricht\nzum Senden."
        case .sent: return "Gesendete Nachrichten\nerscheinen hier."
        case .archive: return "Archivierte Nachrichten\nerscheinen hier."
        }
    }

    private func refreshMessages() {
        messages = mailbox.messages(in: selectedFolder)
    }

    private func deleteMessages(at offsets: IndexSet) {
        for index in offsets {
            let msg = messages[index]
            mailbox.delete(messageId: msg.messageId, folder: selectedFolder)
        }
        refreshMessages()
    }
}

// MARK: - Message Row

struct MessageRow: View {
    let message: WinlinkMessage

    var body: some View {
        HStack(spacing: 8) {
            // Unread indicator
            Circle()
                .fill(message.isRead ? Color.clear : Color.blue)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(displayName)
                        .font(.subheadline)
                        .fontWeight(message.isRead ? .regular : .bold)
                        .lineLimit(1)

                    Spacer()

                    Text(formattedDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(message.subject)
                    .font(.footnote)
                    .fontWeight(message.isRead ? .regular : .semibold)
                    .lineLimit(1)

                Text(message.body.prefix(80).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if !message.attachments.isEmpty {
                Image(systemName: "paperclip")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        message.folder == .sent || message.folder == .outbox
            ? message.to
            : message.from
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(message.date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(message.date) {
            return "Gestern"
        } else {
            formatter.dateFormat = "dd.MM.yy"
        }
        return formatter.string(from: message.date)
    }
}

// MARK: - Message Detail View

struct MessageDetailView: View {
    let message: WinlinkMessage
    @Environment(\.dismiss) private var dismiss
    @State private var showingReply = false
    @State private var showingArchiveConfirm = false

    private let mailbox = WinlinkMailbox.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // MARK: - Header
                    Group {
                        headerRow("Von:", value: message.from)
                        headerRow("An:", value: message.to)
                        if let cc = message.cc, !cc.isEmpty {
                            headerRow("CC:", value: cc)
                        }
                        headerRow("Datum:", value: fullDateString)
                        headerRow("Betreff:", value: message.subject)
                    }
                    .padding(.horizontal)

                    Divider()

                    // MARK: - Body
                    Text(message.body)
                        .font(.body)
                        .padding(.horizontal)
                        .textSelection(.enabled)

                    // MARK: - Anhänge
                    if !message.attachments.isEmpty {
                        Divider()
                        Section {
                            ForEach(message.attachments) { attachment in
                                HStack {
                                    Image(systemName: "paperclip")
                                        .foregroundColor(.blue)
                                    Text(attachment.filename)
                                        .font(.footnote)
                                    Spacer()
                                    Text(attachment.sizeFormatted)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Nachricht")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(action: { showingReply = true }) {
                        Label("Antworten", systemImage: "arrowshape.turn.up.left")
                    }

                    Spacer()

                    Button(action: archiveMessage) {
                        Label("Archivieren", systemImage: "archivebox")
                    }

                    Spacer()

                    Button(role: .destructive, action: deleteMessage) {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }
            .sheet(isPresented: $showingReply) {
                ComposeView(replyTo: message)
            }
        }
    }

    private func headerRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss 'UTC'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: message.date)
    }

    private func archiveMessage() {
        mailbox.archive(messageId: message.messageId, from: message.folder)
        dismiss()
    }

    private func deleteMessage() {
        mailbox.delete(messageId: message.messageId, folder: message.folder)
        dismiss()
    }
}
