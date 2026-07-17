// Sources/App/Export/DebugMemory.swift
// Tiny helper for the `-autoSave` debug verification hook (EditorView.swift):
// reads the process's current physical memory footprint via mach task_info,
// the same metric Instruments' Memory report uses, so the S4 peak-memory
// target (< 400MB during export) can be checked from a device/sim log line
// without attaching a profiler.
import Foundation

enum DebugMemory {
    /// Current `phys_footprint` in bytes, or 0 if the mach call fails.
    static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}
