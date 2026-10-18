import Foundation

/// Minimální platné PPTX: každý snímek = jeden obrázek přes celou plochu.
/// (PDF → PPTX: vzhled stránky zůstane 1:1, text ve snímku není editovatelný.)
public enum PPTX {
    public struct Slide {
        public let image: URL // JPG nebo PNG
        public init(image: URL) { self.image = image }
    }

    /// - Parameter size: velikost snímku v bodech (1 pt = 12 700 EMU).
    public static func write(slides: [Slide], size: CGSize, to output: URL, workDirectory: URL) async throws {
        let root = workDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for folder in ["_rels", "ppt/_rels", "ppt/slides/_rels", "ppt/slideMasters/_rels", "ppt/slideLayouts/_rels",
                       "ppt/theme", "ppt/media"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ content: String) throws {
            try (header + content).write(to: root.appendingPathComponent(path), atomically: false, encoding: .utf8)
        }
        let cx = Int(size.width * 12_700)
        let cy = Int(size.height * 12_700)

        var overrides = """
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        """
        for index in slides.indices {
            overrides += #"<Override PartName="/ppt/slides/slide\#(index + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
        }
        try put("[Content_Types].xml", """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="jpg" ContentType="image/jpeg"/><Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Default Extension="png" ContentType="image/png"/>\(overrides)</Types>
        """)
        try put("_rels/.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """)

        let slideIDs = slides.indices.map { #"<p:sldId id="\#(256 + $0)" r:id="rId\#($0 + 2)"/>"# }.joined()
        try put("ppt/presentation.xml", """
        <p:presentation xmlns:a="\(nsA)" xmlns:r="\(nsR)" xmlns:p="\(nsP)" saveSubsetFonts="1">\
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(slideIDs)</p:sldIdLst>\
        <p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="\(cy)" cy="\(cx)"/>\
        <p:defaultTextStyle><a:defPPr><a:defRPr lang="cs-CZ"/></a:defPPr></p:defaultTextStyle></p:presentation>
        """)
        var presentationRels = #"<Relationship Id="rId1" Type="\#(relBase)/slideMaster" Target="slideMasters/slideMaster1.xml"/>"#
        for index in slides.indices {
            presentationRels += #"<Relationship Id="rId\#(index + 2)" Type="\#(relBase)/slide" Target="slides/slide\#(index + 1).xml"/>"#
        }
        presentationRels += #"<Relationship Id="rId\#(slides.count + 2)" Type="\#(relBase)/theme" Target="theme/theme1.xml"/>"#
        try put("ppt/_rels/presentation.xml.rels", relationships(presentationRels))

        try put("ppt/slideMasters/slideMaster1.xml", """
        <p:sldMaster xmlns:a="\(nsA)" xmlns:r="\(nsR)" xmlns:p="\(nsP)"><p:cSld>\(emptyTree)</p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
        accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """)
        try put("ppt/slideMasters/_rels/slideMaster1.xml.rels", relationships("""
        <Relationship Id="rId1" Type="\(relBase)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="\(relBase)/theme" Target="../theme/theme1.xml"/>
        """))
        try put("ppt/slideLayouts/slideLayout1.xml", """
        <p:sldLayout xmlns:a="\(nsA)" xmlns:r="\(nsR)" xmlns:p="\(nsP)" type="blank" preserve="1">\
        <p:cSld name="Prázdný">\(emptyTree)</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
        try put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relationships(
            #"<Relationship Id="rId1" Type="\#(relBase)/slideMaster" Target="../slideMasters/slideMaster1.xml"/>"#
        ))
        try put("ppt/theme/theme1.xml", theme)

        for (index, slide) in slides.enumerated() {
            try Task.checkCancellation()
            let ext = slide.image.pathExtension.lowercased()
            let media = "image\(index + 1).\(ext)"
            try fm.copyItem(at: slide.image, to: root.appendingPathComponent("ppt/media/\(media)"))
            try put("ppt/slides/slide\(index + 1).xml", """
            <p:sld xmlns:a="\(nsA)" xmlns:r="\(nsR)" xmlns:p="\(nsP)"><p:cSld><p:spTree>\
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
            <p:pic><p:nvPicPr><p:cNvPr id="2" name="Strana \(index + 1)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>\
            </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
            try put("ppt/slides/_rels/slide\(index + 1).xml.rels", relationships("""
            <Relationship Id="rId1" Type="\(relBase)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
            <Relationship Id="rId2" Type="\(relBase)/image" Target="../media/\(media)"/>
            """))
        }
        try await Zip.archiveContents(of: root, to: output)
    }

    // MARK: XML

    private static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    private static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private static func relationships(_ body: String) -> String {
        #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(body)</Relationships>"#
    }

    private static let emptyTree = """
    <p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree>
    """

    /// Úplné téma Office (PowerPoint bez něj soubor odmítne).
    private static let theme = """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="FocusGlass"><a:themeElements>\
    <a:clrScheme name="FocusGlass"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2>\
    <a:accent1><a:srgbClr val="2563EB"/></a:accent1><a:accent2><a:srgbClr val="DC2626"/></a:accent2>\
    <a:accent3><a:srgbClr val="16A34A"/></a:accent3><a:accent4><a:srgbClr val="9333EA"/></a:accent4>\
    <a:accent5><a:srgbClr val="EA580C"/></a:accent5><a:accent6><a:srgbClr val="0891B2"/></a:accent6>\
    <a:hlink><a:srgbClr val="2563EB"/></a:hlink><a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="FocusGlass"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="FocusGlass"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>\
    <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """
}
