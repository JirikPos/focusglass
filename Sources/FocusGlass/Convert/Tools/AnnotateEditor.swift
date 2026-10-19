import ConvertKit
import SwiftUI

typealias Annotation = ImageAnnotate.Annotation

/// Kreslení anotací přímo na fotku: šipky, tvary, zvýrazňovač, text, číslování, tužka, pixelizace.
/// Vykresluje se jádrem (`ImageAnnotate.render`), takže náhled odpovídá výsledku.
struct AnnotateEditor: View {
    let model: ToolSheetModel
    @State private var moveSnapshot: [Annotation]?
    @State private var lastPoint: ImageAnnotate.Point?
    @State private var textValue = ""
    @FocusState private var textFocused: Bool
    @FocusState private var canvasFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geometry in
                let size = model.original.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
                let fit = fittedRect(imageSize: size, in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Checkerboard()
                    if let base = model.original {
                        let image = (try? ImageAnnotate.render(model.annotations + (model.draft.map { [$0] } ?? []), onto: base)) ?? base
                        Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                            .resizable().interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                            .position(x: fit.midX, y: fit.midY)
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
                        selectionOverlay(fit: fit)
                        textField(fit: fit)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(drag(fit: fit))
                .focusable()
                .focused($canvasFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard model.pendingText == nil else { return .ignored }
                    model.deleteSelectedAnnotation()
                    return .handled
                }
                .onAppear { canvasFocused = true }
            }
        }
    }

    // MARK: Panel nástrojů

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton(nil, symbol: "cursorarrow", title: "Výběr a přesun")
            ForEach(Annotation.Kind.allCases, id: \.self) { kind in
                toolButton(kind, symbol: kind.symbol, title: kind.title)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(GlassIconButtonStyle(size: 26)).disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command).help("Zpět (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(GlassIconButtonStyle(size: 26)).disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift]).help("Znovu (⇧⌘Z)")
            Button { model.deleteSelectedAnnotation() } label: { Image(systemName: "trash") }
                .buttonStyle(GlassIconButtonStyle(size: 26)).disabled(model.selectedAnnotation == nil)
                .help("Smazat vybranou (⌫)")
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.35))
    }

    private func toolButton(_ kind: Annotation.Kind?, symbol: String, title: String) -> some View {
        let active = model.annotateTool == kind
        return Button {
            model.annotateTool = kind
            model.pendingText = nil
            if kind != nil { model.selectedAnnotation = nil }
        } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? .white.opacity(0.9) : .clear))
                .foregroundStyle(active ? .black : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: Souřadnice

    private func normalized(_ point: CGPoint, in fit: CGRect) -> ImageAnnotate.Point {
        ImageAnnotate.Point(min(max(Double((point.x - fit.minX) / max(fit.width, 1)), 0), 1),
                            min(max(Double((point.y - fit.minY) / max(fit.height, 1)), 0), 1))
    }

    private func viewPoint(_ p: ImageAnnotate.Point, in fit: CGRect) -> CGPoint {
        CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
    }

    // MARK: Tažení

    private func drag(fit: CGRect) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.original != nil, model.pendingText == nil else { return }
                let point = normalized(value.location, in: fit)
                let start = normalized(value.startLocation, in: fit)
                if let kind = model.annotateTool {
                    switch kind {
                    case .text, .number:
                        break
                    case .pen:
                        if model.draft == nil {
                            model.draft = newAnnotation(kind, start: start, end: point, points: [start])
                        } else {
                            model.draft?.points.append(point)
                            model.draft?.end = point
                        }
                    default:
                        if model.draft == nil { model.draft = newAnnotation(kind, start: start, end: point) }
                        model.draft?.end = constrained(kind, from: start, to: point)
                    }
                } else {
                    moveSelection(from: start, to: point)
                }
            }
            .onEnded { value in
                guard model.original != nil, model.pendingText == nil else { return }
                let point = normalized(value.location, in: fit)
                let start = normalized(value.startLocation, in: fit)
                let moved = hypot(point.x - start.x, point.y - start.y) > 0.004
                if let kind = model.annotateTool {
                    switch kind {
                    case .text:
                        textValue = ""
                        model.pendingText = start
                        textFocused = true
                    case .number:
                        let next = model.annotations.filter { $0.kind == .number }.count + 1
                        model.commitAnnotations(model.annotations + [
                            newAnnotation(.number, start: start, end: start, text: String(next)),
                        ])
                    default:
                        if let draft = model.draft, moved || kind == .pen { model.commitAnnotations(model.annotations + [draft]) }
                        model.draft = nil
                    }
                } else {
                    if let snapshot = moveSnapshot { model.registerUndo(snapshot) }
                    moveSnapshot = nil
                    lastPoint = nil
                    if !moved { select(at: start) }
                }
            }
    }

    private func newAnnotation(_ kind: Annotation.Kind, start: ImageAnnotate.Point, end: ImageAnnotate.Point,
                               points: [ImageAnnotate.Point] = [], text: String = "") -> Annotation {
        Annotation(kind: kind, start: start, end: end, points: points, text: text, color: model.annotateColor,
                   strokeWidth: model.annotateWidth, filled: model.annotateFilled)
    }

    /// Se Shift by se dalo omezit na osy; zatím vrací bod beze změny (ponecháno pro rozšíření).
    private func constrained(_ kind: Annotation.Kind, from start: ImageAnnotate.Point, to point: ImageAnnotate.Point) -> ImageAnnotate.Point {
        point
    }

    // MARK: Výběr a přesun

    private func select(at point: ImageAnnotate.Point) {
        model.selectedAnnotation = model.annotations.last { ImageAnnotate.hit($0, at: point) }?.id
    }

    private func moveSelection(from start: ImageAnnotate.Point, to point: ImageAnnotate.Point) {
        if lastPoint == nil {
            // Začátek tahu: vybrat, co je pod kurzorem.
            let target = model.annotations.last { ImageAnnotate.hit($0, at: start) }
            model.selectedAnnotation = target?.id
            lastPoint = start
            moveSnapshot = model.annotations
        }
        guard let id = model.selectedAnnotation, let last = lastPoint,
              let index = model.annotations.firstIndex(where: { $0.id == id }) else { return }
        let dx = point.x - last.x
        let dy = point.y - last.y
        lastPoint = point
        model.annotations[index] = ImageAnnotate.moved(model.annotations[index], dx: dx, dy: dy)
    }

    // MARK: Překryv

    @ViewBuilder
    private func selectionOverlay(fit: CGRect) -> some View {
        if let id = model.selectedAnnotation, let a = model.annotations.first(where: { $0.id == id }) {
            let box = box(for: a, in: fit)
            RoundedRectangle(cornerRadius: 3)
                .stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .allowsHitTesting(false)
        }
    }

    private func box(for a: Annotation, in fit: CGRect) -> CGRect {
        let pad: CGFloat = 8
        switch a.kind {
        case .pen:
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: fit.minX + minX * fit.width, y: fit.minY + minY * fit.height,
                          width: (maxX - minX) * fit.width, height: (maxY - minY) * fit.height).insetBy(dx: -pad, dy: -pad)
        case .text:
            let origin = viewPoint(a.start, in: fit)
            let fontSize = max(10, a.strokeWidth * Double(min(model.original?.width ?? 1, model.original?.height ?? 1)) * 6)
            let scale = fit.width / CGFloat(model.original?.width ?? 1)
            return CGRect(x: origin.x, y: origin.y, width: CGFloat(a.text.count) * fontSize * 0.6 * scale + 14,
                          height: fontSize * 1.3 * scale + 8).insetBy(dx: -pad / 2, dy: -pad / 2)
        case .number:
            let center = viewPoint(a.start, in: fit)
            let diameter = max(18, a.strokeWidth * Double(min(model.original?.width ?? 1, model.original?.height ?? 1)) * 7)
                * fit.width / CGFloat(model.original?.width ?? 1)
            return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter).insetBy(dx: -pad / 2, dy: -pad / 2)
        default:
            let r = a.bounds
            return CGRect(x: fit.minX + r.x * fit.width, y: fit.minY + r.y * fit.height,
                          width: max(r.width * fit.width, 4), height: max(r.height * fit.height, 4)).insetBy(dx: -pad, dy: -pad)
        }
    }

    @ViewBuilder
    private func textField(fit: CGRect) -> some View {
        if let point = model.pendingText {
            let origin = viewPoint(point, in: fit)
            TextField("Text", text: $textValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($textFocused)
                .position(x: min(origin.x + 100, fit.maxX - 100), y: origin.y)
                .onSubmit {
                    let text = textValue.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        model.commitAnnotations(model.annotations + [newAnnotation(.text, start: point, end: point, text: text)])
                    }
                    model.pendingText = nil
                    canvasFocused = true
                }
                .onKeyPress(.escape) {
                    model.pendingText = nil
                    canvasFocused = true
                    return .handled
                }
        }
    }
}

/// Barva, tloušťka a výplň (v postranním panelu). Změna se promítne i do vybrané anotace.
struct AnnotateOptions: View {
    let model: ToolSheetModel
    private static let swatches: [RGBA] = [.red, .yellow, RGBA(0.2, 0.78, 0.35), RGBA(0.2, 0.5, 1), .white, .black]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Barva").font(.system(size: 12.5))
                HStack(spacing: 7) {
                    ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, color in
                        Button { setColor(color) } label: {
                            Circle().fill(Color(rgba: color)).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.white.opacity(model.annotateColor == color ? 0.95 : 0.25),
                                                               lineWidth: model.annotateColor == color ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("", selection: Binding(get: { Color(rgba: model.annotateColor) }, set: { setColor(RGBA(color: $0)) }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Tloušťka").font(.system(size: 12.5))
                    Spacer()
                    Text(String(format: "%.1f", model.annotateWidth * 1000)).foregroundStyle(.white.opacity(0.55)).font(.system(size: 12))
                }
                Slider(value: Binding(get: { model.annotateWidth }, set: setWidth), in: 0.002...0.025)
                    .controlSize(.small).tint(Color(white: 0.6))
            }
            Toggle("Vyplnit tvary", isOn: Binding(get: { model.annotateFilled }, set: setFilled))
                .toggleStyle(.switch).controlSize(.small).tint(Color(white: 0.55)).font(.system(size: 12.5))
            Text("Táhni na fotce. Nástroj Výběr (šipka) přesouvá anotace; ⌫ maže vybranou, ⌘Z vrací zpět.")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setColor(_ color: RGBA) {
        model.annotateColor = color
        model.updateSelectedAnnotation { $0.color = color }
    }

    private func setWidth(_ width: Double) {
        model.annotateWidth = width
        model.selectedAnnotation.flatMap { id in model.annotations.first { $0.id == id } }.map { _ in
            if let index = model.annotations.firstIndex(where: { $0.id == model.selectedAnnotation }) {
                model.annotations[index].strokeWidth = width
            }
        }
    }

    private func setFilled(_ filled: Bool) {
        model.annotateFilled = filled
        model.updateSelectedAnnotation { $0.filled = filled }
    }
}
