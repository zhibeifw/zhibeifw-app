import SwiftUI

// 封面图在 iPhone、Apple TV 上是 UIImage，在 Mac 上是 NSImage；共用代码只认 PlatformImage。
#if os(macOS)
import AppKit

typealias PlatformImage = NSImage

extension NSImage {
    /// 按像素建图（1 点 = 1 像素），和 UIImage(cgImage:) 的尺寸含义一致。
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    var scale: CGFloat { 1 }
}

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif
