// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging
import Vision

public struct RecognizedBarcode: Sendable, Equatable {
    public let payload: String
    public let symbology: String
    public let rect: ImageRect
    /// True when the payload was binary and is shown as hex rather than text.
    public let isBinary: Bool
}

public enum BarcodeRecognizer {

    /// Decode QR and other codes.
    ///
    /// Run in the same `VNImageRequestHandler` pass as text recognition where
    /// possible: one image decode serves both, so the pair costs about as much
    /// as the slower of the two.
    public static func recognize(in image: RasterImage) -> [RecognizedBarcode] {
        let request = VNDetectBarcodesRequest()
        // ORDER MATTERS. Setting the revision resets `symbologies` to the full
        // set for that revision, so assigning symbologies first would silently
        // discard the filter.
        request.revision = VNDetectBarcodesRequestRevision4
        request.symbologies = [.qr, .microQR, .aztec, .dataMatrix, .pdf417, .ean13, .code128]

        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }

        let width = image.cgImage.width
        let height = image.cgImage.height

        return (request.results ?? []).compactMap { observation in
            let rect = TextRecognizer.imageRect(
                from: observation.boundingBox, width: width, height: height
            )

            if let payload = observation.payloadStringValue {
                return RecognizedBarcode(
                    payload: payload,
                    symbology: observation.symbology.rawValue,
                    rect: rect,
                    isBinary: false
                )
            }
            // A binary payload has no string form. Reporting "no code found"
            // would be wrong — there is a code, it just is not text.
            guard let data = observation.payloadData, !data.isEmpty else { return nil }
            return RecognizedBarcode(
                payload: data.map { String(format: "%02X", $0) }.joined(),
                symbology: observation.symbology.rawValue,
                rect: rect,
                isBinary: true
            )
        }
    }
}

/// Finds the regions occupied by text, for redaction.
public enum TextRegionMasker {

    /// Rects covering the text inside `region`, in image pixels.
    ///
    /// `region` is expressed in image pixels like everything else; the
    /// normalised, bottom-left `regionOfInterest` Vision wants is built here so
    /// no caller has to know about it.
    public static func textRegions(
        in image: RasterImage,
        within region: ImageRect? = nil,
        matching pattern: (any RegexComponent)? = nil,
        padding: Double = 2
    ) -> [ImageRect] {
        let width = image.cgImage.width
        let height = image.cgImage.height
        guard width > 0, height > 0 else { return [] }

        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0

        if let region {
            // regionOfInterest is normalised, bottom-left origin, and relative
            // to the FULL image — results still come back normalised to the
            // full image too. Getting either wrong puts redaction boxes in the
            // wrong quadrant, which is a privacy failure, not a cosmetic one.
            request.regionOfInterest = CGRect(
                x: region.minX.value / Double(width),
                y: (Double(height) - region.maxY.value) / Double(height),
                width: region.width.value / Double(width),
                height: region.height.value / Double(height)
            )
        }

        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }

        var rects: [ImageRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }

            if let pattern {
                // Redact only what matches — an email or a token — rather than
                // the whole line it sits on.
                for match in candidate.string.ranges(of: pattern) {
                    let range = NSRange(match, in: candidate.string)
                    guard
                        let swiftRange = Range(range, in: candidate.string),
                        let box = try? candidate.boundingBox(for: swiftRange)
                    else { continue }
                    rects.append(
                        TextRecognizer.imageRect(
                            from: box.boundingBox, width: width, height: height
                        ).outsetBy(ImagePx(padding))
                    )
                }
            } else {
                rects.append(
                    TextRecognizer.imageRect(
                        from: observation.boundingBox, width: width, height: height
                    ).outsetBy(ImagePx(padding))
                )
            }
        }

        // Clip to the requested region: Vision occasionally returns a box that
        // straddles the boundary, and a redaction spilling outside what the
        // user selected is surprising.
        guard let region else { return rects }
        return rects.compactMap {
            let clipped = $0.intersection(region)
            return clipped.isEmpty ? nil : clipped
        }
    }
}
