import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import ConvertKit

/// Ukázkové soubory se generují za běhu – v repozitáři nejsou binární data a testy nezávisí na cizích souborech.
enum Fixtures {
    static let marker = "Žluťoučký kůň 42"

    static func png(in dir: URL, name: String = "obrázek.png", alpha: Bool = true, size: Int = 64) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        let image = context.makeImage()!
        let type = UTType(filenameExtension: url.pathExtension)!.identifier
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    static func svg(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("vektor.svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="20" height="20" fill="red"/></svg>"#
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func pdf(in dir: URL, pages: Int = 2) throws -> URL {
        let url = dir.appendingPathComponent("dokument.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 120)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 0..<pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (page == 0 ? "Nadpis" : "Strana \(page + 1)").draw(at: CGPoint(x: 10, y: 80),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
            marker.draw(at: CGPoint(x: 10, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 11)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// 0,5 s sinusovky 440 Hz.
    static func wav(in dir: URL, name: String = "zvuk.wav") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let frames: AVAudioFrameCount = 22_050
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sin(Float(i) * 2 * .pi * 440 / 44_100) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    /// 1 s videa H.264 64×64, 10 snímků/s.
    static func mp4(in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("video.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 25), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    static func markdown(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("poznámky.md")
        try """
        # Kapitola

        Text s **tučným** a *kurzívou* – \(marker).

        - jedna
        - dvě

        | A | B |
        |---|---|
        | 1 | 2 |
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func text(in dir: URL, name: String, content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func docx(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("smlouva.docx")
        let text = NSMutableAttributedString(string: "Nadpis\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        text.append(NSAttributedString(string: "\(marker)\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url)
        return url
    }

    static func csv(in dir: URL) throws -> URL {
        try text(in: dir, name: "data.csv", content: "jméno,poznámka,číslo\r\nAda,\"čárka, a \"\"uvozovky\"\"\",42\r\nBob,\(marker),007\r\n")
    }

    static func srt(in dir: URL) throws -> URL {
        try text(in: dir, name: "titulky.srt", content: "1\n00:00:01,000 --> 00:00:02,500\n<i>\(marker)</i>\n\n2\n00:00:03,000 --> 00:00:04,000\nDruhý\n")
    }

    static func folder(in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent("Složka")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try marker.write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    static func zip(in dir: URL) async throws -> URL {
        let folder = try folder(in: dir)
        let url = dir.appendingPathComponent("archiv.zip")
        try await ProcessRunner.run(Zip.ditto, ["-c", "-k", "--keepParent", folder.path, url.path])
        return url
    }
}
