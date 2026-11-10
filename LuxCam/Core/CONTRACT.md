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
    func set(look: LookPreset)              // ignored when !state.gear.body.allows(look)
    func set(manual: ManualSettings)
    func set(video: VideoFormatSettings)
    func set(photoFormat: PhotoFormat)      // HEIF or Apple ProRAW (DNG); ProRAW ignores looks
    func clearError()                       // main thread: clears state.errorMessage (error banner dismissed)
    func forgetAssets(_ ids: [String])      // drop deleted/missing assets from state.recentAssetIDs (+ persist)
    func set(gear: GearSelection)           // body + lens; normalises lens, enforces body.allows(look)
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
    init(frames: PreviewFrameSource, look: LookPreset, gear: GearSelection = GearSelection(),
         aperture: Float? = nil, renderer: LookRendering,
         onTap: @escaping (_ devicePoint: CGPoint) -> Void,
         onTapViewPoint: ((CGPoint) -> Void)? = nil)
}
```

## UI + App (owner D) — `LuxCam/UI/`, `LuxCam/App/`
`@main struct LuxCamApp`, `ContentView` owning `@StateObject var camera = CameraService(lookRenderer: LookRenderer.shared)`.

## Gear (Core/Gear.swift)
- `lens.equivalentFocalLength(on: body)` (focal length × body cropFactor; M8 = 1.33, Hasselblad = 0.79) selects the PHYSICAL back camera (ultra wide / wide / telephoto)
  plus a residual `videoZoomFactor` in PHOTO and VIDEO. PORTRAIT and CINEMATIC keep their own devices.
- Body `photoAspect` crops photos (not ProRAW DNGs) and masks the preview.
- Body `character` + lens `character` are applied after the look via
  `LookRendering.apply(_:gear:aperture:cheap:to:isLogSource:)`.

## Orientation
- The interface is locked to portrait (Info.plist). Like the stock Camera app, landscape is detected
  from the PHYSICAL device orientation (CoreMotion gravity), so it works with the rotation lock on.
- The preview is never rotated: frames are always oriented `.right` (portrait interface), which shows the
  scene correctly however the phone is held. Tap mapping therefore stays the portrait mapping.
- In physical landscape only the overlay UI (bars, chips, dials, mode strip, shutter rail, HUD) is laid
  out in a rotated (±90°) landscape canvas, so all text reads correctly.
- Capture uses `AVCaptureDevice.RotationCoordinator` (`videoRotationAngleForHorizonLevelCapture`, gravity
  based) at photo capture / record start. Never rotate the video data output connection.

## Captured media history
- Every successful save to Photos records the created asset's `localIdentifier`
  (`PHAssetCreationRequest.placeholderForCreatedAsset`) at the front of `state.recentAssetIDs`,
  persisted in UserDefaults key `LuxCam.recentAssetIDs` and restored in `CameraService.init`.
- The in-app viewer (UI/MediaViewer) needs read access: it requests `PHPhotoLibrary.requestAuthorization(for: .readWrite)`
  when first opened (limited access is fine for assets the app created).
