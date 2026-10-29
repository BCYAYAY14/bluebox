@preconcurrency import AVFoundation
import MediaToolbox

/// Runs `AudioEffectsDSP` inside AVPlayer through an `MTAudioProcessingTap` on
/// the item's audio mix. Works for files and progressive downloads; AVFoundation
/// ignores audio mixes for HLS.
enum AudioEffectsTap {
    /// An audio mix with one tap per audio track, all reading `switches`.
    static func audioMix(for tracks: [AVAssetTrack], switches: AudioEffectsSwitch) -> AVAudioMix? {
        let params: [AVMutableAudioMixInputParameters] = tracks.compactMap { track in
            guard let tap = makeTap(switches: switches) else { return nil }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTapProcessor = tap
            return p
        }
        guard !params.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    /// Per-tap state, owned by the tap (retained in init, released in finalize).
    final class Context: @unchecked Sendable {
        let dsp: AudioEffectsDSP
        var channelCount = 0
        var interleaved = false
        var isFloat32 = false
        var pointers: [UnsafeMutablePointer<Float>] = []
        init(switches: AudioEffectsSwitch) { dsp = AudioEffectsDSP(switches: switches) }
    }

    private static func makeTap(switches: AudioEffectsSwitch) -> MTAudioProcessingTap? {
        let context = Context(switches: switches)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let asbd = format.pointee
                ctx.channelCount = Int(asbd.mChannelsPerFrame)
                ctx.interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                ctx.isFloat32 = asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && asbd.mBitsPerChannel == 32
                ctx.pointers.reserveCapacity(max(ctx.channelCount, 1))
                ctx.dsp.prepare(sampleRate: asbd.mSampleRate, channels: ctx.channelCount)
            },
            unprepare: { _ in },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard ctx.isFloat32, ctx.channelCount > 0 else { return }
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                let count = Int(framesOut.pointee)
                ctx.pointers.removeAll(keepingCapacity: true)
                if ctx.interleaved {
                    guard let data = buffers.first?.mData else { return }
                    let base = data.assumingMemoryBound(to: Float.self)
                    for c in 0..<ctx.channelCount { ctx.pointers.append(base + c) }
                    ctx.dsp.process(ctx.pointers, stride: ctx.channelCount, frames: count)
                } else {
                    for b in buffers { if let d = b.mData { ctx.pointers.append(d.assumingMemoryBound(to: Float.self)) } }
                    guard ctx.pointers.count == ctx.channelCount else { return }
                    ctx.dsp.process(ctx.pointers, stride: 1, frames: count)
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<Context>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }
}
