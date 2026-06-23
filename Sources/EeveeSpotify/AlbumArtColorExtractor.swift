import UIKit

/// Extracts a small palette of dominant colors from an image, for the
/// karaoke background gradient — the iOS equivalent of what Android's
/// Palette API does (already used for this exact purpose in the Velora
/// project), but iOS has no built-in equivalent, so this implements a
/// simple from-scratch quantization instead of leaning on a system API.
///
/// Approach: downsample the image to a small grid (cheap, avoids scanning
/// every pixel of a full-resolution image), bucket pixels into a coarse
/// color-space grid (quantization), find the most populous buckets, and
/// return their average colors — a simplified median-cut/k-means-ish
/// technique. Not as visually refined as Android's Palette API (which
/// also classifies vibrant/muted/dark/light swatches), but sufficient for
/// "a few colors that look like they came from this image" rather than a
/// flat placeholder gradient.
struct AlbumArtColorExtractor {
    /// Returns up to `count` dominant colors, ordered most-to-least
    /// populous. Returns an empty array if the image can't be processed
    /// (callers should fall back to placeholder colors in that case).
    static func dominantColors(from image: UIImage, count: Int = 3) -> [UIColor] {
        guard let pixels = downsampledPixels(image, targetSize: 32) else { return [] }

        // Quantize each channel into 6 buckets (0-5) — coarse enough to
        // group visually-similar colors together, fine enough to still
        // distinguish genuinely different hues.
        let bucketsPerChannel = 6
        var buckets: [Int: (count: Int, rSum: Int, gSum: Int, bSum: Int)] = [:]

        for pixel in pixels {
            let (r, g, b, a) = pixel
            guard a > 200 else { continue } // skip near-transparent pixels

            // Skip near-black and near-white — these tend to be letterboxing
            // or background padding rather than the actual artwork's color,
            // and dominate buckets in a way that produces a washed-out
            // gradient otherwise.
            let brightness = (r + g + b) / 3
            guard brightness > 20 && brightness < 235 else { continue }

            let rb = (r * bucketsPerChannel) / 256
            let gb = (g * bucketsPerChannel) / 256
            let bb = (b * bucketsPerChannel) / 256
            let key = rb * bucketsPerChannel * bucketsPerChannel + gb * bucketsPerChannel + bb

            var entry = buckets[key] ?? (0, 0, 0, 0)
            entry.count += 1
            entry.rSum += r
            entry.gSum += g
            entry.bSum += b
            buckets[key] = entry
        }

        let topBuckets = buckets.values.sorted { $0.count > $1.count }.prefix(count)
        guard !topBuckets.isEmpty else { return [] }

        return topBuckets.map { entry in
            UIColor(
                red: CGFloat(entry.rSum / entry.count) / 255.0,
                green: CGFloat(entry.gSum / entry.count) / 255.0,
                blue: CGFloat(entry.bSum / entry.count) / 255.0,
                alpha: 1.0
            )
        }
    }

    /// Renders the image into a small RGBA buffer and returns each pixel
    /// as (r, g, b, a) in 0...255. Downsampling first keeps this cheap —
    /// we don't need per-pixel precision on a 1000x1000 album art image,
    /// a 32x32 grid is plenty to find dominant colors.
    private static func downsampledPixels(
        _ image: UIImage,
        targetSize: Int
    ) -> [(r: Int, g: Int, b: Int, a: Int)]? {
        guard let cgImage = image.cgImage else { return nil }

        let width = targetSize
        let height = targetSize
        var rawData = [UInt8](repeating: 0, count: width * height * 4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels: [(r: Int, g: Int, b: Int, a: Int)] = []
        pixels.reserveCapacity(width * height)
        for i in stride(from: 0, to: rawData.count, by: 4) {
            pixels.append((
                r: Int(rawData[i]),
                g: Int(rawData[i + 1]),
                b: Int(rawData[i + 2]),
                a: Int(rawData[i + 3])
            ))
        }
        return pixels
    }
}

/// Locates the currently-displayed album art image without any new network
/// fetch — Spotify's own Now Playing UI already has the artwork loaded
/// into a UIImageView somewhere in its view hierarchy, so this walks
/// `nowPlayingScrollViewController.view`'s subviews (the same safe,
/// in-process technique SponsorBlockOverlay already uses to find sliders)
/// to find it, rather than guessing at internal KVC keys or standing up a
/// new authenticated request to fetch artwork ourselves.
struct AlbumArtLocator {
    /// Heuristic: the largest UIImageView with a non-nil image in the Now
    /// Playing view's subtree is almost certainly the album art — it's
    /// typically the single largest image element on that screen by a wide
    /// margin (icon-sized images like buttons are much smaller).
    static func currentAlbumArt() -> UIImage? {
        guard let controller = nowPlayingScrollViewController as? UIViewController,
              let rootView = controller.view else { return nil }

        var best: (view: UIImageView, area: CGFloat)?

        func walk(_ view: UIView) {
            if let imageView = view as? UIImageView, imageView.image != nil {
                let area = imageView.bounds.width * imageView.bounds.height
                if area > (best?.area ?? 0) {
                    best = (imageView, area)
                }
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(rootView)

        return best?.view.image
    }
}
