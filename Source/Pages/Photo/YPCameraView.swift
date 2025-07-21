//
//  YPCameraView.swift
//  YPImgePicker
//
//  Created by Sacha Durand Saint Omer on 2015/11/14.
//  Copyright © 2015 Yummypets. All rights reserved.
//

import UIKit
import Stevia

internal class YPCameraView: UIView, UIGestureRecognizerDelegate {
    let focusView = UIView(frame: CGRect(x: 0, y: 0, width: 90, height: 90))
    let previewViewContainer = UIView()
    let buttonsContainer = UIView()
    let flipButton = UIButton()
    let shotButton = UIButton()
    let flashButton = UIButton()
    let timeElapsedLabel = UILabel()
    let progressBar = UIProgressView()
    
    // Camera mode switching buttons
    let cameraModeButton = UIButton()
    let autoSwitchButton = UIButton()
    
    convenience init(overlayView: UIView? = nil) {
        self.init(frame: .zero)
        
        if let overlayView = overlayView {
            // View Hierarchy
            subviews(
                previewViewContainer,
                overlayView,
                progressBar,
                timeElapsedLabel,
                flashButton,
                flipButton,
                cameraModeButton,
                autoSwitchButton,
                buttonsContainer.subviews(
                    shotButton
                )
            )
        } else {
            // View Hierarchy
            subviews(
                previewViewContainer,
                progressBar,
                timeElapsedLabel,
                flashButton,
                flipButton,
                cameraModeButton,
                autoSwitchButton,
                buttonsContainer.subviews(
                    shotButton
                )
            )
        }
        
        // Layout
        let height = window?.windowScene?.screen.bounds.height ?? .zero
        let isIphone4 = height == 480
        let sideMargin: CGFloat = isIphone4 ? 20 : 0
        if YPConfig.onlySquareImagesFromCamera {
            layout(
                0,
                |-sideMargin-previewViewContainer-sideMargin-|,
                -2,
                |progressBar|,
                0,
                |buttonsContainer|,
                0
            )
            
            previewViewContainer.heightEqualsWidth()
        } else {
            layout(
                0,
                |-sideMargin-previewViewContainer-sideMargin-|,
                -2,
                |progressBar|,
                0
            )
            
            previewViewContainer.fillContainer()
            
            buttonsContainer.fillHorizontally()
            buttonsContainer.height(100)
            buttonsContainer.Bottom == previewViewContainer.Bottom - 50
        }
        
        overlayView?.followEdges(previewViewContainer)
        
        |-(15+sideMargin)-flashButton.size(42)
        flashButton.Bottom == previewViewContainer.Bottom - 15
        
        flipButton.size(42)-(15+sideMargin)-|
        flipButton.Bottom == previewViewContainer.Bottom - 15
        
        timeElapsedLabel-(15+sideMargin)-|
        timeElapsedLabel.Top == previewViewContainer.Top + 15
        
        shotButton.centerVertically()
        shotButton.size(84).centerHorizontally()
        
        // Camera mode switching buttons layout
        setupCameraModeButtonsLayout(sideMargin: sideMargin)
        
        // Style
        backgroundColor = YPConfig.colors.photoVideoScreenBackgroundColor
        previewViewContainer.backgroundColor = UIColor.ypLabel
        timeElapsedLabel.style { l in
            l.textColor = .white
            l.text = "00:00"
            l.isHidden = true
            l.font = YPConfig.fonts.cameraTimeElapsedFont
        }
        progressBar.style { p in
            p.trackTintColor = .clear
            p.tintColor = .ypSystemRed
        }
        flashButton.setImage(YPConfig.icons.flashOffIcon, for: .normal)
        flipButton.setImage(YPConfig.icons.loopIcon, for: .normal)
        shotButton.setImage(YPConfig.icons.capturePhotoImage, for: .normal)
        
        // Style camera mode buttons
        setupCameraModeButtonsStyle()
    }
    
    private func setupCameraModeButtonsLayout(sideMargin: CGFloat) {
        // Camera mode button - position in bottom left corner
        |-(15+sideMargin)-cameraModeButton
        cameraModeButton.Bottom == previewViewContainer.Bottom - 100
        
        // Auto-switch button - position in bottom right corner  
        autoSwitchButton-(15+sideMargin)-|
        autoSwitchButton.Bottom == previewViewContainer.Bottom - 100
    }
    
    private func setupCameraModeButtonsStyle() {
        // Calculate height: top padding (8) + font size (14) + bottom padding (8) = 30
        let buttonHeight: CGFloat = 30
        let cornerRadius: CGFloat = buttonHeight / 2
        
        // Camera mode button styling
        cameraModeButton.style { button in
            button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            button.layer.cornerRadius = cornerRadius
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            button.setTitleColor(.white, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            button.setTitle("Camera", for: .normal)
            button.isHidden = true // Initially hidden until we know if multiple cameras are available
        }
        
        // Auto-switch button styling
        autoSwitchButton.style { button in
            button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            button.layer.cornerRadius = cornerRadius
            button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            button.setTitle("Auto: ON", for: .normal)
            button.setTitleColor(.green, for: .normal)
            button.layer.borderColor = UIColor.green.cgColor
            button.layer.borderWidth = 1
            button.isHidden = true // Initially hidden until we know if multiple cameras are available
        }
    }
    
    /// Update the camera mode button title
    func updateCameraModeButton(title: String, isVisible: Bool) {
        cameraModeButton.setTitle(title, for: .normal)
        cameraModeButton.isHidden = !isVisible || !YPConfig.camera.showCameraModeButton
    }
    
    /// Update the auto-switch button state
    func updateAutoSwitchButton(isEnabled: Bool, isVisible: Bool) {
        if isEnabled {
            autoSwitchButton.setTitle("Auto: ON", for: .normal)
            autoSwitchButton.setTitleColor(.green, for: .normal)
            autoSwitchButton.layer.borderColor = UIColor.green.cgColor
        } else {
            autoSwitchButton.setTitle("Auto: OFF", for: .normal)
            autoSwitchButton.setTitleColor(.white, for: .normal)
            autoSwitchButton.layer.borderColor = UIColor.white.cgColor
        }
        autoSwitchButton.isHidden = !isVisible || !YPConfig.camera.showAutoSwitchButton
    }
}
