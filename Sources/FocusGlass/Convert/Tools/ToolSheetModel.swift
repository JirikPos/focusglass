import AppKit
import ConvertKit
import Observation
import PDFKit

/// Stav okna nástroje: hodnoty voleb, náhled a data z editorů (ořez, anotace, krytí, pořadí).
@MainActor
@Observable
final class ToolSheetModel {
    let tool: Tool
    let selection: Selection
    var values: [String: OptionValue]

    /// Který ze souborů výběru ukazuje náhled.
    private(set) var previewIndex = 0
    /// Originál (zmenšený) – podklad editorů a „před“ v náhledu.
    private(set) var original: CGImage?
    /// Výsledek nástroje v náhledu.
    private(set) var result: CGImage?
    private(set) var caption: String?
    private(set) var isWorking = false
    private(set) var failure: String?

    // MARK: Editory

    var cropRect = NormalizedRect.full
    /// Poměr (šířka ÷ výška), se kterým ořez začal; drží se, dokud je zamčený.
    var cropRatio: Double?
    var lockCropRatio = true
    var effectiveCropRatio: Double? { lockCropRatio ? cropRatio : nil }
    var annotations: [ImageAnnotate.Annotation] = []
    var selectedAnnotation: UUID?
    /// Aktivní nástroj; `nil` = výběr a přesouvání.
    var annotateTool: ImageAnnotate.Annotation.Kind? = .arrow
    var annotateColor = RGBA.red
    var annotateWidth = 0.006
    var annotateFilled = false
    /// Rozkreslená anotace (ještě není v seznamu).
    var draft: ImageAnnotate.Annotation?
    /// Místo, kam se právě píše text.
    var pendingText: ImageAnnotate.Point?
    private var undoStack: [[ImageAnnotate.Annotation]] = []
    private var redoStack: [[ImageAnnotate.Annotation]] = []
    var regions: [ImageRedact.Region] = []
    var enabledRegions: Set<UUID> = []
    private(set) var isDetecting = false
    var showRedactResult = false { didSet { schedulePreview() } }
    var order: [URL]

    // Stránky PDF
    var pageSpecs: [PDFPages.PageSpec] = []
    var selectedPages: Set<UUID> = []
    @ObservationIgnored private(set) var pdfDocument: PDFDocument?
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]
    private var pageUndo: [[PDFPages.PageSpec]] = []

    @ObservationIgnored var onApply: ((Tool, Selection, [String: OptionValue]) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    nonisolated static let previewPixels = 1400

    init(tool: Tool, selection: Selection) {
        self.tool = tool
        self.selection = selection
        self.values = tool.defaults
        self.order = selection.urls
        if tool.editor == .pages {
            pdfDocument = PDFDocument(url: selection.urls[0])
            pageSpecs = (0..<(pdfDocument?.pageCount ?? 0)).map { PDFPages.PageSpec(source: $0) }
        } else {
            loadSource()
        }
    }

    deinit {
        previewTask?.cancel()
        detectTask?.cancel()
        loadTask?.cancel()
    }

    var source: URL { selection.urls[min(previewIndex, selection.count - 1)] }
    var hasPreviewPager: Bool { selection.isMultiple && tool.editor != .order && tool.editor != .annotate }
    var applyTitle: String {
        selection.isMultiple && !tool.needsMultiple
            ? "Použít na \(Czech.count(selection.count, "soubor", "soubory", "souborů"))" : "Použít"
    }

    // MARK: Hodnoty voleb

    func set(_ key: String, _ value: OptionValue) {
        guard values[key] != value else { return }
        values[key] = value
        if tool.editor == .redact, key == "faces" || key == "text" { detectRegions() }
        schedulePreview()
    }

    func string(_ key: String) -> String {
        if case .string(let value) = values[key] { return value }
        return ""
    }

    func bool(_ key: String) -> Bool {
        if case .bool(let value) = values[key] { return value }
        return false
    }

    func double(_ key: String) -> Double {
        switch values[key] {
        case .double(let value): value
        case .int(let value): Double(value)
        default: 0
        }
    }

    func int(_ key: String) -> Int { Int(double(key).rounded()) }

    func color(_ key: String) -> RGBA {
        if case .color(let value) = values[key] { return value }
        return .black
    }

    /// Hodnoty pro spuštění: volby + data z editorů.
    var resolvedValues: [String: OptionValue] {
        var result = values
        let encoder = JSONEncoder()
        switch tool.editor {
        case .crop:
            if string("mode") == "free", let data = try? encoder.encode(cropRect) { result["rect"] = .data(data) }
        case .annotate:
            if let data = try? encoder.encode(annotations) { result["annotations"] = .data(data) }
        case .redact:
            let active = regions.filter { enabledRegions.contains($0.id) }
            // Jeden soubor: použijí se upravené oblasti; víc souborů: každý se zpracuje automaticky.
            if selection.count == 1, let data = try? encoder.encode(active) { result["regions"] = .data(data) }
        case .order:
            if let data = try? encoder.encode(order.map(\.path)) { result["order"] = .data(data) }
        case .pages:
            if let data = try? encoder.encode(pageSpecs) { result["pages"] = .data(data) }
        case .trim:
            break
        case .form:
            break
        }
        return result
    }

    var canApply: Bool {
        switch tool.editor {
        case .annotate: !annotations.isEmpty
        case .pages:
            !pageSpecs.isEmpty && pageSpecs != (0..<(pdfDocument?.pageCount ?? 0)).map { PDFPages.PageSpec(id: pageSpecs.indices.contains($0) ? pageSpecs[$0].id : UUID(), source: $0) }
        case .redact: selection.count > 1 || regions.contains { enabledRegions.contains($0.id) }
        default: true
        }
    }

    func apply() {
        guard canApply else { return }
        onApply?(tool, selection, resolvedValues)
        onClose?()
    }

    func cancel() { onClose?() }

    // MARK: Zdroj a náhled

    func selectPreview(_ index: Int) {
        let clamped = min(max(index, 0), selection.count - 1)
        guard clamped != previewIndex else { return }
        previewIndex = clamped
        loadSource()
    }

    private func loadSource() {
        loadTask?.cancel()
        let url = source
        loadTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                try? ImageBackend.previewImage(at: url, maxPixel: Self.previewPixels)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.original = image
            if self.tool.editor == .redact { self.detectRegions() }
            self.schedulePreview(after: 0)
        }
    }

    func schedulePreview(after milliseconds: Int = 140) {
        guard tool.hasPreview else { return }
        previewTask?.cancel()
        // Editor ořezu a krytí ukazuje originál; výsledek se počítá jen kvůli popisku (a „ukázat výsledek“).
        var options = resolvedValues
        if tool.editor == .redact {
            options["regions"] = showRedactResult
                ? resolvedValues["regions"] ?? (try? JSONEncoder().encode(regions.filter { enabledRegions.contains($0.id) })).map(OptionValue.data)
                : nil
        }
        let request = PreviewRequest(source: source, options: options, maxPixel: Self.previewPixels, selection: previewSelection)
        let tool = tool
        previewTask = Task { [weak self] in
            if milliseconds > 0 { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.isWorking = true }
            do {
                let preview = try await tool.preview(request)
                guard !Task.isCancelled, let self else { return }
                self.result = preview?.image
                self.caption = preview?.caption
                self.failure = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.failure = error.localizedDescription
            }
            self?.isWorking = false
        }
    }

    /// Nástroje nad celým výběrem (koláž, PDF) dostanou výběr v pořadí z editoru.
    private var previewSelection: Selection {
        tool.needsMultiple ? Selection(urls: order) : Selection(urls: [source])
    }

    // MARK: Krytí

    func detectRegions() {
        detectTask?.cancel()
        guard let image = original else { return }
        let faces = bool("faces")
        let text = ImageRedact.TextMode(rawValue: string("text")) ?? .sensitive
        isDetecting = true
        detectTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                (try? ImageRedact.detect(in: image, faces: faces, text: text)) ?? []
            }.value
            guard !Task.isCancelled, let self else { return }
            let manual = self.regions.filter { $0.kind == .manual }
            self.regions = found + manual
            self.enabledRegions = Set(self.regions.map(\.id))
            self.isDetecting = false
            self.schedulePreview()
        }
    }

    func addManualRegion(_ rect: NormalizedRect) {
        let region = ImageRedact.Region(rect: rect, kind: .manual, label: "Ruční oblast")
        regions.append(region)
        enabledRegions.insert(region.id)
        schedulePreview()
    }

    func toggleRegion(_ id: UUID) {
        if enabledRegions.contains(id) { enabledRegions.remove(id) } else { enabledRegions.insert(id) }
        schedulePreview()
    }

    func removeRegion(_ id: UUID) {
        regions.removeAll { $0.id == id }
        enabledRegions.remove(id)
        schedulePreview()
    }

    // MARK: Ořez

    /// Rámeček, který se právě ukazuje: vlastní, nebo spočtený podle poměru / rozměrů.
    var displayedCrop: NormalizedRect {
        if string("mode") == "free" { return cropRect }
        guard let original else { return .full }
        return computedCrop(for: CGSize(width: original.width, height: original.height)) ?? .full
    }

    private func computedCrop(for size: CGSize) -> NormalizedRect? {
        let spec: ImageCrop.Spec
        if string("mode") == "dimensions" {
            spec = .dimensions(width: max(int("width"), 1), height: max(int("height"), 1))
        } else {
            spec = .aspect(AspectRatio(rawValue: string("ratio"))?.value ?? 16.0 / 9, anchorX: 0.5, anchorY: 0.5)
        }
        guard let plan = try? ImageCrop.plan(for: size, spec: spec) else { return nil }
        return NormalizedRect(x: plan.rect.minX / size.width, y: plan.rect.minY / size.height,
                              width: plan.rect.width / size.width, height: plan.rect.height / size.height)
    }

    /// Při prvním tažení se přepne na vlastní rámeček, který začíná tam, kde byl vypočtený.
    func beginFreeCrop() {
        guard string("mode") != "free" else { return }
        let current = displayedCrop
        if let original, string("mode") != "free" {
            let pixels = current.pixels(in: CGSize(width: original.width, height: original.height))
            cropRatio = pixels.height > 0 ? Double(pixels.width / pixels.height) : nil
        }
        cropRect = current
        set("mode", .string("free"))
    }

    func updateCrop(_ rect: NormalizedRect) {
        cropRect = rect
        schedulePreview()
    }

    // MARK: Anotace

    func commitAnnotations(_ updated: [ImageAnnotate.Annotation]) {
        undoStack.append(annotations)
        redoStack.removeAll()
        annotations = updated
    }

    /// Zapamatuje stav před změnou, která se provedla přímo (např. přesun tažením).
    func registerUndo(_ snapshot: [ImageAnnotate.Annotation]) {
        guard snapshot != annotations else { return }
        undoStack.append(snapshot)
        redoStack.removeAll()
    }

    /// Změní vybranou anotaci (barva, tloušťka) s možností vrátit zpět.
    func updateSelectedAnnotation(_ change: (inout ImageAnnotate.Annotation) -> Void) {
        guard let id = selectedAnnotation, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var updated = annotations
        change(&updated[index])
        commitAnnotations(updated)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedAnnotation = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedAnnotation = nil
    }

    func deleteSelectedAnnotation() {
        guard let id = selectedAnnotation else { return }
        commitAnnotations(annotations.filter { $0.id != id })
        selectedAnnotation = nil
    }

    // MARK: Pořadí

    func moveOrder(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        schedulePreview()
    }
}

// MARK: - Stránky PDF

extension ToolSheetModel {
    /// Miniatura stránky (s přidaným otočením); drží se v paměti.
    func thumbnail(for spec: PDFPages.PageSpec) -> NSImage? {
        let key = "\(spec.source)-\(spec.rotation)"
        if let cached = thumbnails[key] { return cached }
        guard let page = pdfDocument?.page(at: spec.source)?.copy() as? PDFPage else { return nil }
        page.rotation = (page.rotation + spec.rotation) % 360
        let image = page.thumbnail(of: CGSize(width: 260, height: 340), for: .cropBox)
        thumbnails[key] = image
        return image
    }

    private func commitPages(_ updated: [PDFPages.PageSpec]) {
        guard updated != pageSpecs else { return }
        pageUndo.append(pageSpecs)
        pageSpecs = updated
    }

    var canUndoPages: Bool { !pageUndo.isEmpty }

    func undoPages() {
        guard let previous = pageUndo.popLast() else { return }
        pageSpecs = previous
        selectedPages = selectedPages.filter { id in previous.contains { $0.id == id } }
    }

    func togglePage(_ id: UUID, extend: Bool) {
        if extend {
            if selectedPages.contains(id) { selectedPages.remove(id) } else { selectedPages.insert(id) }
        } else {
            selectedPages = selectedPages == [id] ? [] : [id]
        }
    }

    func selectAllPages() { selectedPages = Set(pageSpecs.map(\.id)) }

    func rotateSelectedPages(by degrees: Int) {
        guard !selectedPages.isEmpty else { return }
        commitPages(pageSpecs.map { spec in
            guard selectedPages.contains(spec.id) else { return spec }
            return PDFPages.PageSpec(id: spec.id, source: spec.source, rotation: spec.rotation + degrees)
        })
    }

    func deleteSelectedPages() {
        guard !selectedPages.isEmpty else { return }
        commitPages(pageSpecs.filter { !selectedPages.contains($0.id) })
        selectedPages = []
    }

    func duplicateSelectedPages() {
        guard !selectedPages.isEmpty else { return }
        var result: [PDFPages.PageSpec] = []
        for spec in pageSpecs {
            result.append(spec)
            if selectedPages.contains(spec.id) { result.append(PDFPages.PageSpec(source: spec.source, rotation: spec.rotation)) }
        }
        commitPages(result)
    }

    /// Přesune stránku `id` před stránku `target` (nebo na konec, když je `target` `nil`).
    func movePage(_ id: UUID, before target: UUID?) {
        guard let from = pageSpecs.firstIndex(where: { $0.id == id }), id != target else { return }
        var updated = pageSpecs
        let item = updated.remove(at: from)
        if let target, let to = updated.firstIndex(where: { $0.id == target }) { updated.insert(item, at: to) } else { updated.append(item) }
        commitPages(updated)
    }
}
