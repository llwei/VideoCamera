//
//  VideoCamera.swift
//  VideoCamera
//
//  Created by Ryan on 2018/12/12.
//  Copyright © 2018 Ryan. All rights reserved.
//

import UIKit
import AVFoundation
import CoreGraphics
import CoreImage

typealias MovieRecordFinishHandle = ((_ outputURL: URL?) -> Void)
typealias MetaDataIdentifyHandle = ((_ metadataObjects: [AVMetadataObject]) -> Void)

// MARK: - VideoCamera

class VideoCamera: NSObject {
    
    enum OutputMode {
        /// 默认相机
        case system
        /// 机器码识别相机
        case metaData(objectTypes: [AVMetadataObject.ObjectType])
        /// 帧数据相机
        case bufferData
    }
    
    /// 录音功能开关
    private var audioEnable: Bool = false {
        didSet {
            sessionQueue.async { [unowned self] in
                guard self.authorizeAvailable == true else { return }
                if self.audioEnable {
                    guard let deviceInput = AVCaptureDevice.default(for: .audio) else { return }
                    do {
                        self.session.beginConfiguration()
                        let audioInput = try AVCaptureDeviceInput(device: deviceInput)
                        if self.session.canAddInput(audioInput) {
                            self.session.addInput(audioInput)
                            self.audioDeviceInput = audioInput
                        }
                        self.session.commitConfiguration()
                    } catch {
                        print("音频输入添加失败：\(error.localizedDescription)")
                    }
                } else {
                    if let audioInput = self.audioDeviceInput {
                        self.session.beginConfiguration()
                        self.session.removeInput(audioInput)
                        self.session.commitConfiguration()
                    }
                }
            }
        }
    }
    /// 是否正在录像
    private var recording: Bool = false
    
    /// 执行线程
    private let sessionQueue = DispatchQueue(label: "VideoCamera.sessionQueue")
    /// 相机权限
    private var authorizeAvailable: Bool = false
    /// 录像后台处理
    private var backgroundRecordingID: UIBackgroundTaskIdentifier?
    
    /// 相机模式
    private var outputMode: OutputMode
    /// 预览图层
    private var preview: VideoCameraPreview
    /// 会话
    private let session: AVCaptureSession = AVCaptureSession()
    /// 视频输入
    private var videoDeviceInput: AVCaptureDeviceInput?
    /// 音频输入
    private var audioDeviceInput: AVCaptureDeviceInput?
    
    /// OutputMode.system 图片输出
    private lazy var stillImageOutput = AVCaptureStillImageOutput()
    /// OutputMode.system 视频输出
    private lazy var movieFileOutput = AVCaptureMovieFileOutput()
    /// OutputMode.metaData 数据码输出
    private lazy var metaDataOutput = AVCaptureMetadataOutput()
    /// OutputMode.bufferData 视频输出
    private lazy var videoDataOutput = AVCaptureVideoDataOutput()
    /// OutputMode.bufferData 音频输出
    private lazy var audioDataOutput = AVCaptureAudioDataOutput()
    
    /// 滤镜
    private var theFilter: CIFilter?
    /// 资源写入器
    private lazy var assertWriter = AssetWriter()
    
    private var movieOutputHandle: MovieRecordFinishHandle?
    private var metaDataIdentifyHandle: MetaDataIdentifyHandle?
    
    
    init(preview: VideoCameraPreview, outputMode: OutputMode, authorizedHandle: ((_ granted: Bool) -> Void)? = nil) {
        self.preview = preview
        self.outputMode = outputMode
        super.init()
        
        // 触发检测屏幕旋转通知
        if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        
        // 摄像头授权判断
        checkCameraAuthorizationStatus()
        
        // 录像后台处理
        sessionQueue.async { [unowned self] in
            DispatchQueue.main.async {
                authorizedHandle?(self.authorizeAvailable)
            }
            guard self.authorizeAvailable == true else {
                return
            }
            self.backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
        }
        
        // 配置显示图层
        setupCapturePreview()
        
        // 配置会话输入流
        setupCaptureSessionInputs()
        
        // 配置会话输出流
        setupCaptureSessionOutputs()
        
    }
    
    // 摄像头授权判断
    private func checkCameraAuthorizationStatus() {
        switch AVCaptureDevice.authorizationStatus(for: AVMediaType.video) {
        case .authorized:
            authorizeAvailable = true
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: AVMediaType.video) { (granted) in
                self.authorizeAvailable = granted
                self.sessionQueue.resume()
            }
        default:
            authorizeAvailable = false
        }
    }
    
    // 配置显示图层
    private func setupCapturePreview() {
        preview.backgroundColor = UIColor.white
        preview.session = session
    }
    
    // 配置输入流
    private func setupCaptureSessionInputs() {
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            
            self.session.beginConfiguration()
            if let backCamera = self.camera(at: .back) {
                do {
                    let deviceInput = try AVCaptureDeviceInput(device: backCamera)
                    if self.session.canAddInput(deviceInput) {
                        self.session.addInput(deviceInput)
                        self.videoDeviceInput = deviceInput
                        
                        // 使预览图层方向与屏幕方向一致
                        DispatchQueue.main.async {
                            let orientation = AVCaptureVideoOrientation(rawValue: UIApplication.shared.statusBarOrientation.rawValue) ?? .portrait
                            (self.preview.layer as? AVCaptureVideoPreviewLayer)?.connection?.videoOrientation = orientation
                        }
                    }
                } catch {
                    print("后置摄像头加入会话失败：\(error.localizedDescription)")
                }
            }
            self.session.commitConfiguration()
        }
    }
    
    // 配置会话输出流
    private func setupCaptureSessionOutputs() {
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            
            self.session.beginConfiguration()
            switch self.outputMode {
            case .system:
                // 系统默认模式
                if self.session.canAddOutput(self.stillImageOutput) {
                    self.stillImageOutput.outputSettings = [AVVideoCodecKey: AVVideoCodecJPEG]
                    self.session.addOutput(self.stillImageOutput)
                }
                if self.session.canAddOutput(self.movieFileOutput) {
                    self.movieFileOutput.connection(with: .video)?.preferredVideoStabilizationMode = .auto
                    self.session.addOutput(self.movieFileOutput)
                }
                
            case .metaData(let objectTypes):
                // 扫描机器码
                if self.session.canAddOutput(self.metaDataOutput) {
                    self.metaDataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    self.metaDataOutput.metadataObjectTypes = objectTypes
                    self.session.addOutput(self.metaDataOutput)
                }
                
            case .bufferData:
                // 帧数据
                let orientation = AVCaptureVideoOrientation(rawValue: UIApplication.shared.statusBarOrientation.rawValue) ?? .portrait
                if self.session.canAddOutput(self.videoDataOutput) {
                    self.videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String : Int(kCVPixelFormatType_32BGRA)]
                    self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "VideoCamera.videoDataOutput"))
                    self.videoDataOutput.connection(with: .video)?.videoOrientation = orientation
                    self.session.addOutput(self.videoDataOutput)
                }
                if self.session.canAddOutput(self.audioDataOutput) {
                    self.audioDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "VideoCamera.audioDataOutput"))
                    self.session.addOutput(self.audioDataOutput)
                }
            }
            self.session.commitConfiguration()
        }
    }
    
}

extension VideoCamera {
    
    /// 添加通知监听
    private func addNotificationsObserver() {
        // 预览发生变化
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(VideoCamera.subjectAreaDidChange),
                                               name: .AVCaptureDeviceSubjectAreaDidChange,
                                               object: nil)
        // 会话出错时
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(VideoCamera.sessionRuntimeError(_:)),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)
        // 屏幕旋转时
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(VideoCamera.deviceOrientationDidChange(_:)),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: nil)
    }
    
    /// 预览发生变化
    @objc func subjectAreaDidChange() {
        focusAndExposure(at: CGPoint(x: preview.frame.midX, y: preview.frame.midY),
                         isSubjectAreaChangeMonitoringEnabled: false)
    }
    
    /// 会话出错时
    @objc func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else { return }
        print("会话运行时出错: \(error.localizedDescription)")
        if error.code == AVError.Code.mediaServicesWereReset.rawValue {
            sessionQueue.async { [weak self] in
                self?.session.startRunning()
            }
        }
    }
    
    /// 屏幕旋转时
    @objc func deviceOrientationDidChange(_ notification: Notification) {
        guard !isRecording else { return }
        switch UIDevice.current.orientation {
        case .portrait,
             .portraitUpsideDown,
             .landscapeLeft,
             .landscapeRight:
            let orientation = AVCaptureVideoOrientation(rawValue: UIDevice.current.orientation.rawValue) ?? .portrait
            (preview.layer as? AVCaptureVideoPreviewLayer)?.connection?.videoOrientation = orientation
        default:
            break
        }
    }
}

extension VideoCamera:  AVCaptureFileOutputRecordingDelegate {
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let curBackgroundRecordingID = backgroundRecordingID {
            backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
            if curBackgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
                UIApplication.shared.endBackgroundTask(curBackgroundRecordingID)
            }
        }
        
        movieOutputHandle?(outputFileURL)
    }
    
    
}

extension VideoCamera: AVCaptureMetadataOutputObjectsDelegate {
 
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        metaDataIdentifyHandle?(metadataObjects)
    }
}

extension VideoCamera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 视频
        if self.videoDataOutput == output {
            let cgImage = assertWriter.renderVideo(sampleBuffer: sampleBuffer, filter: filter)
            
            DispatchQueue.main.async {
                self.preview.layer.contents = cgImage
            }
        }
        
        // 音频
        if self.audioDataOutput == output {
            assertWriter.appendAudio(sampleBuffer: sampleBuffer)
        }
    }
    
}

// MARK: -

extension VideoCamera {
    
    /// 开始会话
    func startRunning() {
        guard !session.isRunning else { return }
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            self.addNotificationsObserver()
            self.session.startRunning()
        }
    }
    
    /// 结束会话
    func stopRunning() {
        guard session.isRunning else { return }
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            NotificationCenter.default.removeObserver(self)
            self.session.stopRunning()
        }
    }
    
    /// 当前摄像头
    var curCamera: AVCaptureDevice? {
        return videoDeviceInput?.device
    }
    
    /// 获取指定位置的摄像头
    func camera(at postion: AVCaptureDevice.Position) -> AVCaptureDevice? {
        return AVCaptureDevice.devices(for: .video).filter({ $0.position == postion }).first
    }
    
    /// 切换摄像头
    func toggleCamera(position: AVCaptureDevice.Position) {
        guard !isRecording, let curCamera = curCamera, curCamera.position != position else { return }
        
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable, let targetCamera = self.camera(at: position) else { return }
            
            do {
                let deviceInput = try AVCaptureDeviceInput(device: targetCamera)
                self.session.beginConfiguration()
                if let oldDeviceInput = self.videoDeviceInput {
                    self.session.removeInput(oldDeviceInput)
                }
                if self.session.canAddInput(deviceInput) {
                    self.session.addInput(deviceInput)
                    self.videoDeviceInput = deviceInput
                }
                self.session.commitConfiguration()
            } catch {
                print("切换摄像头失败：\(error.localizedDescription)")
            }
        }
        
    }
    
    /// 设置闪光灯
    func setFlashMode(_ flashMode: AVCaptureDevice.FlashMode) {
        guard let curCamera = curCamera, curCamera.isFlashModeSupported(flashMode) else { return }
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            do {
                try curCamera.lockForConfiguration()
                curCamera.flashMode = flashMode
                curCamera.unlockForConfiguration()
            } catch {
                print("设置闪光灯失败：\(error.localizedDescription)")
            }
        }
    }
    
    /// 设置手电筒
    func setTorchMode(_ torchMode: AVCaptureDevice.TorchMode) {
        guard let curCamera = curCamera, curCamera.isTorchModeSupported(torchMode) else { return }
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            do {
                try curCamera.lockForConfiguration()
                curCamera.torchMode = torchMode
                curCamera.unlockForConfiguration()
            } catch {
                print("设置手电筒失败：\(error.localizedDescription)")
            }
        }
    }
    
    /// 调节手电筒亮度
    func regulateTorchModeOnWithLevel(_ level: Float) {
        guard let curCamera = curCamera, curCamera.isTorchActive else { return }
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            do {
                try curCamera.lockForConfiguration()
                try curCamera.setTorchModeOn(level: level)
                curCamera.unlockForConfiguration()
            } catch {
                print("调节手电筒亮度失败：\(error.localizedDescription)")
            }
        }
    }
    
    /// 指定点聚焦曝光
    func focusAndExposure(at location: CGPoint, isSubjectAreaChangeMonitoringEnabled: Bool = true) {
        guard let layer = preview.layer as? AVCaptureVideoPreviewLayer else { return }
        
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: location)
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable, let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                // 聚焦
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                // 曝光
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                // If subject area change monitoring is enabled, the receiver
                // sends an AVCaptureDeviceSubjectAreaDidChangeNotification whenever it detects
                // a change to the subject area, at which time an interested client may wish
                // to re-focus, adjust exposure, white balance, etc.
                device.isSubjectAreaChangeMonitoringEnabled = isSubjectAreaChangeMonitoringEnabled
                device.unlockForConfiguration()
            } catch {
                print("点击聚焦失败：\(error.localizedDescription)")
            }
        }
    }
    
    /// 录音功能开关
    var isAudioEnable: Bool {
        set {
            audioEnable = newValue
        }
        get {
            return audioEnable
        }
    }
    
    /// 是否正在录像
    var isRecording: Bool {
        return recording
    }
    
    /// 滤镜
    var filter: CIFilter? {
        get {
            return theFilter
        }
        set {
            theFilter = newValue
        }
    }
    
    /// 拍照
    func snapStillImage(complete: ((_ image: UIImage?, _ imageData: Data?) -> Void)?) {
        guard session.isRunning, !isRecording else { return }
        
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            
            switch self.outputMode {
            case .system:
                // 默认相机
                guard let connection = self.stillImageOutput.connection(with: .video) else  { return }
                self.stillImageOutput.captureStillImageAsynchronously(from: connection, completionHandler: { (buffer, _) in
                    var imageData: Data?
                    var image: UIImage?
                    if let buffer = buffer {
                        imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(buffer)
                    }
                    if let data = imageData {
                        image = UIImage(data: data)
                    }
                    DispatchQueue.main.async {
                        complete?(image, imageData)
                        if let _ = image {
                            let layer = self.preview.layer
                            layer.opacity = 0.0
                            UIView.animate(withDuration: 0.25, animations: {
                                layer.opacity = 1.0
                            })
                        }
                    }
                })
                
            case .bufferData:
                // 帧视频
                let image = self.assertWriter.snapImage
                let imageData = image?.jpegData(compressionQuality: 1.0)
                DispatchQueue.main.async {
                    complete?(image, imageData)
                    if let _ = image {
                        let layer = self.preview.layer
                        layer.opacity = 0.0
                        UIView.animate(withDuration: 0.25, animations: {
                            layer.opacity = 1.0
                        })
                    }
                }
                
            case .metaData:
                break
            }
            
        }
        
    }
    
    /// 识别数据码
    func identifyMetaDataObject(complete: MetaDataIdentifyHandle?) {
        guard session.isRunning else { return }
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            DispatchQueue.main.async {
                self.metaDataIdentifyHandle = complete
            }
        }
    }
    
    /// 开始录像
    func beginMovieRecording(savePath: String = NSTemporaryDirectory().appending("/\(Date()).mov")) {
        guard session.isRunning, !isRecording else { return }
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            
            switch self.outputMode {
            case .system:
                // 默认相机
                if UIDevice.current.isMultitaskingSupported {
                    self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                }
                let orientation = (self.preview.layer as? AVCaptureVideoPreviewLayer)?.connection?.videoOrientation ?? .portrait
                self.movieFileOutput.connection(with: .video)?.videoOrientation = orientation
                self.movieFileOutput.startRecording(to: URL(fileURLWithPath: savePath), recordingDelegate: self)
                self.recording = true
                
            case .bufferData:
                // 帧视频
                self.recording = true
                self.assertWriter.startWriting(with: savePath)
                
            case .metaData:
                break
            }
        }
    }
    
    /// 结束录像
    func endMovieRecording(complete: MovieRecordFinishHandle?) {
        guard session.isRunning, isRecording else { return }
        sessionQueue.async { [unowned self] in
            guard self.authorizeAvailable else { return }
            switch self.outputMode {
            case .system:
                // 默认相机
                self.movieFileOutput.stopRecording()
                self.recording = false
                DispatchQueue.main.async {
                    self.movieOutputHandle = complete
                }
                
            case .bufferData:
                // 帧视频
                self.recording = false
                self.assertWriter.finishWriting(completionHandler: { (outputFileURL) in
                    DispatchQueue.main.async {
                        complete?(outputFileURL)
                    }
                })
                
            case .metaData:
                break
            }
        }
    }
    
    
}


// MARK: - VideoCameraPreview

class VideoCameraPreview: UIView {
    
    override class var layerClass : AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }
    
    var session: AVCaptureSession? {
        set {
            let previewLayer = layer as! AVCaptureVideoPreviewLayer
            previewLayer.session = newValue
            previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        }
        get {
            return (layer as! AVCaptureVideoPreviewLayer).session
        }
    }
}

// MARK: - AssetWriter

class AssetWriter {
    
    private var ciContext = CIContext(eaglContext: EAGLContext(api: .openGLES2)!)
    
    private var videoDimensions = CMVideoDimensions(width: Int32(320), height: Int32(568))
    private var sourceTime = CMTime()
    
    private var writer: AVAssetWriter?
    private var videoWiterInput: AVAssetWriterInput?
    private var audioWiterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    var snapImage: UIImage?
    
    /// 更新视频帧信息
    func renderVideo(sampleBuffer: CMSampleBuffer, filter: CIFilter? = nil) -> CGImage? {
        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            videoDimensions = CMVideoFormatDescriptionGetDimensions(description)
            sourceTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        }
        
        var cgImage: CGImage?
        var pixelBuffer: CVPixelBuffer?
        
        if let filter = filter,
            let ciImage = AssetWriter.ciImage(fromSampleBuffer: sampleBuffer, filter: filter) {
            cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
            
            // writing
            if writer?.startWriting() == true {
                if let pixelBufferPool = adaptor?.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
                    if let buffer = pixelBuffer {
                        ciContext.render(ciImage, to: buffer, bounds: ciImage.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
                    }
                }
            }
            
        } else {
            cgImage = AssetWriter.cgImage(fromSampleBuffer: sampleBuffer)
            
            // writing
            if writer?.startWriting() == true {
                pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            }
        }
        
        // writing
        if writer?.startWriting() == true,
            let buffer = pixelBuffer,
            adaptor?.assetWriterInput.isReadyForMoreMediaData == true {
            adaptor?.append(buffer, withPresentationTime: sourceTime)
        }
        
        if let cgImage = cgImage {
            snapImage = UIImage(cgImage: cgImage)
        }
        
        return cgImage
    }
    
    /// 更新音频帧信息
    func appendAudio(sampleBuffer: CMSampleBuffer) {
        guard writer?.startWriting() == true else { return }
        if audioWiterInput?.isReadyForMoreMediaData == true {
            audioWiterInput?.append(sampleBuffer)
        }
    }
    
    /// 开始资源写入
    func startWriting(with savePath: String) {
        // writer
        do {
            writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: savePath), fileType: .mov)
        } catch {
            print("AssetWriter 初始化失败：\(error.localizedDescription)")
        }
        
        // videoWiterInput
        let videoSettings: [String : Any] = [AVVideoCodecKey : AVVideoCodecH264,
                                             AVVideoWidthKey : videoDimensions.width,
                                             AVVideoHeightKey : videoDimensions.height]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer?.add(videoInput)
        videoWiterInput = videoInput
        
        
        // audioWiterInput
        let audioSettings: [String : Any] = [AVFormatIDKey : kAudioFormatMPEG4AAC,
                                             AVSampleRateKey : 44100,
                                             AVNumberOfChannelsKey : 1]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        writer?.add(audioInput)
        audioWiterInput = audioInput
        
        // adaptor
        let adaptorAttributes: [String : Any] = [String(kCVPixelBufferPixelFormatTypeKey) : kCVPixelFormatType_32BGRA,
                                                 String(kCVPixelBufferWidthKey) : videoDimensions.width,
                                                 String(kCVPixelBufferHeightKey) : videoDimensions.height,
                                                 String(kCVPixelFormatOpenGLESCompatibility) : kCFBooleanTrue]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                       sourcePixelBufferAttributes: adaptorAttributes)
        
        
        // startWriting
        writer?.startSession(atSourceTime: self.sourceTime)
        writer?.startWriting()
    }
    
    /// 结束资源写入
    func finishWriting(completionHandler: MovieRecordFinishHandle?) {
        writer?.finishWriting(completionHandler: { [weak self] in
            completionHandler?(self?.writer?.outputURL)
        })
    }
    
}

extension AssetWriter {
    
    /// Create a CGImage from sample buffer data
    class func cgImage(fromSampleBuffer sampleBuffer: CMSampleBuffer) -> CGImage? {
        
        // Get a CMSampleBuffer's Core Video image buffer for the media data
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil}
        
        // Lock the base address of the pixel buffer
        CVPixelBufferLockBaseAddress(imageBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        
        let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bitsPerComponent: Int = 8
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        
        // Create a bitmap graphics context with the sample buffer data
        let context = CGContext(data: baseAddress,
                                width: width,
                                height: height,
                                bitsPerComponent: bitsPerComponent,
                                bytesPerRow: bytesPerRow,
                                space: colorSpace,
                                bitmapInfo: bitmapInfo)
        
        // Unlock the pixel buffer
        CVPixelBufferUnlockBaseAddress(imageBuffer, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        
        // Create a Quartz image from the pixel data in the bitmap graphics context
        return context?.makeImage()
        
    }
    
    /// Create a CIImage from sample buffer data with filter
    class func ciImage(fromSampleBuffer sampleBuffer: CMSampleBuffer, filter: CIFilter) -> CIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        
        let inputImage = CIImage(cvPixelBuffer: imageBuffer)
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        
        return filter.outputImage
    }
    
}
