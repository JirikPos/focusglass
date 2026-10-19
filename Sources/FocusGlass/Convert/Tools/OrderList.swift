import AppKit
import ConvertKit
import SwiftUI

/// Pořadí souborů pro koláž a PDF: přetažením se mění.
struct OrderList: View {
    let model: ToolSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pořadí").font(.system(size: 12.5, weight: .semibold))
            List {
                ForEach(Array(model.order.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.4)).frame(width: 16)
                        Thumb(url: url)
                        Text(url.lastPathComponent).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                }
                .onMove(perform: model.moveOrder)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(model.order.count) * 34 + 6, 190))
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
            Text("Přetažením změníš pořadí.").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

private struct Thumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.08))
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            image = await Task.detached(priority: .utility) {
                (try? ImageBackend.previewImage(at: url, maxPixel: 80)).map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                }
            }.value
        }
    }
}
