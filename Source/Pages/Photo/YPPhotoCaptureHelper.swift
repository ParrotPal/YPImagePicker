//
//  YPPhotoCaptureHelper.swift
//  YPImagePicker
//
//  Created by Sacha DSO on 08/03/2018.
//  Copyright © 2018 Yummypets. All rights reserved.
//

import UIKit
import AVFoundation

internal final class YPPhotoCaptureHelper: NSObject {
    var currentFlashMode: YPFlashMode {
        return YPFlashMode(torchMode: device?.torchMode)
    }
    var device: AVCaptureDevice? {
        return deviceInput?.device
    }
    var hasFlash: Bool {
        let isFrontCamera = device?.position == .front
        let deviceHasFlash = device?.hasFlash ?? false
        return !isFrontCamera && deviceHasFlash
    }
    
    // MARK: - Camera Mode Switching Properties
    private var availableCameraTypes: [AVCaptureDevice.DeviceType] = []
    private var currentCameraTypeIndex: Int = 0
    private var isManualModeActive: Bool = false
    
    var currentCameraModeName: String {
        guard !availableCameraTypes.isEmpty, currentCameraTypeIndex < availableCameraTypes.count else {
            return "Camera"
        }
        
        let deviceType = availableCameraTypes[currentCameraTypeIndex]
        switch deviceType {
        case .builtInWideAngleCamera:
            return "1× Standard"
        case .builtInUltraWideCamera:
            return "0.5× Wide"
        case .builtInTelephotoCamera:
            return "2× Zoom"
        case .builtInDualCamera:
            return "Standard"
        case .builtInDualWideCamera:
            return "Wide Lens"
        case .builtInTripleCamera:
            return "Multi-Lens"
        default:
            return "Camera"
        }
    }
    
    var hasMultipleCameraModes: Bool {
        return availableCameraTypes.count > 1
    }
    
    private let sessionQueue = DispatchQueue(label: "YPPhotoCaptureHelperQueue", qos: .background)
    private let session = AVCaptureSession()
    private var deviceInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private var isCaptureSessionSetup: Bool = false
    private var isPreviewSetup: Bool = false
    private var previewView: UIView!
    private var videoLayer: AVCaptureVideoPreviewLayer!
    private var block: ((Data) -> Void)?
    private var initVideoZoomFactor: CGFloat = 1.0
    internal var autofocusManager: YPAutofocusManager?
}

// MARK: - Public

extension YPPhotoCaptureHelper {
    func shoot(completion: @escaping (Data) -> Void) {
        block = completion
        
        // Set current device orientation
        setCurrentOrienation()
        
        let settings = photoCaptureSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func start(with previewView: UIView, completion: @escaping () -> Void) {
        self.previewView = previewView
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if !self.isCaptureSessionSetup {
                self.setupCaptureSession()
            }
            self.startCamera {
                completion()
            }
        }
    }
    
    func stopCamera() {
        if session.isRunning {
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
            }
        }
    }
    
    func zoom(began: Bool, scale: CGFloat) {
        guard let device = device else {
            return
        }
        
        if began {
            initVideoZoomFactor = device.videoZoomFactor
            return
        }
        
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            
            let minAvailableVideoZoomFactor = device.minAvailableVideoZoomFactor
            let maxAvailableVideoZoomFactor = min(device.maxAvailableVideoZoomFactor, YPConfig.maxCameraZoomFactor)

            let desiredZoomFactor = initVideoZoomFactor * scale
            device.videoZoomFactor = max(minAvailableVideoZoomFactor,
                                         min(desiredZoomFactor, maxAvailableVideoZoomFactor))
        } catch let error {
            ypLog("Error: \(error)")
        }
    }
    
    func flipCamera(completion: @escaping () -> Void) {
        sessionQueue.async { [weak self] in
            self?.flip()
            DispatchQueue.main.async {
                completion()
            }
        }
    }
    
    func focus(on point: CGPoint) {
        guard let device = device else {
            return
        }
        
        // Use autofocus manager if available and tap-to-focus is enabled
        if let manager = autofocusManager {
            do {
                try manager.focusAt(point: point, in: previewView)
            } catch {
                ypLog("Autofocus error: \(error)")
                // Fallback to legacy focus
                setFocusPointOnDevice(device: device, point: point)
            }
        } else {
            // Fallback to legacy focus implementation
            setFocusPointOnDevice(device: device, point: point)
        }
    }
    
    // MARK: - Camera Mode Switching
    
    /// Switches to the next available camera mode
    func switchCameraMode() {
        guard hasMultipleCameraModes else {
            ypLog("No multiple camera modes available")
            return
        }
        
        // Manual switch disables auto-switching temporarily
        isManualModeActive = true
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Stop the current session
            if self.session.isRunning {
                self.session.stopRunning()
            }
            
            // Remove current video input
            if let currentInput = self.session.inputs.first(where: { $0 is AVCaptureDeviceInput }) {
                self.session.removeInput(currentInput)
            }
            
            // Move to the next camera type
            self.currentCameraTypeIndex = (self.currentCameraTypeIndex + 1) % self.availableCameraTypes.count
            let newDeviceType = self.availableCameraTypes[self.currentCameraTypeIndex]
            
            let currentPosition = self.device?.position ?? .back
            
            // Get the new device
            guard let newDevice = AVCaptureDevice.device(ofType: newDeviceType, position: currentPosition) else {
                ypLog("Failed to get device for type: \(newDeviceType.rawValue)")
                return
            }
            
            // Create new input
            do {
                let newInput = try AVCaptureDeviceInput(device: newDevice)
                
                // Add new input
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.deviceInput = newInput
                    
                    // Configure the new device
                    try newDevice.lockForConfiguration()
                    
                    // Configure focus mode
                    if newDevice.isFocusModeSupported(.continuousAutoFocus) {
                        newDevice.focusMode = .continuousAutoFocus
                    }
                    
                    // Enable appropriate focus range for each camera type
                    if #available(iOS 13.0, *) {
                        if newDevice.isAutoFocusRangeRestrictionSupported {
                            // For ultra-wide camera, use .near for better macro focusing
                            // For standard and telephoto, use .none for better overall range
                            if newDeviceType == .builtInUltraWideCamera {
                                newDevice.autoFocusRangeRestriction = .near
                            } else {
                                newDevice.autoFocusRangeRestriction = .none
                            }
                        }
                    }
                    
                    // Configure exposure
                    if newDevice.isExposureModeSupported(.continuousAutoExposure) {
                        newDevice.exposureMode = .continuousAutoExposure
                    }
                    
                    // Enable low light boost if available
                    if newDevice.isLowLightBoostSupported && !newDevice.automaticallyEnablesLowLightBoostWhenAvailable {
                        newDevice.automaticallyEnablesLowLightBoostWhenAvailable = true
                    }
                    
                    newDevice.unlockForConfiguration()
                    
                    // Reconfigure autofocus for new device
                    self.autofocusManager = YPAutofocusManager(device: newDevice, configuration: YPConfig.camera.autofocus)
                    do {
                        try self.autofocusManager?.configure()
                        // Restore auto-switch state from UserDefaults
                        self.autofocusManager?.isAutoSwitchEnabled = YPConfig.camera.autoSwitchEnabled
                    } catch {
                        ypLog("Failed to configure autofocus after camera switch: \(error)")
                    }
                    
                    ypLog("Switched to camera: \(self.currentCameraModeName)")
                    
                    // Restart the session
                    self.session.startRunning()
                    
                    // Notify UI about the switch
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: NSNotification.Name("CameraModeManualSwitched"), object: nil)
                    }
                    
                    // Reset manual mode after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.isManualModeActive = false
                    }
                } else {
                    ypLog("Cannot add input for device type: \(newDeviceType.rawValue)")
                }
            } catch {
                ypLog("Error switching camera: \(error)")
            }
        }
    }
    
    /// Auto-switch to ultra-wide camera if available
    func autoSwitchToUltraWideIfAvailable() {
        guard let ultraWideIndex = availableCameraTypes.firstIndex(of: .builtInUltraWideCamera),
              currentCameraTypeIndex != ultraWideIndex else { return }
        
        autoSwitchToCamera(at: ultraWideIndex)
    }
    
    /// Auto-switch to standard wide camera if available  
    func autoSwitchToStandardIfAvailable() {
        guard let standardIndex = availableCameraTypes.firstIndex(of: .builtInWideAngleCamera),
              currentCameraTypeIndex != standardIndex else { return }
        
        autoSwitchToCamera(at: standardIndex)
    }
    
    private func autoSwitchToCamera(at index: Int) {
        guard index != currentCameraTypeIndex else { return }
        guard index < availableCameraTypes.count else { return }
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Stop the current session
            if self.session.isRunning {
                self.session.stopRunning()
            }
            
            // Remove current video input
            if let currentInput = self.session.inputs.first(where: { $0 is AVCaptureDeviceInput }) {
                self.session.removeInput(currentInput)
            }
            
            // Update the index
            self.currentCameraTypeIndex = index
            let newDeviceType = self.availableCameraTypes[self.currentCameraTypeIndex]
            
            let currentPosition = self.device?.position ?? .back
            
            // Get the new device
            guard let newDevice = AVCaptureDevice.device(ofType: newDeviceType, position: currentPosition) else {
                ypLog("Failed to get device for auto-switch to type: \(newDeviceType.rawValue)")
                return
            }
            
            // Create and add new input
            do {
                let newInput = try AVCaptureDeviceInput(device: newDevice)
                
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.deviceInput = newInput
                    
                    // Configure the new device
                    try newDevice.lockForConfiguration()
                    
                    if newDevice.isFocusModeSupported(.continuousAutoFocus) {
                        newDevice.focusMode = .continuousAutoFocus
                    }
                    
                    if #available(iOS 13.0, *) {
                        if newDevice.isAutoFocusRangeRestrictionSupported {
                            if newDeviceType == .builtInUltraWideCamera {
                                newDevice.autoFocusRangeRestriction = .near
                            } else {
                                newDevice.autoFocusRangeRestriction = .none
                            }
                        }
                    }
                    
                    if newDevice.isExposureModeSupported(.continuousAutoExposure) {
                        newDevice.exposureMode = .continuousAutoExposure
                    }
                    
                    if newDevice.isLowLightBoostSupported && !newDevice.automaticallyEnablesLowLightBoostWhenAvailable {
                        newDevice.automaticallyEnablesLowLightBoostWhenAvailable = true
                    }
                    
                    newDevice.unlockForConfiguration()
                    
                    // Reconfigure autofocus for new device
                    self.autofocusManager = YPAutofocusManager(device: newDevice, configuration: YPConfig.camera.autofocus)
                    do {
                        try self.autofocusManager?.configure()
                        // Restore auto-switch state from UserDefaults
                        self.autofocusManager?.isAutoSwitchEnabled = YPConfig.camera.autoSwitchEnabled
                    } catch {
                        ypLog("Failed to configure autofocus after auto camera switch: \(error)")
                    }
                    
                    ypLog("Auto-switched to camera: \(self.currentCameraModeName)")
                    
                    // Restart the session
                    self.session.startRunning()
                    
                    // Notify UI about the automatic switch
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: NSNotification.Name("CameraModeAutoSwitched"), object: nil)
                    }
                }
            } catch {
                ypLog("Error auto-switching camera: \(error)")
            }
        }
    }
}

extension YPPhotoCaptureHelper: AVCapturePhotoCaptureDelegate {
    
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if YPConfig.silentMode {
            AudioServicesDisposeSystemSoundID(1108)
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if YPConfig.silentMode {
            AudioServicesDisposeSystemSoundID(1108)
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation() else { return }
        block?(data)
    }
}

// MARK: - Private
private extension YPPhotoCaptureHelper {
    
    // MARK: Setup
    
    private func photoCaptureSettings() -> AVCapturePhotoSettings {
        var settings = AVCapturePhotoSettings()
        
        // Catpure Heif when available.
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        
        // Catpure Highest Quality possible.
        settings.isHighResolutionPhotoEnabled = true
        
        // Set flash mode.
        if let deviceInput = deviceInput {
            if deviceInput.device.isFlashAvailable {
                let supportedFlashModes = photoOutput.__supportedFlashModes
                switch currentFlashMode {
                case .auto:
                    if supportedFlashModes.contains(NSNumber(value: AVCaptureDevice.FlashMode.auto.rawValue)) {
                        settings.flashMode = .auto
                    }
                case .off:
                    if supportedFlashModes.contains(NSNumber(value: AVCaptureDevice.FlashMode.off.rawValue)) {
                        settings.flashMode = .off
                    }
                case .on:
                    if supportedFlashModes.contains(NSNumber(value: AVCaptureDevice.FlashMode.on.rawValue)) {
                        settings.flashMode = .on
                    }
                }
            }
        }
        
        return settings
    }
    
    private func setupCaptureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        let cameraPosition: AVCaptureDevice.Position = YPConfig.usesFrontCamera ? .front : .back
        
        // Initialize available camera types
        availableCameraTypes = AVCaptureDevice.availableCameraTypes(for: cameraPosition)
        
        // Select the initial camera device
        var selectedDevice: AVCaptureDevice?
        
        if !availableCameraTypes.isEmpty {
            // Try to find and set the standard wide angle camera as default
            if let wideAngleIndex = availableCameraTypes.firstIndex(of: .builtInWideAngleCamera) {
                currentCameraTypeIndex = wideAngleIndex
            }
            
            // Use the selected camera type
            let selectedType = availableCameraTypes[currentCameraTypeIndex]
            selectedDevice = AVCaptureDevice.device(ofType: selectedType, position: cameraPosition)
            ypLog("Selected camera type: \(selectedType.rawValue)")
        } else {
            // Fallback to original logic
            selectedDevice = AVCaptureDevice.deviceForPosition(cameraPosition)
        }
        
        if let device = selectedDevice {
            deviceInput = try? AVCaptureDeviceInput(device: device)
        }
        
        if let videoInput = deviceInput {
            if session.canAddInput(videoInput) {
                session.addInput(videoInput)
            }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                photoOutput.isHighResolutionCaptureEnabled = true
                // Improve capture time by preparing output with the desired settings.
                photoOutput.setPreparedPhotoSettingsArray([photoCaptureSettings()], completionHandler: nil)
            }
        }
        
        // Setup autofocus manager
        if let device = self.device {
            autofocusManager = YPAutofocusManager(device: device, configuration: YPConfig.camera.autofocus)
            do {
                try autofocusManager?.configure()
                // Initialize auto-switch state from UserDefaults
                autofocusManager?.isAutoSwitchEnabled = YPConfig.camera.autoSwitchEnabled
            } catch {
                ypLog("Failed to configure autofocus: \(error)")
            }
        }
        
        session.commitConfiguration()
        isCaptureSessionSetup = true
    }
    
    private func tryToSetupPreview() {
        if !isPreviewSetup {
            setupPreview()
            isPreviewSetup = true
        }
    }
    
    private func setupPreview() {
        videoLayer = AVCaptureVideoPreviewLayer(session: session)
        DispatchQueue.main.async {
            self.videoLayer.frame = self.previewView.bounds
            self.videoLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
            self.previewView.layer.addSublayer(self.videoLayer)
        }
    }
    
    // MARK: Other
    
    private func startCamera(completion: @escaping (() -> Void)) {
        if !session.isRunning {
            sessionQueue.async { [weak self] in
                // Re-apply session preset
                self?.session.sessionPreset = .photo
                let status = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)
                switch status {
                case .notDetermined, .restricted, .denied:
                    self?.session.stopRunning()
                case .authorized:
                    self?.session.startRunning()
                    completion()
                    self?.tryToSetupPreview()
                @unknown default:
                    ypLog("unknown default reached. Check code.")
                }
            }
        }
    }
    
    private func flip() {
        session.resetInputs()
        guard let di = deviceInput else { return }
        deviceInput = flippedDeviceInputForInput(di)
        guard let deviceInput = deviceInput else { return }
        if session.canAddInput(deviceInput) {
            session.addInput(deviceInput)
        }
        
        // Reconfigure autofocus for new device
        if let device = self.device {
            autofocusManager = YPAutofocusManager(device: device, configuration: YPConfig.camera.autofocus)
            do {
                try autofocusManager?.configure()
                // Restore auto-switch state from UserDefaults
                autofocusManager?.isAutoSwitchEnabled = YPConfig.camera.autoSwitchEnabled
            } catch {
                ypLog("Failed to configure autofocus after camera flip: \(error)")
            }
        }
    }
    
    private func setCurrentOrienation() {
        let connection = photoOutput.connection(with: .video)
        let orientation = YPDeviceOrientationHelper.shared.currentDeviceOrientation
        switch orientation {
        case .portrait:
            connection?.videoOrientation = .portrait
        case .portraitUpsideDown:
            connection?.videoOrientation = .portraitUpsideDown
        case .landscapeRight:
            connection?.videoOrientation = .landscapeLeft
        case .landscapeLeft:
            connection?.videoOrientation = .landscapeRight
        default:
            connection?.videoOrientation = .portrait
        }
    }
}
