#[link(kind = "framework", name = "CoreFoundation")]
#[link(kind = "framework", name = "CoreServices")]
#[link(kind = "framework", name = "QuartzCore")]
#[link(kind = "framework", name = "Metal")]
#[link(kind = "framework", name = "CoreGraphics")]
#[link(kind = "framework", name = "MetalPerformanceShaders")]
extern "C" {
    // Used
    fn MTLCopyAllDevices() -> *mut std::ffi::c_void;

    // Unused 
    #[allow(dead_code)]
    fn MTLCreateSystemDefaultDevice() -> *mut std::ffi::c_void;
}

fn main() {
    unsafe {
        let devices = MTLCopyAllDevices();
        println!("{:?}", devices);
    }
}
