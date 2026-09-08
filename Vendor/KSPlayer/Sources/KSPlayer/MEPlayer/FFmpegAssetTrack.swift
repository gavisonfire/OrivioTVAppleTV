//
//  FFmpegAssetTrack.swift
//  KSPlayer
//
//  Created by kintan on 2023/2/12.
//

import AVFoundation
import FFmpegKit
import Libavformat

public class FFmpegAssetTrack: MediaPlayerTrack {
    public private(set) var trackID: Int32 = 0
    public let codecName: String
    public var name: String = ""
    public private(set) var languageCode: String?
    public var nominalFrameRate: Float = 0
    public private(set) var avgFrameRate = Timebase.defaultValue
    public private(set) var realFrameRate = Timebase.defaultValue
    public private(set) var bitRate: Int64 = 0
    public let mediaType: AVFoundation.AVMediaType
    public let formatName: String?
    public let bitDepth: Int32
    private var stream: UnsafeMutablePointer<AVStream>?
    var startTime = CMTime.zero
    var codecpar: AVCodecParameters
    var timebase: Timebase = .defaultValue
    let bitsPerRawSample: Int32
    // audio
    public let audioDescriptor: AudioDescriptor?
    // subtitle
    public let isImageSubtitle: Bool
    public var delay: TimeInterval = 0
    var subtitle: SyncPlayerItemTrack<SubtitleFrame>?
    // video
    public private(set) var rotation: Int16 = 0
    public var dovi: DOVIDecoderConfigurationRecord?
    public let fieldOrder: FFmpegFieldOrder
    public let formatDescription: CMFormatDescription?
    var closedCaptionsTrack: FFmpegAssetTrack?
    let isConvertNALSize: Bool
    var seekByBytes = false
    public var description: String {
        var description = codecName
        if let formatName {
            description += ", \(formatName)"
        }
        if bitsPerRawSample > 0 {
            description += "(\(bitsPerRawSample.kmFormatted) bit)"
        }
        if let audioDescriptor {
            description += ", \(audioDescriptor.sampleRate)Hz"
            description += ", \(audioDescriptor.channel.description)"
        }
        if let formatDescription {
            if mediaType == .video {
                let naturalSize = formatDescription.naturalSize
                description += ", \(Int(naturalSize.width))x\(Int(naturalSize.height))"
                description += String(format: ", %.2f fps", nominalFrameRate)
            }
        }
        if bitRate > 0 {
            description += ", \(bitRate.kmFormatted)bps"
        }
        if let language {
            description += "(\(language))"
        }
        return description
    }

    convenience init?(stream: UnsafeMutablePointer<AVStream>) {
        let codecpar = stream.pointee.codecpar.pointee
        self.init(codecpar: codecpar)
        self.stream = stream
        let metadata = toDictionary(stream.pointee.metadata)
        if let value = metadata["variant_bitrate"] ?? metadata["BPS"], let bitRate = Int64(value) {
            self.bitRate = bitRate
        }
        trackID = stream.pointee.index
        var timebase = Timebase(stream.pointee.time_base)
        if timebase.num <= 0 || timebase.den <= 0 {
            timebase = Timebase(num: 1, den: 1000)
        }
        if stream.pointee.start_time != Int64.min {
            startTime = timebase.cmtime(for: stream.pointee.start_time)
        }
        self.timebase = timebase
        avgFrameRate = Timebase(stream.pointee.avg_frame_rate)
        realFrameRate = Timebase(stream.pointee.r_frame_rate)
        if mediaType == .audio {
            var frameSize = codecpar.frame_size
            if frameSize < 1 {
                frameSize = timebase.den / timebase.num
            }
            nominalFrameRate = max(Float(codecpar.sample_rate / frameSize), 48)
        } else {
            if stream.pointee.duration > 0, stream.pointee.nb_frames > 0, stream.pointee.nb_frames != stream.pointee.duration {
                nominalFrameRate = Float(stream.pointee.nb_frames) * Float(timebase.den) / Float(stream.pointee.duration) * Float(timebase.num)
            } else if avgFrameRate.den > 0, avgFrameRate.num > 0 {
                nominalFrameRate = Float(avgFrameRate.num) / Float(avgFrameRate.den)
            } else {
                nominalFrameRate = 24
            }
        }

        if let value = metadata["language"], value != "und" {
            languageCode = value
        } else {
            languageCode = nil
        }
        if let value = metadata["title"] {
            name = value
        } else {
            name = languageCode ?? codecName
        }
        // AV_DISPOSITION_DEFAULT
        if mediaType == .subtitle {
            isEnabled = !isImageSubtitle || stream.pointee.disposition & AV_DISPOSITION_FORCED == AV_DISPOSITION_FORCED
            if stream.pointee.disposition & AV_DISPOSITION_HEARING_IMPAIRED == AV_DISPOSITION_HEARING_IMPAIRED {
                name += "(hearing impaired)"
            }
        }
        //        var buf = [Int8](repeating: 0, count: 256)
        //        avcodec_string(&buf, buf.count, codecpar, 0)
    }

    init?(codecpar: AVCodecParameters) {
        self.codecpar = codecpar
        bitRate = codecpar.bit_rate
        // codec_tag byte order is LSB first CMFormatDescription.MediaSubType(rawValue: codecpar.codec_tag.bigEndian)
        let codecType = codecpar.codec_id.mediaSubType
        var codecName = ""
        if let descriptor = avcodec_descriptor_get(codecpar.codec_id) {
            codecName += String(cString: descriptor.pointee.name)
            if let profile = descriptor.pointee.profiles {
                codecName += " (\(String(cString: profile.pointee.name)))"
            }
        } else {
            codecName = ""
        }
        self.codecName = codecName
        fieldOrder = FFmpegFieldOrder(rawValue: UInt8(codecpar.field_order.rawValue)) ?? .unknown
        var formatDescriptionOut: CMFormatDescription?
        if codecpar.codec_type == AVMEDIA_TYPE_AUDIO {
            mediaType = .audio
            audioDescriptor = AudioDescriptor(codecpar: codecpar)
            isConvertNALSize = false
            bitDepth = 0
            let layout = codecpar.ch_layout
            let channelsPerFrame = UInt32(layout.nb_channels)
            let sampleFormat = AVSampleFormat(codecpar.format)
            let bytesPerSample = UInt32(av_get_bytes_per_sample(sampleFormat))
            let formatFlags = ((sampleFormat == AV_SAMPLE_FMT_FLT || sampleFormat == AV_SAMPLE_FMT_DBL) ? kAudioFormatFlagIsFloat : sampleFormat == AV_SAMPLE_FMT_U8 ? 0 : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
            var audioStreamBasicDescription = AudioStreamBasicDescription(mSampleRate: Float64(codecpar.sample_rate), mFormatID: codecType.rawValue, mFormatFlags: formatFlags, mBytesPerPacket: bytesPerSample * channelsPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerSample * channelsPerFrame, mChannelsPerFrame: channelsPerFrame, mBitsPerChannel: bytesPerSample * 8, mReserved: 0)
            _ = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &audioStreamBasicDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescriptionOut)
            if let name = av_get_sample_fmt_name(sampleFormat) {
                formatName = String(cString: name)
            } else {
                formatName = nil
            }
        } else if codecpar.codec_type == AVMEDIA_TYPE_VIDEO {
            audioDescriptor = nil
            mediaType = .video
            if codecpar.nb_coded_side_data > 0, let sideDatas = codecpar.coded_side_data {
                for i in 0 ..< codecpar.nb_coded_side_data {
                    let sideData = sideDatas[Int(i)]
                    if sideData.type == AV_PKT_DATA_DOVI_CONF {
                        dovi = sideData.data.withMemoryRebound(to: DOVIDecoderConfigurationRecord.self, capacity: 1) { $0 }.pointee
                    } else if sideData.type == AV_PKT_DATA_DISPLAYMATRIX {
                        let matrix = sideData.data.withMemoryRebound(to: Int32.self, capacity: 1) { $0 }
                        let rawRotation = -av_display_rotation_get(matrix)
                        if rawRotation.isFinite {
                            let degrees = Int(rawRotation.rounded())
                            let normalized = ((degrees % 360) + 360) % 360
                            rotation = Int16(normalized)
                        } else {
                            rotation = 0
                        }                        
                    }
                }
            }
            let sar = codecpar.sample_aspect_ratio.size
            var extradataSize = Int32(0)
            var extradata = codecpar.extradata
            let atomsData: Data?
            if let extradata {
                extradataSize = codecpar.extradata_size
                if extradataSize >= 5, extradata[4] == 0xFE {
                    extradata[4] = 0xFF
                    isConvertNALSize = true
                } else {
                    isConvertNALSize = false
                }
                atomsData = Data(bytes: extradata, count: Int(extradataSize))
            } else {
                if codecType.rawValue == kCMVideoCodecType_VP9 {
                    // ff_videotoolbox_vpcc_extradata_create
                    var ioContext: UnsafeMutablePointer<AVIOContext>?
                    guard avio_open_dyn_buf(&ioContext) == 0 else {
                        return nil
                    }
                    ff_isom_write_vpcc(nil, ioContext, nil, 0, &self.codecpar)
                    extradataSize = avio_close_dyn_buf(ioContext, &extradata)
                    guard let extradata else {
                        return nil
                    }
                    var data = Data()
                    var array: [UInt8] = [1, 0, 0, 0]
                    data.append(&array, count: 4)
                    data.append(extradata, count: Int(extradataSize))
                    atomsData = data
                } else {
                    atomsData = nil
                }
                isConvertNALSize = false
            }
            let format = AVPixelFormat(rawValue: codecpar.format)
            bitDepth = format.bitDepth
            // Orivio: recover missing colour signalling from the BITSTREAM.
            //
            // The demuxer's codecpar can say UNSPECIFIED for primaries /
            // transfer / matrix even when the SPS VUI carries the real values
            // (verified on a 2160p HDR remux: codecpar said 2/2/2 with a 16 MB
            // probe budget, so this is not a probe-size artefact). Everything
            // downstream trusts codecpar: the format description is built with
            // no colour extensions, VideoToolbox tags its output BT.709, and
            // HDR plays as washed-out SDR.
            //
            // avcodec parses the parameter sets out of extradata at open time
            // and exports the VUI colour description onto the context — so a
            // single-threaded open with NO frames decoded reads the
            // bitstream's own answer. Only attempted when something is
            // actually missing; tagged files pay nothing.
            var colorPrimaries = codecpar.color_primaries
            var colorTrc = codecpar.color_trc
            var colorSpace = codecpar.color_space
            var colorRange = codecpar.color_range
            if colorPrimaries == AVCOL_PRI_UNSPECIFIED || colorTrc == AVCOL_TRC_UNSPECIFIED
                || colorSpace == AVCOL_SPC_UNSPECIFIED || colorRange == AVCOL_RANGE_UNSPECIFIED,
                let sniffed = Self.bitstreamColor(codecpar: self.codecpar) {
                if colorPrimaries == AVCOL_PRI_UNSPECIFIED { colorPrimaries = sniffed.primaries }
                if colorTrc == AVCOL_TRC_UNSPECIFIED { colorTrc = sniffed.trc }
                if colorSpace == AVCOL_SPC_UNSPECIFIED { colorSpace = sniffed.space }
                if colorRange == AVCOL_RANGE_UNSPECIFIED { colorRange = sniffed.range }
                // Keep the stored copy coherent for every later reader.
                self.codecpar.color_primaries = colorPrimaries
                self.codecpar.color_trc = colorTrc
                self.codecpar.color_space = colorSpace
                self.codecpar.color_range = colorRange
                KSColorProbe.once("bitstream") {
                    "bitstream recovery (SPS VUI):"
                        + " spc=\(sniffed.space.rawValue)->\(ksProbeTag(sniffed.space.ycbcrMatrix))"
                        + " pri=\(sniffed.primaries.rawValue)->\(ksProbeTag(sniffed.primaries.colorPrimaries))"
                        + " trc=\(sniffed.trc.rawValue)->\(ksProbeTag(sniffed.trc.transferFunction))"
                        + " range=\(sniffed.range.rawValue)"
                }
            } else if colorPrimaries == AVCOL_PRI_UNSPECIFIED || colorTrc == AVCOL_TRC_UNSPECIFIED {
                KSColorProbe.once("bitstream") { "bitstream recovery: nothing recoverable (decoder open failed or codec unsupported)" }
            }
            let fullRange = colorRange == AVCOL_RANGE_JPEG
            let dic: NSMutableDictionary = [
                kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Left,
                kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
                kCMFormatDescriptionExtension_Depth: format.bitDepth * Int32(format.planeCount),
                kCMFormatDescriptionExtension_FullRangeVideo: fullRange,
                codecType.rawValue == kCMVideoCodecType_HEVC ? "EnableHardwareAcceleratedVideoDecoder" : "RequireHardwareAcceleratedVideoDecoder": true,
            ]
            // kCMFormatDescriptionExtension_BitsPerComponent
            if let atomsData {
                dic[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [codecType.rawValue.avc: atomsData]
            }
            dic[kCVPixelBufferPixelFormatTypeKey] = format.osType(fullRange: fullRange)
            dic[kCVImageBufferPixelAspectRatioKey] = sar.aspectRatio
            dic[kCVImageBufferColorPrimariesKey] = colorPrimaries.colorPrimaries as String?
            dic[kCVImageBufferTransferFunctionKey] = colorTrc.transferFunction as String?
            dic[kCVImageBufferYCbCrMatrixKey] = colorSpace.ycbcrMatrix as String?
            // Orivio probe: the SOURCE of every colour decision downstream.
            // Each tag is reported as the raw ffmpeg enum AND what it mapped
            // to — a raw 2 (UNSPECIFIED) mapping to nil is the case that
            // silently becomes BT.601 + sRGB further down.
            KSColorProbe.once("track") {
                let pixName = av_get_pix_fmt_name(format).map { String(cString: $0) } ?? "?"
                return "track \(codecpar.width)x\(codecpar.height) \(pixName) depth=\(format.bitDepth)"
                    + " planes=\(format.planeCount) leftShift=\(format.leftShift)"
                    + " range=\(codecpar.color_range.rawValue)(\(fullRange ? "full" : "video"))"
                    + " spc=\(codecpar.color_space.rawValue)->\(ksProbeTag(codecpar.color_space.ycbcrMatrix))"
                    + " pri=\(codecpar.color_primaries.rawValue)->\(ksProbeTag(codecpar.color_primaries.colorPrimaries))"
                    + " trc=\(codecpar.color_trc.rawValue)->\(ksProbeTag(codecpar.color_trc.transferFunction))"
                    + " osType=\(ksProbeFourCC(format.osType(fullRange: fullRange)))"
            }
            // The decoder's view of the SPS would settle whether the colour
            // description is in the bitstream, but reading it by opening an
            // HEVC decoder here allocates a decoder and its worker threads at
            // load time — too much to spend inside a diagnostic. Read the VUI
            // straight out of the hvcC bytes instead when this resumes.
            // swiftlint:disable line_length
            _ = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codecType.rawValue, width: codecpar.width, height: codecpar.height, extensions: dic, formatDescriptionOut: &formatDescriptionOut)
            // swiftlint:enable line_length
            if let name = av_get_pix_fmt_name(format) {
                formatName = String(cString: name)
            } else {
                formatName = nil
            }
        } else if codecpar.codec_type == AVMEDIA_TYPE_SUBTITLE {
            mediaType = .subtitle
            audioDescriptor = nil
            formatName = nil
            bitDepth = 0
            isConvertNALSize = false
            _ = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Subtitle, mediaSubType: codecType.rawValue, extensions: nil, formatDescriptionOut: &formatDescriptionOut)
        } else {
            bitDepth = 0
            return nil
        }
        formatDescription = formatDescriptionOut
        bitsPerRawSample = codecpar.bits_per_raw_sample
        isImageSubtitle = [AV_CODEC_ID_DVD_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE, AV_CODEC_ID_DVB_TELETEXT, AV_CODEC_ID_HDMV_PGS_SUBTITLE].contains(codecpar.codec_id)
        trackID = 0
    }

    func createContext(options: KSOptions) throws -> UnsafeMutablePointer<AVCodecContext> {
        try codecpar.createContext(options: options)
    }

    /// The bitstream's own colour description, read from the parameter sets in
    /// `extradata` — the SPS VUI carries primaries/transfer/matrix/range, and
    /// avcodec exports them onto the context when it parses extradata at open.
    ///
    /// No frames are decoded and threading is forced off, so the open is a
    /// parameter-set parse and nothing more. Any failure returns nil and the
    /// caller keeps the demuxer's (unspecified) values — recovery must never
    /// be the reason a track fails to load.
    private static func bitstreamColor(codecpar: AVCodecParameters)
        -> (primaries: AVColorPrimaries, trc: AVColorTransferCharacteristic, space: AVColorSpace, range: AVColorRange)? {
        guard codecpar.codec_id == AV_CODEC_ID_HEVC || codecpar.codec_id == AV_CODEC_ID_H264,
              codecpar.extradata_size > 0,
              let codec = avcodec_find_decoder(codecpar.codec_id),
              let context = avcodec_alloc_context3(codec)
        else { return nil }
        var contextRef: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&contextRef) }
        var par = codecpar
        guard avcodec_parameters_to_context(context, &par) >= 0 else { return nil }
        context.pointee.thread_count = 1
        context.pointee.thread_type = 0
        guard avcodec_open2(context, codec, nil) >= 0 else { return nil }
        return (context.pointee.color_primaries, context.pointee.color_trc,
                context.pointee.colorspace, context.pointee.color_range)
    }

    public var isEnabled: Bool {
        get {
            stream?.pointee.discard == AVDISCARD_DEFAULT
        }
        set {
            var discard = newValue ? AVDISCARD_DEFAULT : AVDISCARD_ALL
            if mediaType == .subtitle, !isImageSubtitle {
                discard = AVDISCARD_DEFAULT
            }
            stream?.pointee.discard = discard
        }
    }
}

extension FFmpegAssetTrack {
    var pixelFormatType: OSType? {
        let format = AVPixelFormat(codecpar.format)
        return format.osType(fullRange: formatDescription?.fullRangeVideo ?? false)
    }
}
