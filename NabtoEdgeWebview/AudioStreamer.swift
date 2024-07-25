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

class AudioStreamer {
    // AVAudioEngine
    let engine = AVAudioEngine()
    let audioSession = AVAudioSession.sharedInstance()
    let mixerNode: AVAudioMixerNode
    let playerNode = AVAudioPlayerNode()
    let sampleRate: Double
    let sampleRateConversion: Double
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    let formatConverter: AVAudioConverter
    
    // Audio thread
    var isAudioThreadRunning = true
    var audioThread: Thread! = nil
    
    // TCP stream
    var sockfd = Int32(-1)
    var sockthread: Thread! = nil
    var connectionHost: String! = nil
    var connectionPort: UInt16 = 0
    
    // Test producer
    var testProducer: Thread! = nil
    
    // Circular buffer
    let circularBuffer = UnsafeMutablePointer<TPCircularBuffer>.allocate(capacity: 1)
    let sampleSize = MemoryLayout<Int16>.size
    
    init() {
        try! audioSession.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try! audioSession.setActive(true)
        mixerNode = engine.mainMixerNode
        
        sampleRate = 8000.0
        outputFormat = mixerNode.outputFormat(forBus: 0)
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)!
        formatConverter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        
        sampleRateConversion = inputFormat.sampleRate / outputFormat.sampleRate
        
        engine.attach(playerNode)
        engine.connect(playerNode, to: mixerNode, format: playerNode.outputFormat(forBus: 0))
        try! engine.start()
        playerNode.play()
        
        // allow 5 seconds of buffered audio
        let bufferSizeInSeconds = 5
        let bufferSize = Int(sampleRate) * bufferSizeInSeconds * sampleSize
        _TPCircularBufferInit(circularBuffer, UInt32(bufferSize), MemoryLayout<TPCircularBuffer>.size)
        
        audioThread = Thread.init(target: self, selector: #selector(audioConsumer), object: nil)
        audioThread.start()
    }
    
    deinit {
        isAudioThreadRunning = false
        audioThread.cancel()
        TPCircularBufferCleanup(circularBuffer)
        circularBuffer.deallocate()
    }
    
    func connectTo(host: String, port: UInt16) {
        connectionHost = host
        connectionPort = port
        sockthread = Thread.init(target: self, selector: #selector(tcpStreamThread), object: nil)
        sockthread.start()
    }
    
    @objc
    func audioConsumer() {
        // NOTE this likely needs to be tweaked significantly.
        // we use (sampleRate / 4) --> 250ms worth of samples in the buffer
        // and poll the circular buffer every 200ms by sleeping the thread
        var availableBytes = UInt32(0)
        let minSamples = Int(sampleRate / 4)
        let minBytes = UInt32(minSamples * sampleSize)
        let sleepDuration = TimeBase.toAbs(nanos: 200 * TimeBase.NANOS_PER_MILLISEC)
        
        while isAudioThreadRunning {
            let tail = TPCircularBufferTail(circularBuffer, &availableBytes)
            
            if let tail = tail, availableBytes > minBytes {
                let sampleCount = minSamples
                let samplePtr = tail.bindMemory(to: Int16.self, capacity: sampleCount)
                
                let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: UInt32(sampleCount))!
                pcmBuffer.frameLength = UInt32(sampleCount)
                let channel = pcmBuffer.int16ChannelData![0]
                
                memcpy(channel, samplePtr, sampleCount * sampleSize)
                
                let capacity = UInt32(Double(pcmBuffer.frameCapacity) / sampleRateConversion)
                let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
                convertedBuffer.frameLength = capacity
                
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = AVAudioConverterInputStatus.haveData
                    return pcmBuffer
                }
                
                var error: NSError? = nil
                formatConverter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
                
                if error != nil {
                    fatalError(error!.localizedDescription)
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
        while true {
            let head = TPCircularBufferHead(circularBuffer, &availableBytes)
            let bytesRead = read(sockfd, buffer, bufferSize)
            if bytesRead > 0, let head = head, availableBytes > bytesRead {
                memcpy(head, buffer, bytesRead)
                TPCircularBufferProduce(circularBuffer, UInt32(bytesRead))
            } else {
                print("ERROR: audio ringbuffer is full \(bytesRead) needed, \(availableBytes) available")
            }
        }
    }
    
    private func connectSocket() {
        sockfd = socket(AF_INET, SOCK_STREAM, 0)
        if sockfd == -1 {
            fatalError("Socket failed to be created")
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
            fatalError("failed to connect")
        } else {
            print("connected")
        }
    }
}

