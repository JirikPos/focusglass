import ConvertKit
import SwiftUI

/// Ořez tažením: rámeček se dá posouvat, tahat za rohy a hrany nebo nakreslit znovu.
/// Dokud se nic netáhne, ukazuje výřez podle zvoleného poměru stran / rozměrů.
struct CropEditor: View {
    let model: ToolSheetModel
    @State private var gesture: Gesture?

    private typealias Handle = CropGeometry.Handle

    private struct Gesture {
        let handle: Handle
        let start: NormalizedRect
        let origin: CGPoint // normalizovaný bod, odkud se začalo tahat
    }

    var body: some View {
        GeometryReader { geometry in
            let size = model.original.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            let fit = fittedRect(imageSize: size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Checkerboard()
                if let image = model.original {
                    Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                        .resizable().interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                    overlay(fit: fit)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                lockButton
            }
            .contentShape(Rectangle())
            .gesture(drag(fit: fit, size: size))
        }
    }

    // MARK: Kreslení

    private func viewRect(_ rect: NormalizedRect, in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + rect.x * fit.width, y: fit.minY + rect.y * fit.height,
               width: rect.width * fit.width, height: rect.height * fit.height)
    }

    private func overlay(fit: CGRect) -> some View {
        let crop = viewRect(model.displayedCrop, in: fit)
        return ZStack {
            // Ztmavení mimo výřez.
            Path { path in
                path.addRect(fit)
                path.addRect(crop)
            }
            .fill(.black.opacity(0.58), style: FillStyle(eoFill: true))
            // Třetinová mřížka.
            Path { path in
                for i in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(i) / 3
                    let y = crop.minY + crop.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: crop.minY)); path.addLine(to: CGPoint(x: x, y: crop.maxY))
                    path.move(to: CGPoint(x: crop.minX, y: y)); path.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.28), lineWidth: 0.5)
            Rectangle().path(in: crop).stroke(.white, lineWidth: 1.5)
            ForEach(Array(handlePoints(crop).enumerated()), id: \.offset) { _, point in
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(point)
            }
        }
        .allowsHitTesting(false)
    }

    private func handlePoints(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    @ViewBuilder
    private var lockButton: some View {
        if model.cropRatio != nil, model.string("mode") == "free" {
            Button {
                model.lockCropRatio.toggle()
            } label: {
                Label(model.lockCropRatio ? "Poměr zamčený" : "Volný poměr", systemImage: model.lockCropRatio ? "lock" : "lock.open")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(GlassPillButtonStyle())
            .padding(12)
        }
    }

    // MARK: Tažení

    private func drag(fit: CGRect, size: CGSize) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard fit.width > 0, fit.height > 0 else { return }
                let start = normalized(value.startLocation, in: fit)
                let current = normalized(value.location, in: fit)
                if gesture == nil {
                    let crop = model.displayedCrop
                    let handle = CropGeometry.hit(value.startLocation, crop: viewRect(crop, in: fit))
                    model.beginFreeCrop()
                    gesture = Gesture(handle: handle, start: crop, origin: start)
                }
                guard let gesture else { return }
                let ratioK = model.effectiveCropRatio.map { ($0 > 0 && size.height > 0) ? Double(size.width / size.height) / $0 : 1 }
                model.updateCrop(CropGeometry.updated(gesture.handle, start: gesture.start, origin: gesture.origin,
                                                       point: current, ratioK: ratioK))
            }
            .onEnded { _ in gesture = nil }
    }

    private func normalized(_ point: CGPoint, in fit: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - fit.minX) / fit.width, 0), 1), y: min(max((point.y - fit.minY) / fit.height, 0), 1))
    }
}
