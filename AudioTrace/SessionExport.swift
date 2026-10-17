import Foundation

// ZIP "store" method with streamed CRC and data descriptors. No third party library,
// no whole-recording Data allocation. ZIP32 limits are checked before writing.
enum SessionExporter {
    private struct Entry { var name: Data; var crc: UInt32; var size: UInt32; var offset: UInt32 }
    private static let table: [UInt32] = (0..<256).map { n in
        var crc = UInt32(n)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : 0xedb88320 ^ (crc >> 1) }
        return crc
    }
    static func zip(folder: URL, destination: URL) throws -> URL {
        guard !SessionStorage.isWriterAlive(root: folder.deletingLastPathComponent()) else { throw TraceFailure.message("请停止录制并等待文件完成后再导出。") }
        let files = SessionStorage.files(in: folder)
        let total = SessionStorage.bytes(in: folder)
        guard total < Int64(UInt32.max) - 1_000_000, files.count < Int(UInt16.max) else { throw TraceFailure.message("Session 超出 ZIP32 的 4GB 限制，请分别导出文件。") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let free = SessionStorage.freeBytes(at: destination.deletingLastPathComponent()), free < total + 50_000_000 { throw TraceFailure.message("可用空间不足以生成 ZIP，请分别导出文件。") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw TraceFailure.message("ZIP_CREATE_FAILED") }
        let output = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer { try? output.close(); if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        var entries: [Entry] = []
        for file in files {
            let name = Data((folder.lastPathComponent + "/" + file.lastPathComponent).utf8)
            let offset = try output.offset()
            let expectedSize = UInt64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard offset < UInt32.max, expectedSize < UInt32.max, name.count < Int(UInt16.max) else { throw TraceFailure.message("ZIP32_LIMIT") }
            var header = Data()
            header.le(UInt32(0x04034b50)); header.le(UInt16(20)); header.le(UInt16(0x0808))
            header.le(UInt16(0)); header.le(UInt16(0)); header.le(UInt16(0x21))
            header.le(UInt32(0)); header.le(UInt32(0)); header.le(UInt32(0)); header.le(UInt16(name.count)); header.le(UInt16(0)); header.append(name)
            try output.write(contentsOf: header)
            let input = try FileHandle(forReadingFrom: file)
            var crc = UInt32.max, size: UInt64 = 0
            do {
                while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                    size += UInt64(chunk.count)
                    guard size <= expectedSize else { throw TraceFailure.message("FILE_CHANGED_DURING_EXPORT") }
                    for byte in chunk { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
                    try output.write(contentsOf: chunk)
                }
                try input.close()
            } catch { try? input.close(); throw error }
            guard size == expectedSize else { throw TraceFailure.message("FILE_CHANGED_DURING_EXPORT") }
            crc ^= UInt32.max
            var descriptor = Data(); descriptor.le(UInt32(0x08074b50)); descriptor.le(crc); descriptor.le(UInt32(size)); descriptor.le(UInt32(size))
            try output.write(contentsOf: descriptor)
            entries.append(Entry(name: name, crc: crc, size: UInt32(size), offset: UInt32(offset)))
        }
        let centralStart = try output.offset()
        for entry in entries {
            var central = Data()
            central.le(UInt32(0x02014b50)); central.le(UInt16(20)); central.le(UInt16(20)); central.le(UInt16(0x0808)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt16(0x21)); central.le(entry.crc); central.le(entry.size); central.le(entry.size)
            central.le(UInt16(entry.name.count)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0)); central.le(entry.offset); central.append(entry.name)
            try output.write(contentsOf: central)
        }
        let centralSize = try output.offset() - centralStart
        var end = Data(); end.le(UInt32(0x06054b50)); end.le(UInt16(0)); end.le(UInt16(0)); end.le(UInt16(entries.count)); end.le(UInt16(entries.count))
        end.le(UInt32(centralSize)); end.le(UInt32(centralStart)); end.le(UInt16(0))
        try output.write(contentsOf: end); try output.synchronize()
        succeeded = true
        return destination
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ number: T) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
