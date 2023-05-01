import Foundation
import SwiftSignalKit
import AVFoundation

private final class CameraContext {
    private let queue: Queue
    private let session = AVCaptureSession()
    private let device: CameraDevice
    private let input = CameraInput()
    private let output = CameraOutput()
    
    private let initialConfiguration: Camera.Configuration
    private var invalidated = false
    
    private let detectedCodesPipe = ValuePipe<[CameraCode]>()
    fileprivate let changingPositionPromise = ValuePromise<Bool>(false)
    
    var previewNode: CameraPreviewNode? {
        didSet {
            self.previewNode?.prepare()
        }
    }
    
    var previewView: CameraPreviewView? {
        didSet {
            
        }
    }
    
    private let filter = CameraTestFilter()
    
    private var videoOrientation: AVCaptureVideoOrientation?
    init(queue: Queue, configuration: Camera.Configuration, metrics: Camera.Metrics) {
        self.queue = queue
        self.initialConfiguration = configuration
        
        self.device = CameraDevice()
        self.device.configure(for: self.session, position: configuration.position)
        
        self.configure {
            self.session.sessionPreset = configuration.preset
            self.input.configure(for: self.session, device: self.device, audio: configuration.audio)
            self.output.configure(for: self.session, configuration: configuration)
        }
        
        self.output.processSampleBuffer = { [weak self] pixelBuffer, connection in
            guard let self else {
                return
            }
            if let previewView = self.previewView, !self.changingPosition {
                let videoOrientation = connection.videoOrientation
                if #available(iOS 13.0, *) {
                    previewView.mirroring = connection.inputPorts.first?.sourceDevicePosition == .front
                }
                if let rotation = CameraPreviewView.Rotation(with: .portrait, videoOrientation: videoOrientation, cameraPosition: self.device.position) {
                    previewView.rotation = rotation
                }
                if #available(iOS 13.0, *), connection.inputPorts.first?.sourceDevicePosition == .front {
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    previewView.captureDeviceResolution = CGSize(width: width, height: height)
                }
                previewView.pixelBuffer = pixelBuffer
                Queue.mainQueue().async {
                    self.videoOrientation = videoOrientation
                }
            }
        }
        
        self.output.processFaceLandmarks = { [weak self] observations in
            guard let self else {
                return
            }
            if let previewView = self.previewView {
                previewView.drawFaceObservations(observations)
            }
        }
        
        self.output.processCodes = { [weak self] codes in
            self?.detectedCodesPipe.putNext(codes)
        }
    }
    
    func startCapture() {
        guard !self.session.isRunning else {
            return
        }
        self.session.startRunning()
    }
    
    func stopCapture(invalidate: Bool = false) {
        if invalidate {
            self.configure {
                self.input.invalidate(for: self.session)
                self.output.invalidate(for: self.session)
            }
        }
        
        self.session.stopRunning()
    }
    
    func focus(at point: CGPoint) {
        self.device.setFocusPoint(point, focusMode: .continuousAutoFocus, exposureMode: .continuousAutoExposure, monitorSubjectAreaChange: true)
    }
    
    func setFps(_ fps: Float64) {
        self.device.fps = fps
    }
    
    private var changingPosition = false {
        didSet {
            if oldValue != self.changingPosition {
                self.changingPositionPromise.set(self.changingPosition)
            }
        }
    }
    func togglePosition() {
        self.configure {
            self.input.invalidate(for: self.session)
            let targetPosition: Camera.Position
            if case .back = self.device.position {
                targetPosition = .front
            } else {
                targetPosition = .back
            }
            self.changingPosition = true
            self.device.configure(for: self.session, position: targetPosition)
            self.input.configure(for: self.session, device: self.device, audio: self.initialConfiguration.audio)
            self.queue.after(0.7) {
                self.changingPosition = false
            }
        }
    }
    
    public func setPosition(_ position: Camera.Position) {
        self.configure {
            self.input.invalidate(for: self.session)
            self.device.configure(for: self.session, position: position)
            self.input.configure(for: self.session, device: self.device, audio: self.initialConfiguration.audio)
        }
    }
    
    private func configure(_ f: () -> Void) {
        self.session.beginConfiguration()
        f()
        self.session.commitConfiguration()
    }
    
    var hasTorch: Signal<Bool, NoError> {
        return self.device.isTorchAvailable
    }
    
    func setTorchActive(_ active: Bool) {
        self.device.setTorchActive(active)
    }
    
    var isFlashActive: Signal<Bool, NoError> {
        return self.output.isFlashActive
    }
    
    private var _flashMode: Camera.FlashMode = .off {
        didSet {
            self._flashModePromise.set(self._flashMode)
        }
    }
    private var _flashModePromise = ValuePromise<Camera.FlashMode>(.off)
    var flashMode: Signal<Camera.FlashMode, NoError> {
        return self._flashModePromise.get()
    }
    
    func setFlashMode(_ mode: Camera.FlashMode) {
        self._flashMode = mode
        
//        if mode == .on {
//            self.output.faceLandmarks = true
//            //self.output.activeFilter = self.filter
//        } else if mode == .off {
//            self.output.faceLandmarks = false
//            //self.output.activeFilter = nil
//        }
    }
    
    func setZoomLevel(_ zoomLevel: CGFloat) {
        self.device.setZoomLevel(zoomLevel)
    }
    
    func takePhoto() -> Signal<PhotoCaptureResult, NoError> {
        return self.output.takePhoto(orientation: self.videoOrientation ?? .portrait, flashMode: .off) //self._flashMode)
    }
    
    public func startRecording() -> Signal<Double, NoError> {
        return self.output.startRecording()
    }
    
    public func stopRecording() -> Signal<String?, NoError> {
        return self.output.stopRecording()
    }
    
    var detectedCodes: Signal<[CameraCode], NoError> {
        return self.detectedCodesPipe.signal()
    }
}

public final class Camera {
    public typealias Preset = AVCaptureSession.Preset
    public typealias Position = AVCaptureDevice.Position
    public typealias FocusMode = AVCaptureDevice.FocusMode
    public typealias ExposureMode = AVCaptureDevice.ExposureMode
    public typealias FlashMode = AVCaptureDevice.FlashMode
    
    public struct Configuration {
        let preset: Preset
        let position: Position
        let audio: Bool
        let photo: Bool
        let metadata: Bool
        
        public init(preset: Preset, position: Position, audio: Bool, photo: Bool, metadata: Bool) {
            self.preset = preset
            self.position = position
            self.audio = audio
            self.photo = photo
            self.metadata = metadata
        }
    }
    
    private let queue = Queue()
    private var contextRef: Unmanaged<CameraContext>?

    private weak var previewView: CameraPreviewView?
    
    public let metrics: Camera.Metrics
    
    public init(configuration: Camera.Configuration = Configuration(preset: .hd1920x1080, position: .back, audio: true, photo: false, metadata: false)) {
        self.metrics = Camera.Metrics(model: DeviceModel.current)
        
        self.queue.async {
            let context = CameraContext(queue: self.queue, configuration: configuration, metrics: self.metrics)
            self.contextRef = Unmanaged.passRetained(context)
        }
    }
    
    deinit {
        let contextRef = self.contextRef
        self.queue.async {
            contextRef?.release()
        }
    }
    
    public func startCapture() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.startCapture()
            }
        }
    }
    
    public func stopCapture(invalidate: Bool = false) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.stopCapture(invalidate: invalidate)
            }
        }
    }
    
    public func togglePosition() {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.togglePosition()
            }
        }
    }
    
    public func setPosition(_ position: Camera.Position) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setPosition(position)
            }
        }
    }
    
    public func takePhoto() -> Signal<PhotoCaptureResult, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.takePhoto().start(next: { value in
                        subscriber.putNext(value)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public func startRecording() -> Signal<Double, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.startRecording().start(next: { value in
                        subscriber.putNext(value)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public func stopRecording() -> Signal<String?, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.stopRecording().start(next: { value in
                        subscriber.putNext(value)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public func focus(at point: CGPoint) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.focus(at: point)
            }
        }
    }
    
    public func setFps(_ fps: Double) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setFps(fps)
            }
        }
    }
    
    public func setFlashMode(_ flashMode: FlashMode) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setFlashMode(flashMode)
            }
        }
    }
    
    public func setZoomLevel(_ zoomLevel: CGFloat) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setZoomLevel(zoomLevel)
            }
        }
    }
    
    public func setTorchActive(_ active: Bool) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.setTorchActive(active)
            }
        }
    }
    
    public var hasTorch: Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.hasTorch.start(next: { hasTorch in
                        subscriber.putNext(hasTorch)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public var isFlashActive: Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.isFlashActive.start(next: { isFlashActive in
                        subscriber.putNext(isFlashActive)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }
    
    public var flashMode: Signal<Camera.FlashMode, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.flashMode.start(next: { flashMode in
                        subscriber.putNext(flashMode)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
            }
            return disposable
        }
    }

    public func attachPreviewNode(_ node: CameraPreviewNode) {
        let nodeRef: Unmanaged<CameraPreviewNode> = Unmanaged.passRetained(node)
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.previewNode = nodeRef.takeUnretainedValue()
                nodeRef.release()
            } else {
                Queue.mainQueue().async {
                    nodeRef.release()
                }
            }
        }
    }
    
    public func attachPreviewView(_ view: CameraPreviewView) {
        self.previewView = view
        let viewRef: Unmanaged<CameraPreviewView> = Unmanaged.passRetained(view)
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.previewView = viewRef.takeUnretainedValue()
                viewRef.release()
            } else {
                Queue.mainQueue().async {
                    viewRef.release()
                }
            }
        }
    }

    public var detectedCodes: Signal<[CameraCode], NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.detectedCodes.start(next: { codes in
                        subscriber.putNext(codes)
                    }))
                }
            }
            return disposable
        }
    }
    
    public var changingPosition: Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.queue.async {
                if let context = self.contextRef?.takeUnretainedValue() {
                    disposable.set(context.changingPositionPromise.get().start(next: { value in
                        subscriber.putNext(value)
                    }))
                }
            }
            return disposable
        }
    }
}

public final class CameraHolder {
    public let camera: Camera
    public let previewView: CameraPreviewView
    
    public init(camera: Camera, previewView: CameraPreviewView) {
        self.camera = camera
        self.previewView = previewView
    }
}
