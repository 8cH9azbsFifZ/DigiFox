import SwiftUI

struct LogOutputView: View {
    @ObservedObject private var logManager = LogManager.shared
    @State private var autoScroll = true
    @State private var filterText = ""

    private var filteredEntries: [LogManager.Entry] {
        if filterText.isEmpty { return logManager.entries }
        return logManager.entries.filter {
            $0.tag.localizedCaseInsensitiveContains(filterText) ||
            $0.message.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredEntries) { entry in
                            Text(entry.formatted)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(colorForTag(entry.tag))
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .background(Color.black)
                .onChange(of: logManager.entries.count) { _ in
                    if autoScroll, let last = filteredEntries.last {
                        withAnimation(.none) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Toolbar
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .autocorrectionDisabled()

                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .font(.caption)

                Button(role: .destructive) {
                    logManager.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .font(.caption)

                Text("\(filteredEntries.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .navigationTitle("Log Output")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func colorForTag(_ tag: String) -> Color {
        switch tag {
        case _ where tag.contains("ERROR"):  return .red
        case _ where tag.contains("TX"):     return .orange
        case _ where tag.contains("RX"):     return .cyan
        case _ where tag.contains("RIG"), _ where tag.contains("CAT"):
            return .yellow
        case _ where tag.contains("Serial"), _ where tag.contains("USB"):
            return .green
        case _ where tag.contains("Audio"):  return .mint
        default: return .white
        }
    }
}
