import SwiftUI
import UIKit

/// A single-photo camera capture (`UIImagePickerController` with `.camera`) returning one `UIImage` - the right
/// shape for an avatar portrait, unlike `DocumentScannerView` (which does document edge-detection/multi-page).
/// Present only when `UIImagePickerController.isSourceTypeAvailable(.camera)` (false on Simulator).
struct CameraPicker: UIViewControllerRepresentable {
    var onComplete: (UIImage) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if UIImagePickerController.isCameraDeviceAvailable(.front) { picker.cameraDevice = .front }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onComplete(image) } else { parent.onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
    }
}
