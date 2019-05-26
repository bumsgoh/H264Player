//
//  VideoPlayer.swift
//  CustomPlayer
//
//  Created by USER on 10/05/2019.
//  Copyright © 2019 USER. All rights reserved.
//

import Foundation
import VideoToolbox

class MoviePlayer: NSObject {

    private let jobQueue: DispatchQueue = DispatchQueue(label: "decodeQueue")
    private let lockQueue: DispatchQueue = DispatchQueue(label: "com.lockQueue", qos: .userInitiated, attributes: .concurrent, autoreleaseFrequency: .workItem, target: nil)
    private let isFileBasedPlayer: Bool
    private let url: URL
    private let httpConnection: HTTPConnetion
    
    var playContext = 1
    
    private var pastBufferCounts: [Int] = [] {
        didSet {
            if pastBufferCounts.count > 10 {
                let average = pastBufferCounts.reduce(0, {$0 + $1}) / 10
                guard let newValue = pastBufferCounts.last else { return }
                if newValue < average {
                 //   fetchNextItem()
                }
                pastBufferCounts.remove(at: 0)
            }
        }
    }
    
    private var currentPlayingItemIndex: ListIndex?
    private var state: MediaStatus = .stopped
    private var audioDecoder: AudioTrackDecodable?
    private var videoDecoder: VideoTrackDecodable?
    private var audioPlayer: AudioPlayer = AudioPlayer()
    
    private var dataFromDecoder = Data()
    
    private var playing = false
    private var isVideoReady: Bool = false
    private var isAudioReady: Bool = false
    
    private var masterPlaylist: MasterPlaylist?
    
    private var keyValueObservations = [NSKeyValueObservation]()
    
    var totalDuration = 0
    var volume: Float {
        get {
            return audioPlayer.volume
        }
        
        set {
            audioPlayer.volume = newValue
        }
    }
    
    weak var delegate: VideoQueueDelegate?
    
   @objc dynamic var isPlayable: Bool = false
   
    private lazy var queue: DisplayLinkedQueue = {
        let queue: DisplayLinkedQueue = DisplayLinkedQueue()
        queue.delegate = self
        return queue
    }()
  
    init(url: URL) {
        self.httpConnection = HTTPConnetion()
        self.url = url
        if url.isFileURL {
            self.isFileBasedPlayer = true
        } else {
            self.isFileBasedPlayer = false
        }
        super.init()
        setObservers()
    }
    
    deinit {
        queue.removeObserver(self, forKeyPath: "isReady")
        audioPlayer.removeObserver(self, forKeyPath: "isReady")
    }
    
    func setObservers() {
        queue.addObserver(self, forKeyPath: "isReady", options: .new, context: &playContext)
        audioPlayer.addObserver(self, forKeyPath: "isReady", options: .new, context: &playContext)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        guard context == &playContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        
        guard context == &playContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        
        if keyPath == #keyPath(DisplayLinkedQueue.isReady) {
            guard let isPlayable = change?[.newKey] as? Int else { return }
            if isPlayable == 1 {
                isVideoReady = true
            }
        }
        
        if keyPath == #keyPath(AudioPlayer.state) {
            guard let state = change?[.newKey] as? Int else { return }
            print(state)
            if state == 1 {
                isAudioReady = true
            }
        }
        print(isAudioReady)
        print(isVideoReady)
        isPlayable = isAudioReady && isVideoReady
        if isPlayable { queue.startRunning() }
        
    }
    
    func loadPlayerAsynchronously(completion: @escaping (Result<Bool, Error>) -> Void) {
        jobQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isFileBasedPlayer {
                guard let fileReader = FileReader(url: self.url) else { return }
                let mediaFileReader = Mpeg4Parser(fileReader: fileReader)
                
                mediaFileReader.decodeMediaData()
                let tracks = mediaFileReader.makeTracks()
                self.totalDuration = tracks[0].duration
                for track in tracks {
                    var sizeArray: [Int] = []
                    var rawFrames: [Data] = []
                    var presentationTimestamp: [Int] = []
                    
                    for sample in track.samples {
                        
                        mediaFileReader.fileReader.seek(offset: UInt64(sample.offset))
                        mediaFileReader.fileReader.read(length: sample.size) { (data) in
                            rawFrames.append(data)
                            sizeArray.append(data.count)
                        }
                    }
                    presentationTimestamp = track.samples.map {
                        $0.startTime
                    }
                    let dataPackage = DataPackage(presentationTimestamp: presentationTimestamp,
                                                  dataStorage: rawFrames)
                    
                    switch track.mediaType {
                    case .audio:
                        self.audioDecoder = AAC_ADTSDecoder(track: track, dataPackage: dataPackage)
                        self.audioDecoder?.audioDelegate = self
                        self.audioDecoder?.decodeTrack(timeScale: track.timescale)
                    case .video:
                        self.videoDecoder = AvccDecoder(track: track, dataPackage: dataPackage)
                        self.videoDecoder?.videoDelegate = self
                        self.videoDecoder?.decodeTrack(timeScale: track.timescale)
                    case .unknown:
                        completion(.failure(NSError(domain: "fail to decode track", code: -1, userInfo: nil)))
                        return
                    }
                }
                completion(.success(true))
            } else {
               
                self.httpConnection.request(url: self.url) { (result, response) in
                    let startTime = Date()
                    switch result {
                    case .failure:
                        completion(.failure(APIError.requestFailed))
                    case .success(let data):
                        let m3u8Player = M3U8Decoder(rawData: data, url: self.url.absoluteString)
                        guard let masterPlaylist = m3u8Player.parseMasterPlaylist() else {
                            completion(.failure(APIError.invalidData))
                            return
                        }
                        //TODO: initial ts file 설정하기
                        guard let expectedLength = response?.expectedContentLength else { return }
                        let length  = CGFloat(expectedLength) / 1000000.0
                        let elapsed = CGFloat( Date().timeIntervalSince(startTime))
                        let currentNetworkSpeed = length/elapsed
//                        if currentNetworkSpeed < 1 {
//                            m3u8Player.parseMediaPlaylist(list: masterPlaylist.mediaPlaylists[0]) {
//                                self.currentPlayingItemIndex = ListIndex(gear: 0, index: 0)
//                            }
//
//                        } else {
//                            m3u8Player.parseMediaPlaylist(list: masterPlaylist.mediaPlaylists[3]) {
//                                 self.currentPlayingItemIndex = ListIndex(gear: 3, index: 0)
//                            }
//                        }
                        
                        m3u8Player.parseMediaPlaylist(list: masterPlaylist.mediaPlaylists[0]) {
                            self.currentPlayingItemIndex = ListIndex(gear: 0, index: 0)
                            self.masterPlaylist = masterPlaylist
                            guard let currentPlaylist = self.currentPlayingItemIndex else { return }
                            guard let tempPlaylistPath = masterPlaylist
                                .mediaPlaylists[currentPlaylist.gear]
                                .videoMediaSegments[currentPlaylist.index].path else { return }
                          
                           guard let url = URL(string: tempPlaylistPath) else { return }
                            print(url)
                            guard let audioURLString = masterPlaylist.mediaPlaylists[currentPlaylist.gear].audioMediaSegments[currentPlaylist.gear].path else { return }
                            let audioURL = URL(string: audioURLString)
                            
                            
                            self.totalDuration = 5960
                            self.httpConnection.request(url: audioURL) { (result, response) in
                                switch result {
                                case .failure:
                                    completion(.failure(APIError.requestFailed))
                                case .success(let data):
                                    var datas = [Data]()
                                    datas.append(data)
                                    
                                    let dataPackage = DataPackage(presentationTimestamp: [Int](), dataStorage: datas)
                                    self.audioDecoder = AAC_ADTSDecoder(track: Track(type: .audio), dataPackage: dataPackage)
                                    self.audioDecoder?.isAdts = false
                                    self.audioDecoder?.audioDelegate = self
                                    self.audioDecoder?.decodeTrack(timeScale: 44100)
                                }
                            }
     
                            self.httpConnection.request(url: url) { (result, response) in
                            switch result {
                            case .failure:
                                completion(.failure(APIError.requestFailed))
                            case .success(let data):
                                let decoder = TSDecoder(target: data)
                                let tsStreams = decoder.decode()
                                
                                var videoDataArray = [UInt8]()
                                var audioDataArray = [UInt8]()
                                var videoTimings = [CMSampleTimingInfo]()
                                var audioTimings = [CMSampleTimingInfo]()
                                var pts: [Int] = []
                                var datas = [Data]()
                                tsStreams.forEach {
                                    switch $0.type {
                                    case .video:
                                        videoDataArray.append(contentsOf: $0.actualData)
                                        videoTimings.append(CMSampleTimingInfo(duration: CMTime(value: 24, timescale: 1000),
                                                                               presentationTimeStamp: CMTime(value: CMTimeValue($0.pts), timescale: 1000),
                                                                               decodeTimeStamp: CMTime(value: CMTimeValue($0.dts), timescale: 1000)))
                                      
                                    case .audio:
                                        pts.append($0.pts)
                                        datas.append(Data($0.actualData))
                                        audioDataArray.append(contentsOf: $0.actualData)
                                        audioTimings.append(CMSampleTimingInfo(duration: CMTime(value: 3000, timescale: 30000),
                                                                                presentationTimeStamp: CMTime(value: CMTimeValue($0.pts), timescale: 30000),
                                                                                decodeTimeStamp: CMTime(value: CMTimeValue($0.dts), timescale: 30000)))
                                    case .unknown:
                                        return
                                    }
                                }
                                let h264Decoder = H264Decoder(frames: videoDataArray, presentationTimestamps: videoTimings)
                                h264Decoder.videoDecoderDelegate = self
                                h264Decoder.decode()
                                
                                if !audioDataArray.isEmpty {
                                    let dataPackage = DataPackage(presentationTimestamp: pts, dataStorage: datas)
                                    self.audioDecoder = AAC_ADTSDecoder(track: Track(type: .audio), dataPackage: dataPackage)
                                    self.audioDecoder?.audioDelegate = self
                                    self.audioDecoder?.decodeTrack(timeScale: 44100)
                                }
                                 completion(.success(true))
                            }
                        }
                    }
                }
            }
        }
    }
}
    
    private func fetchNextItem() {
        guard let masterPlaylist = masterPlaylist, let currentIndex = currentPlayingItemIndex else { return }
        if currentIndex.index > 98 {return}
        let nextIndex = ListIndex(gear: currentIndex.gear, index: currentIndex.index + 1)
        currentPlayingItemIndex = nextIndex
        guard let stringPath = masterPlaylist.mediaPlaylists[nextIndex.gear].videoMediaSegments[nextIndex.index].path else { return }
        print(stringPath)
        httpConnection.request(url: URL(string: stringPath)) { (result, response) in
            switch result {
            case .failure:
                assertionFailure("failed to fetch")
            case .success(let data):
                let decoder = TSDecoder(target: data)
                let result = decoder.decode()
                var dataArray = [UInt8]()
                var timings = [CMSampleTimingInfo]()
                result.forEach {
                    dataArray.append(contentsOf: $0.actualData)
                    let pts = $0.pts % 10 == 0 ? $0.pts : $0.pts + 1
                    let dts = $0.dts % 10 == 0 ? $0.dts : $0.dts + 1
                    timings.append(CMSampleTimingInfo(duration: CMTime(value: 3000, timescale: 30000),
                                                      presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 30000),
                                                      decodeTimeStamp: CMTime.invalid)) //CMTime(value: CMTimeValue($0.dts), timescale: 30000) ))
                }
                let h264Decoder = H264Decoder(frames: dataArray,
                                              presentationTimestamps: timings)
                h264Decoder.videoDecoderDelegate = self
                h264Decoder.decode()
            }
            
        }
       
    }
    
    func play() {
        if isPlayable { queue.startRunning() }
        
        if !playing {
            audioPlayer.playIfNeeded()
        }
        playing = true
    }
    
    func pause() {
        queue.stopRunning()
        audioPlayer.pause()
        playing = false
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer.seek(to: time)
        audioPlayer.parseDeliveredData(data: dataFromDecoder)
    }
}

extension MoviePlayer: MultiMediaAudioTypeDecoderDelegate {
    func prepareToPlay(with data: Data) {
        isAudioReady = true
    
        dataFromDecoder = data
        audioPlayer.parseDeliveredData(data: data)
    }
    
}

extension MoviePlayer: MultiMediaVideoTypeDecoderDelegate {
    func prepareToDisplay(with buffers: CMSampleBuffer) {
       
         queue.enqueue(buffers)
       
    }
    
}

protocol VideoQueueDelegate: class {
     func displayQueue(with buffers: CMSampleBuffer)
}


extension MoviePlayer: DisplayLinkedQueueDelegate {
    // MARK: DisplayLinkedQueue
    func queue(_ buffer: CMSampleBuffer) {

        delegate?.displayQueue(with: buffer)
        if playing {
            self.audioPlayer.playIfNeeded()
        }
    }
}

struct ListIndex {
    var gear: Int
    var index: Int
}

