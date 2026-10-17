import AVFoundation

enum AudioConversion {

    /// 把一个 PCM buffer 转成目标格式。调用方负责复用 converter（同一个源格式）。
    static func convert(_ source: AVAudioPCMBuffer,
                        to target: AVAudioFormat,
                        using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0 else { return nil }

        let ratio = target.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return source
        }

        if status == .error { return nil }
        guard output.frameLength > 0 else { return nil }
        return output
    }
}
