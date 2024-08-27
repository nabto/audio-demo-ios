//
//  AudioStreamer.swift
//  NabtoEdgeWebview
//
//  Created by Ahmad Saleh on 23/07/2024.
//  Copyright © 2024 Nabto. All rights reserved.
//

import Foundation
import AVFoundation
import TPCircularBuffer

fileprivate class TimeBase {
    static let NANOS_PER_USEC: UInt64 = 1000
    static let NANOS_PER_MILLISEC: UInt64 = 1000 * NANOS_PER_USEC
    static let NANOS_PER_SEC: UInt64 = 1000 * NANOS_PER_MILLISEC

    static var timebaseInfo: mach_timebase_info! = {
        var tb = mach_timebase_info(numer: 0, denom: 0)
        let status = mach_timebase_info(&tb)
        if status == KERN_SUCCESS {
            return tb
        } else {
            return nil
        }
    }()

    static func toNanos(abs:UInt64) -> UInt64 {
        return (abs * UInt64(timebaseInfo.numer)) / UInt64(timebaseInfo.denom)
    }

    static func toAbs(nanos:UInt64) -> UInt64 {
        return (nanos * UInt64(timebaseInfo.denom)) / UInt64(timebaseInfo.numer)
    }
}

enum AudioStreamerError: Error {
    case socketFailedToConnect
    case streamToSpeakerFormatConversionFailed
    case recordingToStreamFormatConversionFailed
    case audioRingbufferFull
}

class AudioStreamer {
    // AVAudioEngine
    private let engine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let streamSampleRate: Double
    private let mixerNode: AVAudioMixerNode
    private let playerNode = AVAudioPlayerNode()
    private let playerMixer = AVAudioMixerNode()
    
    // Formats and converters
    private let audioStreamFormat: AVAudioFormat    // Format sent across network
    private let speakerFormat: AVAudioFormat        // Format required for playing on phone speakers
    private let recordingFormat: AVAudioFormat      // Format of audio that comes from microphone
    private let streamToSpeakerConverter: AVAudioConverter
    private let recordingToStreamConverter: AVAudioConverter
    private let streamToSpeakerSampleRateConversion: Double
    private let recordingToStreamSampleRateConversion: Double
    
    // Audio thread
    private var isAudioThreadRunning = true
    private var audioThread: Thread! = nil
    
    // TCP stream
    private var sockfd = Int32(-1)
    private var sockthread: Thread! = nil
    private var connectionHost: String! = nil
    private var connectionPort: UInt16 = 0
    private var isConnected = false
    
    // Circular buffer
    private let circularBuffer = UnsafeMutablePointer<TPCircularBuffer>.allocate(capacity: 1)
    private let streamSampleSize = MemoryLayout<Int16>.size
    
    // Recording
    var isRecording = false
    
    // Callbacks
    var onError: ((_ error: AudioStreamerError) -> ())? = nil
    
    init() {
        try! audioSession.setCategory(.playAndRecord)
        try! audioSession.overrideOutputAudioPort(.speaker)
        try! audioSession.setActive(true)
        mixerNode = engine.mainMixerNode
        
        streamSampleRate = 8000.0
        
        speakerFormat = mixerNode.outputFormat(forBus: 0)
        audioStreamFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: streamSampleRate, channels: 1, interleaved: false)!
        recordingFormat = engine.inputNode.inputFormat(forBus: 0)
        
        streamToSpeakerConverter = AVAudioConverter(from: audioStreamFormat, to: speakerFormat)!
        recordingToStreamConverter = AVAudioConverter(from: recordingFormat, to: audioStreamFormat)!
        
        streamToSpeakerSampleRateConversion = audioStreamFormat.sampleRate / speakerFormat.sampleRate
        recordingToStreamSampleRateConversion = recordingFormat.sampleRate / audioStreamFormat.sampleRate
        
        // engine setup
        engine.attach(playerNode)
        engine.attach(playerMixer)
        engine.connect(playerNode, to: playerMixer, format: playerNode.outputFormat(forBus: 0))
        engine.connect(playerMixer, to: mixerNode, format: playerMixer.outputFormat(forBus: 0))
        
        engine.prepare()
        try! engine.start()
        playerNode.play()
        
        // allow 5 seconds of buffered audio
        let bufferSizeInSeconds = 5
        let bufferSize = Int(streamSampleRate) * bufferSizeInSeconds * streamSampleSize
        _TPCircularBufferInit(circularBuffer, UInt32(bufferSize), MemoryLayout<TPCircularBuffer>.size)
        
        audioThread = Thread.init(target: self, selector: #selector(audioConsumer), object: nil)
        audioThread.start()
    }
    
    func close() {
        isAudioThreadRunning = false
        isConnected = false
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        
        audioThread.cancel()
        sockthread.cancel()
        
        TPCircularBufferCleanup(circularBuffer)
        circularBuffer.deallocate()
        
        Darwin.close(sockfd)
    }
    
    func connectTo(host: String, port: UInt16) {
        connectionHost = host
        connectionPort = port
        sockthread = Thread.init(target: self, selector: #selector(tcpStreamThread), object: nil)
        sockthread.start()
    }
    
    func startRecording() {
        if !isConnected { return }
        
        isRecording = true
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: self.recordingFormat,
            block: { (buffer, when) in
                let capacity = UInt32(Double(buffer.frameCapacity) / self.recordingToStreamSampleRateConversion)
                let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.audioStreamFormat, frameCapacity: capacity)!
                let len = UInt32(Double(buffer.frameLength) / self.recordingToStreamSampleRateConversion)
                convertedBuffer.frameLength = len
                
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = AVAudioConverterInputStatus.haveData
                    return buffer
                }
                
                var error: NSError? = nil
                self.recordingToStreamConverter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
                
                if error != nil {
                    self.onError?(.recordingToStreamFormatConversionFailed)
                } else {
                    write(self.sockfd, convertedBuffer.int16ChannelData![0], Int(len) * self.streamSampleSize)
                }
            }
        )
    }
    
    func stopRecording() {
        if !isConnected { return }
        
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
    }
    
    func setVolume(to: Float) {
        playerMixer.volume = to
    }
    
    @objc
    func audioConsumer() {
        // NOTE this likely needs to be tweaked significantly.
        // we use (sampleRate / 4) --> 250ms worth of samples in the buffer
        // and poll the circular buffer every 200ms by sleeping the thread
        var availableBytes = UInt32(0)
        let minSamples = Int(streamSampleRate / 4)
        let minBytes = UInt32(minSamples * streamSampleSize)
        let sleepDuration = TimeBase.toAbs(nanos: 200 * TimeBase.NANOS_PER_MILLISEC)
        
        while isAudioThreadRunning {
            let tail = TPCircularBufferTail(circularBuffer, &availableBytes)
            
            if let tail = tail, availableBytes > minBytes {
                let sampleCount = minSamples
                let samplePtr = tail.bindMemory(to: Int16.self, capacity: sampleCount)
                
                let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioStreamFormat, frameCapacity: UInt32(sampleCount))!
                pcmBuffer.frameLength = UInt32(sampleCount)
                let channel = pcmBuffer.int16ChannelData![0]
                
                memcpy(channel, samplePtr, sampleCount * streamSampleSize)
                
                let capacity = UInt32(Double(pcmBuffer.frameCapacity) / streamToSpeakerSampleRateConversion)
                let convertedBuffer = AVAudioPCMBuffer(pcmFormat: speakerFormat, frameCapacity: capacity)!
                convertedBuffer.frameLength = capacity
                
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = AVAudioConverterInputStatus.haveData
                    return pcmBuffer
                }
                
                var error: NSError? = nil
                streamToSpeakerConverter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
                
                if error != nil {
                    self.onError?(.streamToSpeakerFormatConversionFailed)
                } else {
                    playerNode.scheduleBuffer(convertedBuffer)
                    TPCircularBufferConsume(circularBuffer, minBytes)
                }
            }
            
            // mach_wait_until for low latency sleep
            let endTime = mach_absolute_time()
            mach_wait_until(endTime + sleepDuration)
        }
    }
    
    @objc
    private func tcpStreamThread() {
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        var availableBytes = UInt32(0)
        
        connectSocket()
        while isAudioThreadRunning {
            let head = TPCircularBufferHead(circularBuffer, &availableBytes)
            let bytesRead = read(sockfd, buffer, bufferSize)
            if bytesRead > 0 {
                if let head = head, availableBytes > bytesRead {
                    memcpy(head, buffer, bytesRead)
                    TPCircularBufferProduce(circularBuffer, UInt32(bytesRead))
                } else {
                    print("ERROR: audio ringbuffer is full \(bytesRead) needed, \(availableBytes) available")
                }
            }
        }
    }
    
    private func connectSocket() {
        sockfd = socket(AF_INET, SOCK_STREAM, 0)
        if sockfd == -1 {
            self.onError?(.socketFailedToConnect)
        }
        
        var addr = sockaddr_in()
        addr.sin_family = UInt8(AF_INET)
        addr.sin_addr.s_addr = inet_addr(connectionHost)
        addr.sin_port = connectionPort.bigEndian
        
        let connectResult = withUnsafePointer(to: addr) {
            return $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr in
                return connect(sockfd, sockaddr, UInt32(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if connectResult != 0 {
            self.onError?(.socketFailedToConnect)
        } else {
            isConnected = true
        }
    }
}

