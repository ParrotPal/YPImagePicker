//
//  YPCameraVC.swift
//  YPImgePicker
//
//  Created by Sacha Durand Saint Omer on 25/10/16.
//  Copyright © 2016 Yummypets. All rights reserved.
//

import UIKit
import AVFoundation
import Photos

internal final class YPCameraVC: UIViewController, UIGestureRecognizerDelegate, YPPermissionCheckable, YPAutofocusManagerDelegate {
    var didCapturePhoto: ((UIImage) -> Void)?
    let v: YPCameraView!

    private let photoCapture = YPPhotoCaptureHelper()
    private var isInited = false
    private var videoZoomFactor: CGFloat = 1.0

    override internal func loadView() {
        view = v
    }

    internal required init() {
        self.v = YPCameraView(overlayView: YPConfig.overlayView)
        super.init(nibName: nil, bundle: nil)

        title = YPConfig.wordings.cameraTitle
        navigationController?.navigationBar.setTitleFont(font: YPConfig.fonts.navigationBarTitleFont)
        
        YPDeviceOrientationHelper.shared.startDeviceOrientationNotifier { _ in }
    }
    
    internal required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        YPDeviceOrientationHelper.shared.stopDeviceOrientationNotifier()
        NotificationCenter.default.removeObserver(self)
    }
    
    override internal func viewDidLoad() {
        super.viewDidLoad()

        v.flashButton.isHidden = true
        v.flashButton.addTarget(self, action: #selector(flashButtonTapped), for: .touchUpInside)
        v.shotButton.addTarget(self, action: #selector(shotButtonTapped), for: .touchUpInside)
        v.flipButton.addTarget(self, action: #selector(flipButtonTapped), for: .touchUpInside)
        
        // Camera mode switching buttons
        v.cameraModeButton.addTarget(self, action: #selector(cameraModeButtonTapped), for: .touchUpInside)
        v.autoSwitchButton.addTarget(self, action: #selector(autoSwitchButtonTapped), for: .touchUpInside)
        
        // Prevent multiple buttons clicked at the same time
        v.shotButton.isExclusiveTouch = true
        v.flipButton.isExclusiveTouch = true
        v.cameraModeButton.isExclusiveTouch = true
        v.autoSwitchButton.isExclusiveTouch = true
        
        // Focus
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.focusTapped(_:)))
        tapRecognizer.delegate = self
        v.previewViewContainer.addGestureRecognizer(tapRecognizer)
        
        // Zoom
        let pinchRecongizer = UIPinchGestureRecognizer(target: self, action: #selector(self.pinch(_:)))
        pinchRecongizer.delegate = self
        v.previewViewContainer.addGestureRecognizer(pinchRecongizer)
        
        // Listen for camera mode switching notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cameraManualSwitched),
            name: NSNotification.Name("CameraModeManualSwitched"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cameraAutoSwitched),
            name: NSNotification.Name("CameraModeAutoSwitched"),
            object: nil
        )
    }
    
    func start() {
        doAfterCameraPermissionCheck { [weak self] in
            guard let previewContainer = self?.v.previewViewContainer else {
                return
            }

            self?.photoCapture.start(with: previewContainer, completion: {
                DispatchQueue.main.async {
                    self?.isInited = true
                    self?.updateFlashButtonUI()
                    self?.updateCameraModeButtonsUI()
                    // Set autofocus delegate for enhanced focus monitoring
                    if let autofocusManager = self?.photoCapture.autofocusManager {
                        autofocusManager.delegate = self
                        // Configure auto-switch based on persisted user preference
                        autofocusManager.isAutoSwitchEnabled = YPConfig.camera.autoSwitchEnabled
                        ypLog("Camera auto-switch initialized to: \(autofocusManager.isAutoSwitchEnabled)")
                    }
                }
            })
        }
    }

    @objc
    func focusTapped(_ recognizer: UITapGestureRecognizer) {
        guard isInited else {
            return
        }
        
        self.focus(recognizer: recognizer)
    }
    
    func focus(recognizer: UITapGestureRecognizer) {

        let point = recognizer.location(in: v.previewViewContainer)
        
        // Focus the capture
        let viewsize = v.previewViewContainer.bounds.size
        let newPoint = CGPoint(x: point.x/viewsize.width, y: point.y/viewsize.height)
        photoCapture.focus(on: newPoint)
        
        // Animate focus view
        v.focusView.center = point
        YPHelper.configureFocusView(v.focusView)
        v.addSubview(v.focusView)
        YPHelper.animateFocusView(v.focusView)
    }
    
    @objc
    func pinch(_ recognizer: UIPinchGestureRecognizer) {
        guard isInited else {
            return
        }
        
        self.zoom(recognizer: recognizer)
    }
    
    func zoom(recognizer: UIPinchGestureRecognizer) {
        photoCapture.zoom(began: recognizer.state == .began, scale: recognizer.scale)
    }

    func stopCamera() {
        photoCapture.stopCamera()
    }
    
    @objc
    func flipButtonTapped() {
        self.photoCapture.flipCamera {
            self.updateFlashButtonUI()
        }
    }
    
    @objc
    func shotButtonTapped() {
        doAfterCameraPermissionCheck { [weak self] in
            self?.shoot()
        }
    }
    
    func shoot() {
        // Prevent from tapping multiple times in a row
        // causing a crash
        v.shotButton.isEnabled = false

        photoCapture.shoot { imageData in
            
            guard let shotImage = UIImage(data: imageData) else {
                return
            }
            
            self.photoCapture.stopCamera()
            
            var image = shotImage
            // Crop the image if the output needs to be square.
            if YPConfig.onlySquareImagesFromCamera {
                image = self.cropImageToSquare(image)
            }

            // Flip image if taken form the front camera.
            if let device = self.photoCapture.device, device.position == .front {
                image = self.flipImage(image: image)
            }
            
            let noOrietationImage = image.resetOrientation()
            
            DispatchQueue.main.async {
                self.didCapturePhoto?(noOrietationImage.resizedImageIfNeeded())
            }
        }
    }
    
    func cropImageToSquare(_ image: UIImage) -> UIImage {
        let orientation: UIDeviceOrientation = YPDeviceOrientationHelper.shared.currentDeviceOrientation
        var imageWidth = image.size.width
        var imageHeight = image.size.height
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            // Swap width and height if orientation is landscape
            imageWidth = image.size.height
            imageHeight = image.size.width
        default:
            break
        }
        
        // The center coordinate along Y axis
        let rcy = imageHeight * 0.5
        let rect = CGRect(x: rcy - imageWidth * 0.5, y: 0, width: imageWidth, height: imageWidth)
        let imageRef = image.cgImage?.cropping(to: rect)
        return UIImage(cgImage: imageRef!, scale: 1.0, orientation: image.imageOrientation)
    }
    
    // Used when image is taken from the front camera.
    func flipImage(image: UIImage!) -> UIImage! {
        let imageSize: CGSize = image.size
        UIGraphicsBeginImageContextWithOptions(imageSize, true, 1.0)
        let ctx = UIGraphicsGetCurrentContext()!
        ctx.rotate(by: CGFloat(Double.pi/2.0))
        ctx.translateBy(x: 0, y: -imageSize.width)
        ctx.scaleBy(x: imageSize.height/imageSize.width, y: imageSize.width/imageSize.height)
        ctx.draw(image.cgImage!, in: CGRect(x: 0.0,
                                            y: 0.0,
                                            width: imageSize.width,
                                            height: imageSize.height))
        let newImage: UIImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return newImage
    }
    
    @objc
    func flashButtonTapped() {
        photoCapture.device?.tryToggleTorch()
        updateFlashButtonUI()
    }
    
    func updateFlashButtonUI() {
        DispatchQueue.main.async {
            let flashImage = self.photoCapture.currentFlashMode.flashImage()
            self.v.flashButton.setImage(flashImage, for: .normal)
            self.v.flashButton.isHidden = !self.photoCapture.hasFlash
        }
    }
    
    // MARK: - Camera Mode Switching
    
    @objc
    func cameraModeButtonTapped() {
        guard YPConfig.camera.allowsCameraModeSwitch else { return }
        
        // Switch camera mode
        photoCapture.switchCameraMode()
        
        // Update UI immediately (will be confirmed by notification)
        updateCameraModeButtonsUI()
        
        // Enable manual mode temporarily
        photoCapture.autofocusManager?.setManualMode(true)
        
        // Add animation
        UIView.animate(withDuration: 0.2) {
            self.v.cameraModeButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        } completion: { _ in
            UIView.animate(withDuration: 0.2) {
                self.v.cameraModeButton.transform = .identity
            }
        }
    }
    
    @objc
    func autoSwitchButtonTapped() {
        guard YPConfig.camera.allowsCameraModeSwitch else { return }
        
        // Toggle auto-switch mode
        if let autofocusManager = photoCapture.autofocusManager {
            autofocusManager.isAutoSwitchEnabled.toggle()
            
            // Save the new state to UserDefaults
            UserDefaults.ypCameraAutoSwitchEnabled = autofocusManager.isAutoSwitchEnabled
            
            // Update button appearance
            updateAutoSwitchButtonUI(isEnabled: autofocusManager.isAutoSwitchEnabled)
            
            ypLog("Camera auto-switch toggled to: \(autofocusManager.isAutoSwitchEnabled)")
        }
        
        // Add animation
        UIView.animate(withDuration: 0.2) {
            self.v.autoSwitchButton.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        } completion: { _ in
            UIView.animate(withDuration: 0.2) {
                self.v.autoSwitchButton.transform = .identity
            }
        }
    }
    
    @objc
    func cameraManualSwitched() {
        // Update camera mode button title when manually switched
        updateCameraModeButtonsUI()
        
        // Add a subtle flash animation to indicate switch
        UIView.animate(withDuration: 0.2) {
            self.v.cameraModeButton.alpha = 0.5
        } completion: { _ in
            UIView.animate(withDuration: 0.2) {
                self.v.cameraModeButton.alpha = 1.0
            }
        }
    }
    
    @objc
    func cameraAutoSwitched() {
        // Update camera mode button title when auto-switched
        updateCameraModeButtonsUI()
        
        // Add a subtle flash animation to indicate automatic switch
        UIView.animate(withDuration: 0.2) {
            self.v.cameraModeButton.alpha = 0.3
        } completion: { _ in
            UIView.animate(withDuration: 0.2) {
                self.v.cameraModeButton.alpha = 1.0
            }
        }
    }
    
    func updateCameraModeButtonsUI() {
        let hasMultipleModes = photoCapture.hasMultipleCameraModes
        let modeName = photoCapture.currentCameraModeName
        let isAutoEnabled = photoCapture.autofocusManager?.isAutoSwitchEnabled ?? false
        
        v.updateCameraModeButton(title: modeName, isVisible: hasMultipleModes && YPConfig.camera.allowsCameraModeSwitch)
        v.updateAutoSwitchButton(isEnabled: isAutoEnabled, isVisible: hasMultipleModes && YPConfig.camera.allowsCameraModeSwitch)
    }
    
    private func updateAutoSwitchButtonUI(isEnabled: Bool) {
        v.updateAutoSwitchButton(isEnabled: isEnabled, isVisible: photoCapture.hasMultipleCameraModes && YPConfig.camera.allowsCameraModeSwitch)
    }
}

// MARK: - YPAutofocusManagerDelegate

extension YPCameraVC {
    func autofocusDidBeginFocusing(at point: CGPoint) {
        // Enhanced focus UI with the existing focus view
        v.focusView.center = point
        YPHelper.configureFocusView(v.focusView)
        v.addSubview(v.focusView)
        YPHelper.animateFocusView(v.focusView)
    }
    
    func autofocusDidBeginAdjusting() {
        // Optional: Show loading state or change focus indicator
        DispatchQueue.main.async {
            // Could add a subtle animation or color change to indicate focusing is in progress
            if self.v.focusView.superview != nil {
                self.v.focusView.layer.borderColor = UIColor.yellow.cgColor
            }
        }
    }
    
    func autofocusDidFinishAdjusting(quality: YPFocusQuality) {
        DispatchQueue.main.async {
            switch quality {
            case .good:
                // Show successful focus with green indicator
                if self.v.focusView.superview != nil {
                    self.v.focusView.layer.borderColor = UIColor.green.cgColor
                }
            case .tooClose, .tooFar, .failed:
                // Show focus failure with red indicator
                if self.v.focusView.superview != nil {
                    self.v.focusView.layer.borderColor = UIColor.red.cgColor
                }
            }
            
            // Hide focus indicator after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                UIView.animate(withDuration: 0.3) {
                    self.v.focusView.alpha = 0.0
                } completion: { _ in
                    self.v.focusView.removeFromSuperview()
                    self.v.focusView.alpha = 1.0
                    self.v.focusView.layer.borderColor = UIColor.systemYellow.cgColor
                }
            }
        }
    }
    
    func autofocusDidEncounterError(_ error: Error) {
        ypLog("Autofocus error in camera: \(error)")
        // Optionally show user-friendly error message or fallback behavior
    }
    
    func autofocusShouldSwitchToUltraWide() {
        guard YPConfig.camera.allowsCameraModeSwitch else { return }
        guard photoCapture.hasMultipleCameraModes else { return }
        
        // Try to find ultra-wide camera and switch to it
        if let autofocusManager = photoCapture.autofocusManager {
            // Check if we're not already on ultra-wide
            let currentModeName = photoCapture.currentCameraModeName
            if !currentModeName.contains("Wide") {
                // Perform auto-switch to ultra-wide
                photoCapture.autoSwitchToUltraWideIfAvailable()
            }
        }
    }
    
    func autofocusShouldSwitchBackToStandard() {
        guard YPConfig.camera.allowsCameraModeSwitch else { return }
        guard photoCapture.hasMultipleCameraModes else { return }
        
        // Try to switch back to standard camera
        if let autofocusManager = photoCapture.autofocusManager {
            // Check if we're currently on ultra-wide
            let currentModeName = photoCapture.currentCameraModeName
            if currentModeName.contains("Wide") && !currentModeName.contains("Standard") {
                // Perform auto-switch back to standard
                photoCapture.autoSwitchToStandardIfAvailable()
            }
        }
    }
}
