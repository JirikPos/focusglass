import Foundation

/// Nástroje kola ⌘ podle druhu souboru. Pořadí = pořadí lístků.
public enum ToolCatalog {
    public static func all() -> [any FileOperation] {
        images()
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
