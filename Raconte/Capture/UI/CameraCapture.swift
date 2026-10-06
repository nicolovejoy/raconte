#if os(iOS)
import SwiftUI
import UIKit

/// Thin `UIImagePickerController` wrapper for taking a journal cover photo
/// (issue #14 part 3). iOS only — macOS has no camera picker; the cover sheet offers
/// `PhotosPicker` there instead. Hands back JPEG bytes (or nil on cancel) rather than a
/// `UIImage`, so nothing above this file touches UIKit types.
struct CameraCapture: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void
        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Not `jpegData(compressionQuality:)`: that drops the camera's metadata, so
            // the shot carried no `DateTimeOriginal` and never suggested a backdate
            // (#181). The metadata arrives separately in `.mediaMetadata`; `CameraJPEG`
            // writes it back around the same pixels, orientation included.
            // The old encode stays as the fallback: a `nil` here reads as CANCEL to both
            // picker sheets, so a shot must never be lost over its metadata.
            guard let image = info[.originalImage] as? UIImage else { return onFinish(nil) }
            let withMetadata = image.cgImage.flatMap { cgImage in
                CameraJPEG.encode(image: cgImage,
                                  orientation: Self.exifOrientation(image.imageOrientation),
                                  metadata: info[.mediaMetadata] as? [CFString: Any])
            }
            onFinish(withMetadata ?? image.jpegData(compressionQuality: 0.9))
        }

        /// `UIImage.Orientation` → EXIF orientation. Same mapping as UIKit's
        /// `CGImagePropertyOrientation.init(_:)`, which the generic-iOS build does not see.
        static func exifOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
            switch orientation {
            case .up: .up
            case .upMirrored: .upMirrored
            case .down: .down
            case .downMirrored: .downMirrored
            case .left: .left
            case .leftMirrored: .leftMirrored
            case .right: .right
            case .rightMirrored: .rightMirrored
            @unknown default: .up
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
#endif
