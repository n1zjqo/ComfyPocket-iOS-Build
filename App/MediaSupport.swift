import SwiftUI
import UIKit
import PhotosUI
import Photos
import UniformTypeIdentifiers
import ImageIO
import ComfyCore

enum MediaImages {
    static let cache = NSCache<NSString, UIImage>()
    static func image(url: URL, maxPixel: Int = 600) -> UIImage? {
        let key = (url.path + "#" + String(maxPixel)) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key, cost: thumbnail.width * thumbnail.height * 4)
        cache.totalCostLimit = 48 * 1024 * 1024
        return image
    }
}
struct MediaPicker: UIViewControllerRepresentable {
    let video: Bool
    let completion: (Result<URL, Error>) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = video ? .videos : .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(video: video, completion: completion) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let video: Bool
        let completion: (Result<URL, Error>) -> Void
        init(video: Bool, completion: @escaping (Result<URL, Error>) -> Void) { self.video = video; self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { completion(.failure(CancellationError())); return }
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: video ? UTType.movie.identifier : UTType.image.identifier) { url, error in
                let response: Result<URL, Error>
                do {
                    guard let url = url else { throw error ?? ComfyError.invalid("无法读取所选素材，请先下载 iCloud 原件后再试。") }
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: destination)
                    response = .success(destination)
                } catch { response = .failure(error) }
                DispatchQueue.main.async { self.completion(response) }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum PhotoExporter {
    static func save(url: URL, video: Bool) async throws {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { throw ComfyError.invalid("未获得相册写入权限，请在系统设置中允许添加照片。") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: video ? .video : .photo, fileURL: url, options: nil)
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? ComfyError.invalid("保存失败，系统相册可能不支持该文件格式。")) }
            }
        }
    }
}
