import ConvertKit
import SwiftUI

/// Krytí: nalezené oblasti jdou zapínat a vypínat kliknutím, další se dají nakreslit tažením.
struct RedactEditor: View {
    let model: ToolSheetModel
    @State private var dragRect: NormalizedRect?

    var body: some View {
        GeometryReader { geometry in
            let size = model.original.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            let fit = fittedRect(imageSize: size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Checkerboard()
                if let image = shownImage {
                    Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                        .resizable().interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
                    if !model.showRedactResult { regionOverlay(fit: fit) }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.isDetecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Hledám obličeje a text…").font(.system(size: 11))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(12)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(fit: fit))
        }
    }

    private var shownImage: CGImage? {
        model.showRedactResult ? (model.result ?? model.original) : model.original
    }

    private func viewRect(_ rect: NormalizedRect, in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + rect.x * fit.width, y: fit.minY + rect.y * fit.height,
               width: rect.width * fit.width, height: rect.height * fit.height)
    }

    private func regionOverlay(fit: CGRect) -> some View {
        ZStack {
            ForEach(model.regions) { region in
                let rect = viewRect(region.rect, in: fit)
                let on = model.enabledRegions.contains(region.id)
                RoundedRectangle(cornerRadius: 3)
                    .fill(on ? Color.red.opacity(0.28) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(on ? Color.red : .white.opacity(0.45), style: StrokeStyle(lineWidth: on ? 1.5 : 1, dash: on ? [] : [4, 3])))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            if let dragRect {
                let rect = viewRect(dragRect, in: fit)
                Rectangle().strokeBorder(.white, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .background(Color.white.opacity(0.1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
    }

    private func drag(fit: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !model.showRedactResult, fit.width > 0 else { return }
                dragRect = rect(from: value.startLocation, to: value.location, in: fit)
            }
            .onEnded { value in
                defer { dragRect = nil }
                guard !model.showRedactResult, fit.width > 0 else { return }
                let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if moved < 4 {
                    // Klik: přepnout oblast pod kurzorem (nejmenší, ať jde trefit oblast uvnitř jiné).
                    let point = normalized(value.startLocation, in: fit)
                    let target = model.regions
                        .filter { point.x >= $0.rect.x && point.x <= $0.rect.x + $0.rect.width && point.y >= $0.rect.y && point.y <= $0.rect.y + $0.rect.height }
                        .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
                    if let target { model.toggleRegion(target.id) }
                } else if let rect = rect(from: value.startLocation, to: value.location, in: fit), rect.width > 0.01, rect.height > 0.01 {
                    model.addManualRegion(rect)
                }
            }
    }

    private func normalized(_ point: CGPoint, in fit: CGRect) -> (x: Double, y: Double) {
        (min(max(Double((point.x - fit.minX) / fit.width), 0), 1), min(max(Double((point.y - fit.minY) / fit.height), 0), 1))
    }

    private func rect(from a: CGPoint, to b: CGPoint, in fit: CGRect) -> NormalizedRect? {
        let p = normalized(a, in: fit)
        let q = normalized(b, in: fit)
        return NormalizedRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
    }
}

/// Seznam nalezených a ručních oblastí v postranním panelu.
struct RedactRegionList: View {
    let model: ToolSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Oblasti").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if model.isDetecting { ProgressView().controlSize(.mini) }
            }
            if model.selection.isMultiple {
                Text("Nastavení se použije na všech \(model.selection.count) souborů; obličeje a text se najdou u každého zvlášť.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            } else if model.regions.isEmpty, !model.isDetecting {
                Text("Nic nenalezeno. Oblast nakresli tažením přes fotku.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(model.regions) { region in
                    HStack(spacing: 8) {
                        Image(systemName: icon(region.kind)).font(.system(size: 11)).frame(width: 16)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(region.label.isEmpty ? "Oblast" : region.label)
                            .font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if region.kind == .manual {
                            Button { model.removeRegion(region.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                        }
                        Toggle("", isOn: Binding(get: { model.enabledRegions.contains(region.id) }, set: { _ in model.toggleRegion(region.id) }))
                            .toggleStyle(.switch).controlSize(.mini).tint(Color(white: 0.55)).labelsHidden()
                    }
                }
                Toggle("Ukázat výsledek", isOn: Binding(get: { model.showRedactResult }, set: { model.showRedactResult = $0 }))
                    .toggleStyle(.switch).controlSize(.small).tint(Color(white: 0.55)).font(.system(size: 12.5))
                    .padding(.top, 4)
            }
        }
    }

    private func icon(_ kind: ImageRedact.Region.Kind) -> String {
        switch kind {
        case .face: "face.dashed"
        case .text: "text.viewfinder"
        case .manual: "rectangle.dashed"
        }
    }
}
