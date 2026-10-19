import AppKit
import ConvertKit
import SwiftUI

/// Okno nástroje: vlevo náhled nebo editor, vpravo volby, dole Zrušit / Použít.
struct ToolSheetView: View {
    let model: ToolSheetModel
    @State private var showOriginal = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            sidebar
                .frame(width: 310)
        }
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
        .onKeyPress(.escape) {
            model.cancel()
            return .handled
        }
    }

    // MARK: Obsah

    @ViewBuilder
    private var content: some View {
        switch model.tool.editor {
        case .crop: CropEditor(model: model)
        case .annotate: AnnotateEditor(model: model)
        case .pages: PagesEditor(model: model)
        case .trim: previewPane
        case .redact: RedactEditor(model: model)
        case .form, .order: previewPane
        }
    }

    private var previewPane: some View {
        ZStack {
            Checkerboard()
            if let image = (showOriginal ? model.original : model.result) ?? model.original {
                Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(18)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
            } else {
                ProgressView().controlSize(.small)
            }
            if model.isWorking {
                ProgressView().controlSize(.small)
                    .padding(8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
            if model.tool.hasPreview, model.original != nil, model.tool.editor == .form, model.tool.id != "image.tool.metadata" {
                Text("Podrž pro originál")
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(showOriginal ? .white : .black.opacity(0.65), in: Capsule())
                    .foregroundStyle(showOriginal ? .black : .white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(12)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in showOriginal = true }
                        .onEnded { _ in showOriginal = false })
            }
        }
    }

    // MARK: Postranní panel

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.tool.symbol ?? "wand.and.stars")
                    .font(.system(size: 14, weight: .medium))
                Text(model.tool.title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 4)

            Text(model.selection.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 18).padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.tool.editor == .order { OrderList(model: model) }
                    if model.tool.editor == .redact { RedactRegionList(model: model) }
                    if model.tool.editor == .annotate { AnnotateOptions(model: model) }
                    OptionsForm(model: model)
                    if let failure = model.failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.hasPreviewPager {
                Button { model.selectPreview(model.previewIndex - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(GlassIconButtonStyle(size: 22))
                    .disabled(model.previewIndex == 0)
                Text("\(model.previewIndex + 1) / \(model.selection.count)")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                Button { model.selectPreview(model.previewIndex + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(GlassIconButtonStyle(size: 22))
                    .disabled(model.previewIndex >= model.selection.count - 1)
            }
            if let caption = model.caption {
                Text(caption)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(model.tool.id == "image.tool.metadata" ? 8 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            Spacer()
            Button("Zrušit", action: model.cancel)
                .buttonStyle(GlassPillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(model.applyTitle, action: model.apply)
                .buttonStyle(PrimaryPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.black.opacity(0.35))
    }
}

/// Šachovnice pod průhlednými obrázky.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.white.opacity(0.035)))
                }
            }
        }
        .background(Color(white: 0.1))
    }
}

/// Obdélník, do kterého se vejde obrázek (aspect fit) uvnitř oblasti.
func fittedRect(imageSize: CGSize, in area: CGSize, padding: CGFloat = 18) -> CGRect {
    let available = CGSize(width: max(area.width - 2 * padding, 1), height: max(area.height - 2 * padding, 1))
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let scale = min(available.width / imageSize.width, available.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2, width: size.width, height: size.height)
}
