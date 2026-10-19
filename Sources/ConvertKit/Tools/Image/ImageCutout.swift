import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Vystřižení předmětu z pozadí (Vision, lokálně). Výsledek je PNG s průhledností.
public enum ImageCutout {
    public static func cutout(_ image: CGImage, cropToSubject: Bool) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ConvertError.unsupportedInput("na obrázku nebyl nalezen žádný předmět")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: cropToSubject)
        let ci = CIImage(cvPixelBuffer: buffer)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ImageAdjust.context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: space) else {
            throw ConvertError.writeFailed("vystřižení")
        }
        return result
    }

    static let options: [ToolOption] = [
        .toggle("crop", "Oříznout na předmět", default: false),
    ]

    public static let tool = Tool(
        id: "image.tool.cutout", title: "Bez pozadí", symbol: "person.crop.rectangle", options: options,
        accepts: { $0.allImages },
        preview: { request in
            let context = OperationContext(selection: request.selection, options: request.options)
            let image = try ImageBackend.previewImage(at: request.source, maxPixel: request.maxPixel)
            return PreviewResult(image: try cutout(image, cropToSubject: context.bool("crop") ?? false))
        },
        run: { context in
            let crop = context.bool("crop") ?? false
            return try await EachImage.run(context, tag: "bez pozadí", outputExtension: { _ in "png" }) { source, output, progress in
                progress(0.2)
                let result = try cutout(try ImageBackend.load(source), cropToSubject: crop)
                progress(0.9)
                try ImageBackend.encode(result, as: .png, properties: ImageBackend.carriedProperties(of: source, stripping: false))
                    .write(to: output)
                progress(1)
            }
        }
    )
}
