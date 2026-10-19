import Foundation

/// Nástroje kola ⌘ podle druhu souboru. Pořadí = pořadí lístků.
public enum ToolCatalog {
    public static func all() -> [any FileOperation] {
        images() + pdfs()
    }

    static func pdfs() -> [Tool] {
        [
            PDFCompress.tool,
            PDFPages.tool,
            PDFSplit.tool,
            PDFMerge.tool,
            PDFPassword.tool,
            PDFWatermark.tool,
            PDFRedactText.tool,
            PDFExtractImages.tool,
            PDFOCR.tool,
        ]
    }

    static func images() -> [Tool] {
        [
            ImageCompress.tool,
            ImageMetadata.tool,
            ImageAdjust.tool,
            ImageAnnotate.tool,
            ImageBackground.tool,
            ImageCrop.tool,
            ImageRedact.tool,
            ImageCutout.tool,
            ImageCombine.pdfTool,
            ImageCombine.collageTool,
        ]
    }
}
