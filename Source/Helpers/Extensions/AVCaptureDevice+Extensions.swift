//
//  AVCaptureDevice+Extensions.swift
//
//  Created by Nik Kov on 23.04.2018.
//  Copyright © 2018 Octopepper. All rights reserved.
//

import AVFoundation
import UIKit

extension AVCaptureDevice {
    func tryToggleTorch() {
        guard hasFlash else {
            return
        }

        do {
            try lockForConfiguration()

            switch torchMode {
            case .auto:
                torchMode = .on
            case .on:
                torchMode = .off
            case .off:
                torchMode = .auto
            @unknown default:
                throw YPError.custom(message: "unknown default case")
            }

            unlockForConfiguration()
        } catch {
            ypLog("Error with torch \(error).")
        }
    }
    
}

internal extension AVCaptureDevice {
    class var audioCaptureDevice: AVCaptureDevice? {
        let availableMicrophoneAudioDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified).devices
        return availableMicrophoneAudioDevices.first
    }

    /// Best available device for selected position.
    class func deviceForPosition(_ p: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devicesSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInTrueDepthCamera, .builtInDualCamera, .builtInWideAngleCamera], 
            mediaType: .video, 
            position: p
        )
        let devices = devicesSession.devices
        guard !devices.isEmpty else {
            print("Don't have supported cameras for this position: \(p.rawValue)")
            return nil
        }

        return devices.first
    }
    
    /// Get all available camera types for a specific position, ordered by preference
    class func availableCameraTypes(for position: AVCaptureDevice.Position) -> [AVCaptureDevice.DeviceType] {
        let allTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera
        ]
        
        var availableTypes: [AVCaptureDevice.DeviceType] = []
        
        for deviceType in allTypes {
            if let device = AVCaptureDevice.default(deviceType, for: .video, position: position) {
                // Check if device supports required features for enhanced functionality
                if #available(iOS 13.0, *) {
                    if device.isAutoFocusRangeRestrictionSupported {
                        availableTypes.append(deviceType)
                        ypLog("Available camera type: \(deviceType.rawValue)")
                    }
                } else {
                    // For older iOS versions, just check if the device exists
                    availableTypes.append(deviceType)
                }
            }
        }
        
        // If no cameras with enhanced features found, fall back to basic discovery
        if availableTypes.isEmpty {
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: allTypes,
                mediaType: .video,
                position: position
            )
            
            for device in discoverySession.devices {
                if !availableTypes.contains(device.deviceType) {
                    availableTypes.append(device.deviceType)
                }
            }
        }
        
        return availableTypes
    }
    
    /// Get device of specific type for position
    class func device(ofType deviceType: AVCaptureDevice.DeviceType, position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        return AVCaptureDevice.default(deviceType, for: .video, position: position)
    }
    
    /// Get human-readable name for device type
    var cameraModeName: String {
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
}
