import CmuxCodeHighlighting
import SwiftUI

/// Header button that opens a searchable symbol outline for the open code file and
/// jumps the editor to the chosen symbol.
struct FilePreviewOutlineButton: View {
    @ObservedObject var panel: FilePreviewPanel

    @State private var isPresented = false
    @State private var symbols: [CodeSymbol] = []

    var body: some View {
        PanelHeaderIconButton(
            systemName: "list.bullet.indent",
            label: String(localized: "filePreview.outline", defaultValue: "Outline"),
            isDisabled: false,
            action: {
                symbols = panel.codeSymbols()
                isPresented = true
            }
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            // Value snapshot + closure only below the list boundary (no store ref).
            FilePreviewOutlineList(symbols: symbols) { symbol in
                panel.scrollToSymbol(symbol)
                isPresented = false
            }
        }
    }
}

/// The popover body: a filter field over a scrollable list of symbols.
private struct FilePreviewOutlineList: View {
    let symbols: [CodeSymbol]
    let onSelect: (CodeSymbol) -> Void

    @State private var query = ""

    private var filtered: [CodeSymbol] {
        guard !query.isEmpty else { return symbols }
        return symbols.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                String(localized: "filePreview.outline.search", defaultValue: "Filter symbols"),
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .padding(8)

            Divider()

            if filtered.isEmpty {
                Text(String(localized: "filePreview.outline.empty", defaultValue: "No symbols"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { symbol in
                            Button {
                                onSelect(symbol)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: Self.icon(for: symbol.kind))
                                        .frame(width: 16)
                                        .foregroundStyle(.secondary)
                                    Text(symbol.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("\(symbol.line)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 280, height: 360)
    }

    private static func icon(for kind: String) -> String {
        switch kind {
        case "function", "method": return "function"
        case "class", "interface", "struct", "type": return "cube"
        case "enum": return "list.number"
        case "constant", "constructor": return "c.square"
        case "module", "namespace": return "shippingbox"
        default: return "circle"
        }
    }
}
