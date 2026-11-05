# Module contract

All modules compile into one target (`LuxCam`, Swift 5 mode, iOS 17.0+). Shared types live in
`Core/CameraTypes.swift` (do not edit without the lead).

## Capture (owner A) — `LuxCam/Capture/`
```swift
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var state: CameraState
    let frames: PreviewFrameSource          // preview frames (BGRA, sensor orientation = landscape-right)
    init(lookRenderer: LookRendering)

    func start()                            // requests permission, configures + starts session (non-blocking)
    func stop()
    func set(mode: CameraMode)
    func set(look: LookPreset)
    func set(manual: ManualSettings)
    func set(video: VideoFormatSettings)
    func set(simulatedAperture: Float)
    func focus(at devicePoint: CGPoint)     // point of interest in device coordinates (0...1), resets focus to auto
    func capturePhoto()
    func toggleRecording()
}
```
All `AVCaptureSession` work happens on a private serial `sessionQueue`; `state` is only mutated on main.

## Looks (owner B) — `LuxCam/Looks/`
```swift
final class LookRenderer: LookRendering, @unchecked Sendable {
    static let shared: LookRenderer
    func apply(_ preset: LookPreset, to image: CIImage, isLogSource: Bool) -> CIImage
}
```

## Preview (owner C) — `LuxCam/Preview/`
```swift
struct CameraPreviewView: UIViewRepresentable {
    init(frames: PreviewFrameSource, look: LookPreset, renderer: LookRendering,
         onTap: @escaping (_ devicePoint: CGPoint) -> Void)
}
```

## UI + App (owner D) — `LuxCam/UI/`, `LuxCam/App/`
`@main struct LuxCamApp`, `ContentView` owning `@StateObject var camera = CameraService(lookRenderer: LookRenderer.shared)`.
