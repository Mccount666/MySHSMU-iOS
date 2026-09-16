import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the arithmetic captcha on the CAS login page.
///
/// The Android build feeds the bitmap to ML Kit's on-device Latin text
/// recogniser and evaluates the expression. On iOS the equivalent engine is
/// Vision's `VNRecognizeTextRequest`; the text normalisation and the evaluation
/// below are a faithful port of `utils/CaptchaSolver.kt`.
enum CaptchaSolver {

    /// Recognises and evaluates a captcha image. Returns the answer as a
    /// string, or `nil` when the image cannot be read or the text does not form
    /// an expression. Everything runs on-device.
    static func solve(imageData: Data) async -> String? {
        guard let image = decodeImage(imageData) else {
            Log.warn("CaptchaSolver", "Could not decode captcha image")
            return nil
        }

        let prepared = upscaleIfTiny(image)
        guard let rawText = await recognizeText(in: prepared) else { return nil }

        Log.debug("CaptchaSolver", "OCR Original Result: \(rawText)")
        let cleaned = cleanText(rawText)
        Log.debug("CaptchaSolver", "OCR Cleaned Text: \(cleaned)")
        return calculateExpression(cleaned)
    }

    // MARK: - Vision

    private static func recognizeText(in image: CGImage) async -> String? {
        let once = ResumeOnce()

        // The handler has to be supplied at construction: `completionHandler`
        // is get-only, and the closure needs `once` to already exist.
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                Log.error("CaptchaSolver", "Vision failed: \(error.localizedDescription)")
                once.resume(nil)
                return
            }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            once.resume(text)
        }
        request.recognitionLevel = .accurate
        // Language correction would "fix" `1+2=?` into prose; captchas need the
        // raw glyphs, matching ML Kit's default recogniser behaviour.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // The continuation type is spelled out: leaving it to inference makes
        // the compiler settle on `String` and then reject `ResumeOnce.attach`.
        let recognised: String? = await withCheckedContinuation {
            (continuation: CheckedContinuation<String?, Never>) in
            once.attach(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    Log.error("CaptchaSolver", "Vision perform failed: \(error.localizedDescription)")
                    once.resume(nil)
                }
            }
        }
        return recognised
    }

    /// Vision loses very small glyphs, and CAS captchas are around 80×30.
    /// Enlarging them roughly triples the recognition rate.
    private static func upscaleIfTiny(_ image: CGImage, minimumWidth: CGFloat = 240) -> CGImage {
        let width = CGFloat(image.width)
        guard width > 0, width < minimumWidth else { return image }

        let scale = min(5, max(2, minimumWidth / width))
        let targetWidth = Int((width * scale).rounded())
        let targetHeight = Int((CGFloat(image.height) * scale).rounded())
        guard targetWidth > 0, targetHeight > 0 else { return image }

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Text normalisation

    /// Strips whitespace, folds the letters OCR confuses with digits, then
    /// keeps only the characters an expression may contain.
    static func cleanText(_ text: String) -> String {
        var result = text.filter { !$0.isWhitespace }

        let substitutions: [(Character, Character)] = [
            ("o", "0"), ("O", "0"),
            ("l", "1"), ("i", "1"), ("I", "1"),
            ("z", "2"), ("Z", "2"),
            ("s", "5"), ("S", "5"),
            ("b", "6"), ("h", "6"),
            ("B", "8"),
            ("g", "9"),
            ("x", "*"), ("X", "*"),
            ("÷", "/"),
            (":", "="),
            ("_", "-"),
        ]
        for (from, to) in substitutions {
            result = result.replacingOccurrences(of: String(from), with: String(to))
        }

        return String(result.filter { $0.isASCII && ("0123456789+-*/=?".contains($0)) })
    }

    /// Evaluates `"1+2=?"` style expressions. Only a single operation is
    /// supported, which is all the captcha ever asks for.
    static func calculateExpression(_ expression: String) -> String? {
        guard !expression.isEmpty else { return nil }

        var body = String(expression.prefix { $0 != "=" })
        while let last = body.last, last == "?" || last == "-" {
            body.removeLast()
        }
        guard !body.isEmpty else { return nil }

        // Kotlin scans the operator list in order and takes the first operator
        // that occurs anywhere, rather than the leftmost operator overall.
        var operatorIndex = -1
        var operatorSymbol: Character = " "
        for candidate in ["+", "-", "*", "/"] as [Character] {
            if let index = body.firstIndex(of: candidate) {
                operatorIndex = body.distance(from: body.startIndex, to: index)
                operatorSymbol = candidate
                break
            }
        }

        if operatorIndex == -1 {
            let isNumeric = !body.isEmpty && body.allSatisfy { $0.isASCII && $0.isNumber }
            return isNumeric ? body : nil
        }

        let leftText = String(body.prefix(operatorIndex))
        let rightText = String(body.dropFirst(operatorIndex + 1))
        guard let left = Int(leftText), let right = Int(rightText) else {
            Log.error("CaptchaSolver", "Calculation Error: \(expression)")
            return nil
        }

        switch operatorSymbol {
        case "+": return String(left + right)
        case "-": return String(left - right)
        case "*": return String(left * right)
        case "/": return right != 0 ? String(left / right) : nil
        default: return nil
        }
    }
}

/// Guards a continuation so a request that both throws and fires its completion
/// handler cannot resume it twice.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var continuation: CheckedContinuation<String?, Never>?

    func attach(_ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: String?) {
        lock.lock()
        guard !didResume, let continuation else {
            lock.unlock()
            return
        }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
