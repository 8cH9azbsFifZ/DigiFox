/// Winlink Nachrichten-Composer — Neue Nachricht verfassen.
///
/// SwiftUI-View zum Erstellen und Senden von Winlink-E-Mails.
/// Unterstützt To, CC, Subject, Body und Anhänge.

import SwiftUI

struct ComposeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var to: String = ""
    @State private var cc: String = ""
    @State private var subject: String = ""
    @State private var messageBody: String = ""
    @State private var attachments: [WinlinkAttachment] = []
    @State private var showingAttachmentPicker = false
    @State private var isSending = false
    @State private var errorMessage: String?

    /// Optional: Vorausgefüllte Antwort
    var replyTo: WinlinkMessage?

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Empfänger
                Section(header: Text("Empfänger")) {
                    HStack {
                        Text("An:")
                            .foregroundColor(.secondary)
                            .frame(width: 30, alignment: .leading)
                        TextField("Callsign@winlink.org oder E-Mail", text: $to)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                    }
                    HStack {
                        Text("CC:")
                            .foregroundColor(.secondary)
                            .frame(width: 30, alignment: .leading)
                        TextField("Optional", text: $cc)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                    }
                }

                // MARK: - Betreff
                Section(header: Text("Betreff")) {
                    TextField("Betreff eingeben", text: $subject)
                }

                // MARK: - Nachrichtentext
                Section(header: Text("Nachricht")) {
                    TextEditor(text: $messageBody)
                        .frame(minHeight: 200)
                }

                // MARK: - Anhänge
                Section(header: Text("Anhänge (\(attachments.count))")) {
                    ForEach(attachments) { attachment in
                        HStack {
                            Image(systemName: iconForMimeType(attachment.mimeType))
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(attachment.filename)
                                    .font(.footnote)
                                Text(attachment.sizeFormatted)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: { removeAttachment(attachment) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    Button(action: { showingAttachmentPicker = true }) {
                        Label("Anhang hinzufügen", systemImage: "paperclip")
                    }
                }

                // MARK: - Fehler
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Neue Nachricht")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: sendMessage) {
                        if isSending {
                            ProgressView()
                        } else {
                            Label("Senden", systemImage: "paperplane")
                        }
                    }
                    .disabled(!isValid || isSending)
                }
            }
        }
        .onAppear {
            prefillReply()
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !to.isEmpty && !subject.isEmpty && !messageBody.isEmpty
    }

    // MARK: - Actions

    private func sendMessage() {
        guard let account = WinlinkAccountManager.shared.loadAccount(),
              account.isConfigured else {
            errorMessage = "Bitte zuerst Winlink-Konto in den Einstellungen konfigurieren."
            return
        }

        isSending = true
        errorMessage = nil

        let message = WinlinkMessage(
            messageId: WinlinkMessage.generateId(callsign: account.callsign),
            from: account.winlinkEmail,
            to: to,
            cc: cc.isEmpty ? nil : cc,
            subject: subject,
            body: messageBody,
            date: Date(),
            mimeType: "text/plain",
            folder: .outbox,
            attachments: attachments,
            isRead: true,
            rawData: Data()
        )

        // In Postausgang speichern
        WinlinkMailbox.shared.storeOutbox(message: message)

        isSending = false
        dismiss()
    }

    private func prefillReply() {
        guard let reply = replyTo else { return }
        to = reply.from
        subject = reply.subject.hasPrefix("Re:") ? reply.subject : "Re: \(reply.subject)"
        messageBody = "\n\n--- Originalangabe von \(reply.from) ---\n\(reply.body)"
    }

    private func removeAttachment(_ attachment: WinlinkAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    private func iconForMimeType(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("text/") { return "doc.text" }
        if mime.contains("pdf") { return "doc.richtext" }
        return "doc"
    }
}
