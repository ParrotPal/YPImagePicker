//
//  YPAutofocusManager.swift
//  YPImagePicker
//
//  Created by Claude Code Assistant.
//  Copyright © 2025 Yummypets. All rights reserved.
//

import UIKit
import AVFoundation

/// Defines focus quality evaluation results
public enum YPFocusQuality {
    case good
    case tooClose
    case tooFar
    case failed
}

/// Protocol for autofocus manager delegate
public protocol YPAutofocusManagerDelegate: AnyObject {
    func autofocusDidBeginFocusing(at point: CGPoint)
    func autofocusDidBeginAdjusting()
    func autofocusDidFinishAdjusting(quality: YPFocusQuality)
    func autofocusDidEncounterError(_ error: Error)
}

/// Core autofocus manager for handling advanced focus operations
internal final class YPAutofocusManager {
    private let device: AVCaptureDevice
    private let configuration: YPAutofocusConfiguration
    private var focusObservation: NSKeyValueObservation?
    private var resetTimer: Timer?
    
    weak var delegate: YPAutofocusManagerDelegate?
    
    init(device: AVCaptureDevice, configuration: YPAutofocusConfiguration) {
        self.device = device
        self.configuration = configuration
        setupFocusMonitoring()
    }
    
    deinit {
        focusObservation?.invalidate()
        resetTimer?.invalidate()
    }
    
    // MARK: - Public Methods
    
    /// Configure the device with autofocus settings
    func configure() throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        // Configure focus mode
        if device.isFocusModeSupported(configuration.focusMode.avFocusMode) {
            device.focusMode = configuration.focusMode.avFocusMode
        }
        
        // Configure smooth autofocus
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = configuration.smoothAutoFocusEnabled
        }
        
        // Configure focus range restriction (iOS 13.0+)
        if #available(iOS 13.0, *) {
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = configuration.focusRange.avFocusRange
            }
        }
        
        // Configure manual lens position if specified
        if let lensPosition = configuration.manualLensPosition {
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: lensPosition) { _ in }
            }
        }
    }
    
    /// Focus at a specific point in the preview view
    func focusAt(point: CGPoint, in view: UIView) throws {
        guard configuration.tapToFocusEnabled else { return }
        guard device.isFocusPointOfInterestSupported else { return }
        
        // Convert point to device coordinates
        let devicePoint = convertToDevicePoint(point, in: view)
        
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        
        // Set focus point
        device.focusPointOfInterest = devicePoint
        
        // Trigger single-shot autofocus
        if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
            
            // Schedule return to continuous mode
            scheduleReturnToContinuousMode()
        }
        
        // Update UI
        delegate?.autofocusDidBeginFocusing(at: point)
    }
    
    /// Manually set focus mode
    func setFocusMode(_ mode: YPCameraFocusMode) throws {
        guard device.isFocusModeSupported(mode.avFocusMode) else {
            throw YPAutofocusError.focusModeNotSupported
        }
        
        try device.lockForConfiguration()
        device.focusMode = mode.avFocusMode
        device.unlockForConfiguration()
    }
    
    /// Get current focus distance estimation
    var estimatedFocusDistance: Float? {
        guard device.minimumFocusDistance > 0.0 else { return nil }
        
        let lensPosition = device.lensPosition
        let minDistance = device.minimumFocusDistance
        
        // Simplified calculation - actual implementation would be more complex
        return minDistance / (1.0 - lensPosition)
    }
    
    /// Check if camera is at minimum focus distance
    var isAtMinimumFocusDistance: Bool {
        return device.lensPosition > 0.95
    }
    
    // MARK: - Private Methods
    
    private func setupFocusMonitoring() {
        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] device, _ in
            DispatchQueue.main.async {
                self?.handleFocusStateChange(device: device)
            }
        }
    }
    
    private func handleFocusStateChange(device: AVCaptureDevice) {
        if device.isAdjustingFocus {
            delegate?.autofocusDidBeginAdjusting()
        } else {
            let focusQuality = evaluateFocusQuality(device: device)
            delegate?.autofocusDidFinishAdjusting(quality: focusQuality)
        }
    }
    
    private func evaluateFocusQuality(device: AVCaptureDevice) -> YPFocusQuality {
        let lensPosition = device.lensPosition
        
        if lensPosition > 0.95 {
            return .tooClose
        } else if lensPosition < 0.05 {
            return .tooFar
        } else {
            return .good
        }
    }
    
    private func scheduleReturnToContinuousMode() {
        resetTimer?.invalidate()
        
        resetTimer = Timer.scheduledTimer(withTimeInterval: configuration.tapToFocusResetDelay, repeats: false) { [weak self] _ in
            self?.returnToContinuousMode()
        }
    }
    
    private func returnToContinuousMode() {
        guard device.isFocusModeSupported(.continuousAutoFocus) else { return }
        guard configuration.focusMode == .continuousAutoFocus else { return }
        
        do {
            try device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        } catch {
            delegate?.autofocusDidEncounterError(error)
        }
    }
    
    private func convertToDevicePoint(_ point: CGPoint, in view: UIView) -> CGPoint {
        // Convert from view coordinates to normalized device coordinates (0.0 - 1.0)
        return CGPoint(
            x: point.x / view.bounds.width,
            y: point.y / view.bounds.height
        )
    }
}

// MARK: - Error Types

enum YPAutofocusError: Error {
    case deviceNotAvailable
    case focusModeNotSupported
    case configurationFailed
    case focusPointNotSupported
    
    var localizedDescription: String {
        switch self {
        case .deviceNotAvailable:
            return "Camera device not available"
        case .focusModeNotSupported:
            return "Focus mode not supported on this device"
        case .configurationFailed:
            return "Failed to configure autofocus"
        case .focusPointNotSupported:
            return "Focus point adjustment not supported"
        }
    }
}