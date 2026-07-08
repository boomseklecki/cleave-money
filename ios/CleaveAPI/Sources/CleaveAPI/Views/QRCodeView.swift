import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// Renders a QR code for a string (e.g. the join link), regenerating only when the value changes.
/// Scanning it with the Camera opens the Universal Link (the app, or the web confirm page if not
/// installed).
struct QRCodeView: View {
    let string: String

    @State private var image: UIImage?

    var body: some View {
        SwiftUI.Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)  // keep the modules crisp when scaled
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        // Generate off the main thread - CIContext.createCGImage on the 10×-scaled output is enough to
        // hitch the UI if run on the main actor.
        .task(id: string) {
            let value = string
            image = await Task.detached(priority: .userInitiated) { QRCode.make(value) }.value
        }
    }
}

private enum QRCode {
    private static let context = CIContext()  // reusable; rendering a small code is cheap

    static func make(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
