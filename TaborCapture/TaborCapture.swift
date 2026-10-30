import ExtensionKit
import LockedCameraCapture
import SwiftUI

/// The Lock Screen camera (#107): the Catch control on a locked phone opens this rather than
/// asking for Face ID. It only takes photos; the app reads them once you've unlocked.
@main
struct TaborCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            CaptureView(session: session)
        }
    }
}
