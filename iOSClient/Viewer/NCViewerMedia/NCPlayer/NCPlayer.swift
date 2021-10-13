//
//  NCPlayer.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 01/07/21.
//  Copyright © 2021 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import NCCommunication
import UIKit
import AVFoundation
import AVKit

/// The Set of custom player controllers currently using or transitioning out of PiP
private var activeNCPlayer = Set<NCPlayer>()

class NCPlayer: NSObject {
   
    private let appDelegate = UIApplication.shared.delegate as! AppDelegate
    private var imageVideoContainer: imageVideoContainerView?
    private var playerToolBar: NCPlayerToolBar?
    private var detailView: NCViewerMediaDetailView?
    private var observerAVPlayerItemDidPlayToEndTime: Any?
    
    public var metadata: tableMetadata?
    public var videoLayer: AVPlayerLayer?
    public var pictureInPictureController: AVPictureInPictureController?

    init(url: URL, imageVideoContainer: imageVideoContainerView?, playerToolBar: NCPlayerToolBar?, metadata: tableMetadata, detailView: NCViewerMediaDetailView?) {
        super.init()

        var timeSeek: CMTime = .zero

        print("Play URL: \(url)")
        appDelegate.player?.pause()
        //TODO: Simultaneous accesses to 0x14fd07578, but modification requires exclusive access
        appDelegate.player = AVPlayer(url: url)

        self.playerToolBar = playerToolBar
        self.metadata = metadata
        self.detailView = detailView
        
        if metadata.livePhoto {
            appDelegate.player?.isMuted = false
        } else if metadata.classFile == NCCommunicationCommon.typeClassFile.audio.rawValue {
            appDelegate.player?.isMuted = CCUtility.getAudioMute()
        } else {
            appDelegate.player?.isMuted = CCUtility.getAudioMute()
            if let time = NCManageDatabase.shared.getVideoTime(metadata: metadata) {
                timeSeek = time
            }
        }
        appDelegate.player?.seek(to: timeSeek)
        
        // At end go back to start & show toolbar
        observerAVPlayerItemDidPlayToEndTime = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: appDelegate.player?.currentItem, queue: .main) { (notification) in
            if let item = notification.object as? AVPlayerItem, let currentItem = self.appDelegate.player?.currentItem, item == currentItem {
                self.videoSeek(time: .zero)
                if !(detailView?.isShow() ?? false) {
                    NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterShowPlayerToolBar, userInfo: ["ocId":metadata.ocId, "enableTimerAutoHide": false])
                }
                NCKTVHTTPCache.shared.saveCache(metadata: metadata)
            }
        }
        
        appDelegate.player?.currentItem?.asset.loadValuesAsynchronously(forKeys: ["playable"], completionHandler: {
            var error: NSError? = nil
            let status = self.appDelegate.player?.currentItem?.asset.statusOfValue(forKey: "playable", error: &error)
            switch status {
            case .loaded:
                DispatchQueue.main.async {
                    if let imageVideoContainer = imageVideoContainer {
                        
                        self.imageVideoContainer = imageVideoContainer
                        self.videoLayer = AVPlayerLayer(player: self.appDelegate.player)
                        self.videoLayer!.frame = imageVideoContainer.bounds
                        self.videoLayer!.videoGravity = .resizeAspect
                        
                        if metadata.classFile != NCCommunicationCommon.typeClassFile.audio.rawValue {
                        
                            if !metadata.livePhoto {
                                imageVideoContainer.image = imageVideoContainer.image?.image(alpha: 0)
                            }
                            imageVideoContainer.layer.addSublayer(self.videoLayer!)
                            imageVideoContainer.playerLayer = self.videoLayer
                            imageVideoContainer.metadata = self.metadata
                            // PiP
                            if let playerLayer = self.videoLayer {
                                self.pictureInPictureController = AVPictureInPictureController(playerLayer: playerLayer)
                                self.pictureInPictureController?.delegate = self
                            }
                        }
                    }
                    if let durationTime: CMTime = (self.appDelegate.player?.currentItem?.asset.duration) {
                        NCManageDatabase.shared.addVideoTime(metadata: metadata, time: nil, durationTime: durationTime)
                    }
                    self.playerToolBar?.setBarPlayer(ncplayer: self, timeSeek: timeSeek, metadata: metadata)
                    self.generatorImagePreview()
                    if !(detailView?.isShow() ?? false) {
                        NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterShowPlayerToolBar, userInfo: ["ocId":metadata.ocId, "enableTimerAutoHide": false])
                    }
                }
                break
            case .failed:
                DispatchQueue.main.async {
                    var description = NSLocalizedString("_error_something_wrong_", comment: "")
                    if let errorDescription = error?.localizedDescription, let failureReason = error?.localizedFailureReason {
                        description = NSLocalizedString("_error_something_wrong_", comment: "") + "\n" + errorDescription + "\n" + failureReason
                    }
                    NCContentPresenter.shared.messageNotification("_error_", description: description, delay: NCGlobal.shared.dismissAfterSecond, type: NCContentPresenter.messageType.info, errorCode: NCGlobal.shared.errorGeneric, forced: false)
                }
                break
            case .cancelled:
                DispatchQueue.main.async {
                    //do something, show alert, put a placeholder image etc.
                }
                break
            default:
                break
            }
        })
        
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground(_:)), name: NSNotification.Name(rawValue: NCGlobal.shared.notificationCenterApplicationDidEnterBackground), object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)), name: NSNotification.Name(rawValue: NCGlobal.shared.notificationCenterApplicationDidBecomeActive), object: nil)
    }

    deinit {
        print("deinit NCPlayer")
        
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: NCGlobal.shared.notificationCenterApplicationDidEnterBackground), object: nil)

        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: NCGlobal.shared.notificationCenterApplicationDidBecomeActive), object: nil)

        videoRemoved()
    }
    
    //MARK: - NotificationCenter

    @objc func applicationDidEnterBackground(_ notification: NSNotification) {
        
        if metadata?.classFile == NCCommunicationCommon.typeClassFile.video.rawValue {
            if let pictureInPictureController = pictureInPictureController, pictureInPictureController.isPictureInPictureActive { return }
            playerPause()
        }
    }
    
    @objc func applicationDidBecomeActive(_ notification: NSNotification) {
        
        playerToolBar?.updateToolBar()
    }
    
    //MARK: -
    
    func isPlay() -> Bool {
        
        if appDelegate.player?.rate == 1 { return true } else { return false }
    }
    
    func isPictureInPictureActive() -> Bool {
        
        if let pictureInPictureController = pictureInPictureController, pictureInPictureController.isPictureInPictureActive {
            return true
        } else {
            return false
        }
    }
    
    func playerPlay() {
                
        appDelegate.player?.play()
    }
    
    func playerPause() {
        
        appDelegate.player?.pause()
        
        if let pictureInPictureController = pictureInPictureController, pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
        }
    }
    
    func saveTime(_ time: CMTime) {
        guard let metadata = self.metadata else { return }
        if metadata.classFile == NCCommunicationCommon.typeClassFile.audio.rawValue { return }

        NCManageDatabase.shared.addVideoTime(metadata: metadata, time: time, durationTime: nil)
        generatorImagePreview()
    }
    
    func saveCurrentTime() {
        
        if let player = appDelegate.player {
            saveTime(player.currentTime())
        }
    }
    
    func videoSeek(time: CMTime) {
        
        appDelegate.player?.seek(to: time)
        self.saveTime(time)
    }
    
    func videoRemoved() {

        playerPause()

        if let observerAVPlayerItemDidPlayToEndTime = self.observerAVPlayerItemDidPlayToEndTime {
            NotificationCenter.default.removeObserver(observerAVPlayerItemDidPlayToEndTime)
        }
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name(rawValue: NCGlobal.shared.notificationCenterApplicationDidEnterBackground), object: nil)
        
        self.videoLayer?.removeFromSuperlayer()
        
        self.videoLayer = nil
        self.observerAVPlayerItemDidPlayToEndTime = nil
        self.imageVideoContainer = nil
        self.playerToolBar = nil
        self.metadata = nil
    }
        
    func generatorImagePreview() {
        guard let time = appDelegate.player?.currentTime() else { return }
        guard let metadata = self.metadata else { return }
        if metadata.livePhoto { return }
        if metadata.classFile == NCCommunicationCommon.typeClassFile.audio.rawValue { return }

        var image: UIImage?

        if let asset = appDelegate.player?.currentItem?.asset {

            do {
                let fileNamePreviewLocalPath = CCUtility.getDirectoryProviderStoragePreviewOcId(metadata.ocId, etag: metadata.etag)!
                let fileNameIconLocalPath = CCUtility.getDirectoryProviderStorageIconOcId(metadata.ocId, etag: metadata.etag)!
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true
                let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
                image = UIImage(cgImage: cgImage)
                // Preview
                if let data = image?.jpegData(compressionQuality: 0.5) {
                    try data.write(to: URL.init(fileURLWithPath: fileNamePreviewLocalPath), options: .atomic)
                }
                // Icon
                if let data = image?.jpegData(compressionQuality: 0.5) {
                    try data.write(to: URL.init(fileURLWithPath: fileNameIconLocalPath), options: .atomic)
                }
            }
            catch let error as NSError {
                print(error.localizedDescription)
            }
        }
    }
}

extension NCPlayer: AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        activeNCPlayer.insert(self)
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        // nothing
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        //nothing
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard let metadata = self.metadata else { return }

        if !isPlay() {
            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterShowPlayerToolBar, userInfo: ["ocId":metadata.ocId, "enableTimerAutoHide": false])
        }
    }
}

