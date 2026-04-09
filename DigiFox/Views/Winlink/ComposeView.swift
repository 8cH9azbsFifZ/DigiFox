/// Winlink message composer — compose a new message.
///
/// SwiftUI view for creating and sending Winlink emails.
/// Supports To, CC, Subject, Body and attachments.

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

    /// Optional: pre-filled reply
    var replyTo: WinlinkMessage?

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Recipients
                Section(header: Text("Recipients")) {
                    HStack {
                        Text("An:")
                            .foregroundColor(.secondary)
                            .frame(width: 30, alignment: .leading)
                        TextField("Callsign@winlink.org or email", text: $to)
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

                // MARK: - Subject
                Section(header: Text("Subject")) {
                    TextField("Enter subject", text: $subject)
                }

                // MARK: - Message Body
                Section(header: Text("Message")) {
                    TextEditor(text: $messageBody)
                        .frame(minHeight: 200)
                }

                // MARK: - Attachments
                Section(header: Text("Attachments (\(attachments.count))")) {
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
                        Label("Add attachment", systemImage: "paperclip")
                    }
                }

                // MARK: - Error
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: sendMessage) {
                        if isSending {
                            ProgressView()
                        } else {
                            Label("Send", systemImage: "paperplane")
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
            errorMessage = "Please configure Winlink account in Settings first."
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

        // Save to outbox
        WinlinkMailbox.shared.storeOutbox(message: message)

        isSending = false
        dismiss()
    }

    private func prefillReply() {
        guard let reply = replyTo else { return }
        to = reply.from
        subject = reply.subject.hasPrefix("Re:") ? reply.subject : "Re: \(reply.subject)"
        messageBody = "\n\n--- Original message from \(reply.from) ---\n\(reply.body)"
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
