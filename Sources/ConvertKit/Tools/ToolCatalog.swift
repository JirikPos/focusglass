import Foundation

/// Nástroje kola ⌘ podle druhu souboru. Pořadí = pořadí lístků.
public enum ToolCatalog {
    public static func all() -> [any FileOperation] {
        images() + pdfs() + videos() + audio() + subtitles() + archives() + documents()
    }

    static func videos() -> [Tool] {
        [
            VideoCompress.tool,
            VideoTrim.tool,
            VideoCrop.tool,
            VideoResize.tool,
            VideoRotate.tool,
            VideoSpeed.tool,
            VideoFrames.tool,
            VideoExtractAudio.tool,
            VideoMute.tool,
            VideoGIF.tool,
            VideoMerge.tool,
        ]
    }

    static func subtitles() -> [Tool] {
        [SubtitleTools.shift, SubtitleTools.retime, SubtitleTools.merge, SubtitleTools.burn]
    }

    static func documents() -> [Tool] {
        [
            DocumentTools.replaceTool,
            DocumentTools.statsTool,
            DocumentTools.mergeTool,
            SheetTools.cleanTool,
            SheetTools.mergeTool,
            EPUBMeta.tool,
        ]
    }

    static func archives() -> [Tool] {
        [ArchiveTools.extractTool, ArchiveTools.listTool]
    }

    static func audio() -> [Tool] {
        [
            AudioTrim.tool,
            AudioCompress.tool,
            AudioNormalize.tool,
            AudioGain.tool,
            AudioSplit.tool,
            AudioMerge.tool,
        ]
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
