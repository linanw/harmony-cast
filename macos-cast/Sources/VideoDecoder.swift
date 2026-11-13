import AVFoundation

/// Accepts one complete H.264 Annex B access unit per call.
final class VideoDecoder {
    private var sps = Data()
    private var pps = Data()
    private var format: CMVideoFormatDescription?
    var onSample: ((CMSampleBuffer, CMVideoDimensions) -> Void)?

    func reset() {
        sps.removeAll()
        pps.removeAll()
        format = nil
    }

    func consume(_ accessUnit: Data) throws {
        let units = Self.nalUnits(accessUnit)
        var picture = Data()
        for unit in units {
            guard let first = unit.first else { continue }
            switch first & 0x1f {
            case 7:
                if sps != unit { sps = unit; format = nil }
            case 8:
                if pps != unit { pps = unit; format = nil }
            case 1, 5, 6:
                var count = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &count) { picture.append(contentsOf: $0) }
                picture.append(unit)
            default:
                break
            }
        }
        guard !sps.isEmpty, !pps.isEmpty, !picture.isEmpty else { return }
        if format == nil {
            let result = sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
            guard result == noErr else { throw DecodeError.status(result) }
        }
        guard let format else { return }
        var block: CMBlockBuffer?
        var result = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: picture.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: picture.count, flags: 0, blockBufferOut: &block)
        guard result == noErr, let block else { throw DecodeError.status(result) }
        result = picture.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: picture.count)
        }
        guard result == noErr else { throw DecodeError.status(result) }
        var sample: CMSampleBuffer?
        var size = picture.count
        result = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw DecodeError.status(result) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(item,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        onSample?(sample, CMVideoFormatDescriptionGetDimensions(format))
    }

    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var ranges: [Range<Int>] = []
        var start: Int?
        var cursor = 0
        while cursor + 2 < bytes.count {
            var prefix = 0
            if bytes[cursor] == 0, bytes[cursor + 1] == 0 {
                if bytes[cursor + 2] == 1 {
                    prefix = 3
                } else if cursor + 3 < bytes.count, bytes[cursor + 2] == 0, bytes[cursor + 3] == 1 {
                    prefix = 4
                }
            }
            if prefix > 0 {
                if let start, cursor > start { ranges.append(start..<cursor) }
                cursor += prefix
                start = cursor
            } else {
                cursor += 1
            }
        }
        if let start, start < bytes.count { ranges.append(start..<bytes.count) }
        return ranges.map { Data(bytes[$0]) }
    }
}

enum DecodeError: Error {
    case status(OSStatus)
}
