import AppKit

/// The book image behind a page's attachment, for the reader's zoom panel.
public enum EPUBAttachmentImage {
    /// The long side a zoom decode reaches.
    public static let zoomPixelSize = 4_096

    /// Whether an attachment draws a book image (not an alt-text slot).
    public static func isImage(_ attachment: NSTextAttachment?) -> Bool {
        attachment?.attachmentCell is EPUBImageCell
    }

    /// The image at display resolution, usually already decoded.
    public static func preview(of attachment: NSTextAttachment) -> CGImage? {
        (attachment.attachmentCell as? EPUBImageCell)?.displayImage
    }

    /// Whether the display decode is in memory, so drawing it won't decode now.
    public static func isDecoded(_ attachment: NSTextAttachment) -> Bool {
        (attachment.attachmentCell as? EPUBImageCell)?.isDecoded ?? false
    }

    /// The image decoded large; slow, so call it off the main thread.
    public static func zoomImage(of attachment: NSTextAttachment) -> CGImage? {
        (attachment.attachmentCell as? EPUBImageCell)?.zoomImage(maxPixelSize: zoomPixelSize)
    }
}
