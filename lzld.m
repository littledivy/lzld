#import <dlfcn.h>

extern void *kCAGravityTopLeft = 0;

// Metal
void *(*MTLCopyAllDevices_)(void) = 0;

void loadFramework() {
    // Load the Metal framework.
    void *handle = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY);
    if (handle) {
        // Assign the pointer to the MTLCopyAllDevices function.
        MTLCopyAllDevices_ = dlsym(handle, "MTLCopyAllDevices");
    }
}

extern void *MTLCopyAllDevices(void) {
    if (MTLCopyAllDevices_ == 0) {
        loadFramework();
    }

    return MTLCopyAllDevices_();
}

