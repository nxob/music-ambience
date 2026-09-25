import Foundation
import CoreMedia
import ScreenCaptureKit

// Listens to your Mac's audio output so the glow can move with the music.
// Needs Screen Recording permission (that's how macOS gates system audio).

struct AudioLevels {
    var rms: Float
    var low: Float
    var high: Float
}

@available(macOS 13.0, *)
final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "afterglow.audio")
    private var lowpass: Float = 0

    var onLevels: ((AudioLevels) -> Void)?
    var onFailure: (() -> Void)?

    func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let self = self else { return }
            guard let content = content, let display = content.displays.first else {
                DispatchQueue.main.async { self.onFailure?() }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.width = 2                  // we don't care about the picture
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                DispatchQueue.main.async { self.onFailure?() }
                return
            }
            stream.startCapture { error in
                if error != nil { DispatchQueue.main.async { self.onFailure?() } }
            }
            self.stream = stream
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        var levels: AudioLevels?
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let buf = list.first, let data = buf.mData else { return }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard n > 0 else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            var all: Float = 0, low: Float = 0, high: Float = 0
            for i in 0..<n {
                let x = samples[i]
                self.lowpass += 0.03 * (x - self.lowpass)   // roughly the bass
                let h = x - self.lowpass                   // everything above it
                all += x * x
                low += self.lowpass * self.lowpass
                high += h * h
            }
            let k = Float(n)
            levels = AudioLevels(rms: sqrt(all / k), low: sqrt(low / k), high: sqrt(high / k))
        }
        if let l = levels {
            DispatchQueue.main.async { self.onLevels?(l) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
    }
}
