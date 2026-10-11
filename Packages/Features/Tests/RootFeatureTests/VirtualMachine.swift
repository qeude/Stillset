import Darwin

/// Virtual Macs such as CI runners lack the Neural Engine for Vision text and decode video with different pixels.
let isVirtualMachine: Bool = {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}()
