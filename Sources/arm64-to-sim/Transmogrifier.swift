//
//  File.swift
//  
//
//  Created by Luo Sheng on 2021/12/3.
//

import Foundation
import MachO

struct Transmogrifier {
    private static func readBinary(atPath path: String) -> (Data, [Data], Data) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            fatalError("Cannot open a handle for the file at \(path). Aborting.")
        }
        
        // chop up the file into a relevant number of segments
        let headerData = try! handle.read(upToCount: MemoryLayout<mach_header_64>.stride)!
        
        let header: mach_header_64 = headerData.asStruct()
        if header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 {
            fatalError("The file is not a correct arm64 binary. Try thinning (via lipo) or unarchiving (via ar) first.")
        }
        
        let loadCommandsData: [Data] = (0..<header.ncmds).map { _ in
            let loadCommandPeekData = try! handle.peek(upToCount: MemoryLayout<load_command>.stride)
            return try! handle.read(upToCount: Int(loadCommandPeekData!.commandSize))!
        }
        
        let programData = try! handle.readToEnd()!
        
        try! handle.close()
        
        return (headerData, loadCommandsData, programData)
    }
    
    private static func updateSegment64(_ data: Data, _ offset: UInt32) -> Data {
        // decode both the segment_command_64 and the subsequent section_64s
        var segment: segment_command_64 = data.asStruct()
        
        let sections: [section_64] = (0..<Int(segment.nsects)).map { index in
            let offset = MemoryLayout<segment_command_64>.stride + index * MemoryLayout<section_64>.stride
            return data.asStruct(fromByteOffset: offset)
        }
        
        // shift segment information by the offset
        segment.fileoff += UInt64(offset)
        segment.filesize += UInt64(offset)
        segment.vmsize += UInt64(offset)
        
        let offsetSections = sections.map { section -> section_64 in
            var section = section
            section.offset += UInt32(offset)
            section.reloff += section.reloff > 0 ? UInt32(offset) : 0
            return section
        }
        
        var datas = [Data]()
        datas.append(Data(bytes: &segment, count: MemoryLayout<segment_command_64>.stride))
        datas.append(contentsOf: offsetSections.map { section in
            var section = section
            return Data(bytes: &section, count: MemoryLayout<section_64>.stride)
        })
        
        return datas.merge()
    }
    
    private static func updateVersionMin(_ data: Data, _ offset: UInt32, minos: UInt32, sdk: UInt32) -> Data {
        var command = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                            cmdsize: UInt32(MemoryLayout<build_version_command>.stride),
                                            platform: UInt32(PLATFORM_IOSSIMULATOR),
                                            minos: minos << 16 | 0 << 8 | 0,
                                            sdk: sdk << 16 | 0 << 8 | 0,
                                            ntools: 0)
        
        return Data(bytes: &command, count: MemoryLayout<build_version_command>.stride)
    }
    
    private static func updateDataInCode(_ data: Data, _ offset: UInt32) -> Data {
        var command: linkedit_data_command = data.asStruct()
        command.dataoff += offset
        return Data(bytes: &command, count: data.commandSize)
    }
    
    private static func updateSymTab(_ data: Data, _ offset: UInt32) -> Data {
        var command: symtab_command = data.asStruct()
        command.stroff += offset
        command.symoff += offset
        return Data(bytes: &command, count: data.commandSize)
    }
    
    static func processBinary(atPath path: String, minos: UInt32 = 13, sdk: UInt32 = 13) {
        let (headerData, loadCommandsData, programData) = readBinary(atPath: path)
        
        // `offset` is kind of a magic number here, since we know that's the only meaningful change to binary size
        // having a dynamic `offset` requires two passes over the load commands and is left as an exercise to the reader
        let offset = UInt32(abs(MemoryLayout<build_version_command>.stride - MemoryLayout<version_min_command>.stride))
        
        let editedCommandsData = loadCommandsData
            .map { (lc) -> Data in
                switch Int32(lc.loadCommand) {
                case LC_SEGMENT_64:
                    return updateSegment64(lc, offset)
                case LC_VERSION_MIN_IPHONEOS:
                    return updateVersionMin(lc, offset, minos: minos, sdk: sdk)
                case LC_DATA_IN_CODE, LC_LINKER_OPTIMIZATION_HINT:
                    return updateDataInCode(lc, offset)
                case LC_SYMTAB:
                    return updateSymTab(lc, offset)
                case LC_BUILD_VERSION:
                    print("This arm64 binary has already been patched.")
                    exit(0)
                default:
                    return lc
                }
            }
            .merge()
        
        var header: mach_header_64 = headerData.asStruct()
        header.sizeofcmds = UInt32(editedCommandsData.count)
        
        // reassemble the binary
        let reworkedData = [
            Data(bytes: &header, count: MemoryLayout<mach_header_64>.stride),
            editedCommandsData,
            programData
        ].merge()
        
        // save back to disk
        try! reworkedData.write(to: URL(fileURLWithPath: path))
    }
}
