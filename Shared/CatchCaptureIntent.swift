import AppIntents
import Foundation

/// The Catch control's intent (#107). A camera capture intent: on a locked phone the system
/// opens TABOR's Lock Screen camera (TaborCapture) without asking for Face ID, and it lets
/// Camera Control open TABOR. On an unlocked phone the app opens on CATCH. Compiled into the
/// app, the controls and the capture extension, as the system wants.
struct CatchCaptureIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "Open the TABOR camera"
    static let description = IntentDescription("Opens TABOR straight to the camera, even on a locked phone.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !CAPTURE_EXTENSION
        NotificationCenter.default.post(name: .taborOpenCatch, object: nil)
        #endif
        return .result()
    }
}
