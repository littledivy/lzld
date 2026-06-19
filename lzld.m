// lzld — lazy framework loader for macOS (aarch64).
//
// Apple's dyld no longer supports `ld -lazy_framework`: a linked framework is
// loaded at process launch even if no symbol from it is used. For a program
// like Deno that links CoreFoundation / Foundation / Security / CoreServices /
// Metal / QuartzCore / CoreGraphics / MetalPerformanceShaders / AVFoundation
// but touches them only in rarely-hit paths (fs.watch, keychain, WebGPU), that
// is pure startup cost — measured at ~0.43 ms of dyld load+init for the shared
// CoreFoundation/ObjC graph, paid on every `deno run`.
//
// The `lzld` linker wrapper strips those `-framework` / `-weak_framework` args
// and links this static lib instead. Each imported symbol is provided here as
// a thin shim that dlopen()s its framework on first use. Programs that never
// touch the frameworks never load them.
//
// Symbols below are exactly the set Deno imports from these frameworks (see
// `dyld_info -imports`). Regenerate when the import set changes:
//   dyld_info -imports <deno> | grep -E '\(from (CoreFoundation|...)\)'
//
// Mechanism notes:
//  - Functions: cache the resolved fn pointer, forward args. Cheap after first.
//  - Data constants can't be lazily resolved (the consumer reads the symbol's
//    value directly — there is no call to intercept). We instead populate the
//    real values inside the owning framework's ensure_*() (triggered by the
//    first *function* call into that framework, which in every real call site
//    happens before the constant is meaningfully used) and substitute them by
//    address/value at the use site. kCFAllocatorDefault == NULL is already the
//    documented "default allocator" sentinel, so it needs nothing.

#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreServices/CoreServices.h>
#import <Security/Security.h>

// Set LZLD_TRACE=1 to print a backtrace the first time each framework is forced
// to load. Used to find startup call sites that defeat lazy loading.
#import <execinfo.h>
#import <stdio.h>
#import <stdlib.h>
static void lzld_trace(const char *fw) {
  if (!getenv("LZLD_TRACE")) return;
  fprintf(stderr, "\n[lzld] loading %s — backtrace:\n", fw);
  void *bt[32];
  int n = backtrace(bt, 32);
  backtrace_symbols_fd(bt, n, 2);
}

// ---------------------------------------------------------------------------
// Lazy framework handles
// ---------------------------------------------------------------------------

static void *h_CF = 0;       // CoreFoundation
static void *h_CS = 0;       // CoreServices
static void *h_Sec = 0;      // Security
static void *h_MTL = 0;      // Metal

// Real values of the CoreFoundation data constants, resolved in ensure_CF().
static const CFArrayCallBacks *real_kCFTypeArrayCallBacks = 0;
static CFStringRef real_kCFRunLoopDefaultMode = 0;

static void ensure_CF(void) {
  if (h_CF) return;
  lzld_trace("CoreFoundation"); h_CF = dlopen(
      "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
      RTLD_LAZY | RTLD_GLOBAL);
  if (h_CF) {
    real_kCFTypeArrayCallBacks =
        (const CFArrayCallBacks *)dlsym(h_CF, "kCFTypeArrayCallBacks");
    CFStringRef *mode = (CFStringRef *)dlsym(h_CF, "kCFRunLoopDefaultMode");
    if (mode) real_kCFRunLoopDefaultMode = *mode;
  }
}

static void ensure_CS(void) {
  if (h_CS) return;
  ensure_CF();  // CoreServices/FSEvents schedule against the CF run loop mode.
  lzld_trace("CoreServices"); h_CS = dlopen(
      "/System/Library/Frameworks/CoreServices.framework/CoreServices",
      RTLD_LAZY | RTLD_GLOBAL);
}

static void ensure_Sec(void) {
  if (h_Sec) return;
  ensure_CF();
  lzld_trace("Security"); h_Sec = dlopen("/System/Library/Frameworks/Security.framework/Security",
                 RTLD_LAZY | RTLD_GLOBAL);
}

static void ensure_MTL(void) {
  if (h_MTL) return;
  lzld_trace("Metal"); h_MTL = dlopen("/System/Library/Frameworks/Metal.framework/Metal",
                 RTLD_LAZY | RTLD_GLOBAL);
}

#define SYM(h, name) dlsym((h), (name))

// ---------------------------------------------------------------------------
// CoreFoundation data constants
// ---------------------------------------------------------------------------

// NULL is the documented "use the default allocator" sentinel — correct as-is.
const CFAllocatorRef kCFAllocatorDefault = NULL;

// We never read these directly; they are sentinels detected and substituted at
// the use site (see CFArrayCreate*, FSEventStreamScheduleWithRunLoop). Defined
// here only to satisfy the linker. kCFTypeArrayCallBacks is compared by address
// so its contents are irrelevant.
const CFArrayCallBacks kCFTypeArrayCallBacks = {0};
const CFStringRef kCFRunLoopDefaultMode = NULL;

// ---------------------------------------------------------------------------
// CoreFoundation functions
// ---------------------------------------------------------------------------

void CFArrayAppendValue(CFMutableArrayRef a, const void *v) {
  static void (*p)(CFMutableArrayRef, const void *);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFArrayAppendValue"); }
  p(a, v);
}

CFArrayRef CFArrayCreate(CFAllocatorRef allocator, const void **values,
                         CFIndex numValues, const CFArrayCallBacks *callBacks) {
  static CFArrayRef (*p)(CFAllocatorRef, const void **, CFIndex,
                         const CFArrayCallBacks *);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFArrayCreate"); }
  if (callBacks == &kCFTypeArrayCallBacks) callBacks = real_kCFTypeArrayCallBacks;
  return p(allocator, values, numValues, callBacks);
}

CFMutableArrayRef CFArrayCreateMutable(CFAllocatorRef allocator, CFIndex cap,
                                       const CFArrayCallBacks *callBacks) {
  static CFMutableArrayRef (*p)(CFAllocatorRef, CFIndex,
                                const CFArrayCallBacks *);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFArrayCreateMutable"); }
  if (callBacks == &kCFTypeArrayCallBacks) callBacks = real_kCFTypeArrayCallBacks;
  return p(allocator, cap, callBacks);
}

CFIndex CFArrayGetCount(CFArrayRef a) {
  static CFIndex (*p)(CFArrayRef);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFArrayGetCount"); }
  return p(a);
}

const void *CFArrayGetValueAtIndex(CFArrayRef a, CFIndex idx) {
  static const void *(*p)(CFArrayRef, CFIndex);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFArrayGetValueAtIndex"); }
  return p(a, idx);
}

void CFArrayInsertValueAtIndex(CFMutableArrayRef a, CFIndex idx,
                               const void *v) {
  static void (*p)(CFMutableArrayRef, CFIndex, const void *);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFArrayInsertValueAtIndex"); }
  p(a, idx, v);
}

void CFArrayRemoveValueAtIndex(CFMutableArrayRef a, CFIndex idx) {
  static void (*p)(CFMutableArrayRef, CFIndex);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFArrayRemoveValueAtIndex"); }
  p(a, idx);
}

void CFRelease(CFTypeRef cf) {
  static void (*p)(CFTypeRef);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFRelease"); }
  p(cf);
}

CFTypeRef CFRetain(CFTypeRef cf) {
  static CFTypeRef (*p)(CFTypeRef);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFRetain"); }
  return p(cf);
}

CFRunLoopRef CFRunLoopGetCurrent(void) {
  static CFRunLoopRef (*p)(void);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFRunLoopGetCurrent"); }
  return p();
}

Boolean CFRunLoopIsWaiting(CFRunLoopRef rl) {
  static Boolean (*p)(CFRunLoopRef);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFRunLoopIsWaiting"); }
  return p(rl);
}

void CFRunLoopRun(void) {
  static void (*p)(void);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFRunLoopRun"); }
  p();
}

void CFRunLoopStop(CFRunLoopRef rl) {
  static void (*p)(CFRunLoopRef);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFRunLoopStop"); }
  p(rl);
}

CFComparisonResult CFStringCompare(CFStringRef a, CFStringRef b,
                                   CFStringCompareFlags opts) {
  static CFComparisonResult (*p)(CFStringRef, CFStringRef,
                                 CFStringCompareFlags);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFStringCompare"); }
  return p(a, b, opts);
}

CFIndex CFStringGetBytes(CFStringRef s, CFRange range, CFStringEncoding enc,
                         UInt8 lossByte, Boolean isExternal, UInt8 *buffer,
                         CFIndex maxBufLen, CFIndex *usedBufLen) {
  static CFIndex (*p)(CFStringRef, CFRange, CFStringEncoding, UInt8, Boolean,
                      UInt8 *, CFIndex, CFIndex *);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFStringGetBytes"); }
  return p(s, range, enc, lossByte, isExternal, buffer, maxBufLen, usedBufLen);
}

const char *CFStringGetCStringPtr(CFStringRef s, CFStringEncoding enc) {
  static const char *(*p)(CFStringRef, CFStringEncoding);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFStringGetCStringPtr"); }
  return p(s, enc);
}

CFIndex CFStringGetLength(CFStringRef s) {
  static CFIndex (*p)(CFStringRef);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFStringGetLength"); }
  return p(s);
}

CFURLRef CFURLCopyAbsoluteURL(CFURLRef u) {
  static CFURLRef (*p)(CFURLRef);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFURLCopyAbsoluteURL"); }
  return p(u);
}

CFStringRef CFURLCopyFileSystemPath(CFURLRef u, CFURLPathStyle style) {
  static CFStringRef (*p)(CFURLRef, CFURLPathStyle);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFURLCopyFileSystemPath"); }
  return p(u, style);
}

CFStringRef CFURLCopyLastPathComponent(CFURLRef u) {
  static CFStringRef (*p)(CFURLRef);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFURLCopyLastPathComponent"); }
  return p(u);
}

CFURLRef CFURLCreateCopyAppendingPathComponent(CFAllocatorRef a, CFURLRef u,
                                               CFStringRef comp,
                                               Boolean isDir) {
  static CFURLRef (*p)(CFAllocatorRef, CFURLRef, CFStringRef, Boolean);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFURLCreateCopyAppendingPathComponent"); }
  return p(a, u, comp, isDir);
}

CFURLRef CFURLCreateCopyDeletingLastPathComponent(CFAllocatorRef a,
                                                  CFURLRef u) {
  static CFURLRef (*p)(CFAllocatorRef, CFURLRef);
  if (!p) {
    ensure_CF();
    p = SYM(h_CF, "CFURLCreateCopyDeletingLastPathComponent");
  }
  return p(a, u);
}

CFURLRef CFURLCreateFilePathURL(CFAllocatorRef a, CFURLRef u, CFErrorRef *err) {
  static CFURLRef (*p)(CFAllocatorRef, CFURLRef, CFErrorRef *);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFURLCreateFilePathURL"); }
  return p(a, u, err);
}

CFURLRef CFURLCreateFileReferenceURL(CFAllocatorRef a, CFURLRef u,
                                     CFErrorRef *err) {
  static CFURLRef (*p)(CFAllocatorRef, CFURLRef, CFErrorRef *);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFURLCreateFileReferenceURL"); }
  return p(a, u, err);
}

CFURLRef CFURLCreateFromFileSystemRepresentation(CFAllocatorRef a,
                                                 const UInt8 *buffer,
                                                 CFIndex bufLen,
                                                 Boolean isDir) {
  static CFURLRef (*p)(CFAllocatorRef, const UInt8 *, CFIndex, Boolean);
  if (!p) {
    ensure_CF();
    p = SYM(h_CF, "CFURLCreateFromFileSystemRepresentation");
  }
  return p(a, buffer, bufLen, isDir);
}

Boolean CFURLResourceIsReachable(CFURLRef u, CFErrorRef *err) {
  static Boolean (*p)(CFURLRef, CFErrorRef *);
  if (!p) { ensure_CF(); p = SYM(h_CF, "CFURLResourceIsReachable"); }
  return p(u, err);
}

// ---------------------------------------------------------------------------
// CoreServices — FSEvents
// ---------------------------------------------------------------------------

FSEventStreamRef FSEventStreamCreate(CFAllocatorRef allocator,
                                     FSEventStreamCallback callback,
                                     FSEventStreamContext *context,
                                     CFArrayRef pathsToWatch,
                                     FSEventStreamEventId sinceWhen,
                                     CFTimeInterval latency,
                                     FSEventStreamCreateFlags flags) {
  static FSEventStreamRef (*p)(CFAllocatorRef, FSEventStreamCallback,
                               FSEventStreamContext *, CFArrayRef,
                               FSEventStreamEventId, CFTimeInterval,
                               FSEventStreamCreateFlags);
  if (!p) { ensure_CS(); p = SYM(h_CS, "FSEventStreamCreate"); }
  return p(allocator, callback, context, pathsToWatch, sinceWhen, latency,
           flags);
}

dev_t FSEventStreamGetDeviceBeingWatched(ConstFSEventStreamRef s) {
  static dev_t (*p)(ConstFSEventStreamRef);
  if (!p) { ensure_CS(); p = SYM(h_CS, "FSEventStreamGetDeviceBeingWatched"); }
  return p(s);
}

void FSEventStreamInvalidate(FSEventStreamRef s) {
  static void (*p)(FSEventStreamRef);
  if (!p) { ensure_CS(); p = SYM(h_CS, "FSEventStreamInvalidate"); }
  p(s);
}

void FSEventStreamRelease(FSEventStreamRef s) {
  static void (*p)(FSEventStreamRef);
  if (!p) { ensure_CS(); p = SYM(h_CS, "FSEventStreamRelease"); }
  p(s);
}

void FSEventStreamScheduleWithRunLoop(FSEventStreamRef s, CFRunLoopRef runLoop,
                                      CFStringRef runLoopMode) {
  static void (*p)(FSEventStreamRef, CFRunLoopRef, CFStringRef);
  if (!p) { ensure_CS(); p = SYM(h_CS, "FSEventStreamScheduleWithRunLoop"); }
  // The caller passes our kCFRunLoopDefaultMode sentinel (NULL); swap in the
  // real CFRunLoopMode now that CoreFoundation is loaded.
  if (runLoopMode == kCFRunLoopDefaultMode) runLoopMode = real_kCFRunLoopDefaultMode;
  p(s, runLoop, runLoopMode);
}

Boolean FSEventStreamStart(FSEventStreamRef s) {
  static Boolean (*p)(FSEventStreamRef);
  if (!p) { ensure_CS(); p = SYM(h_CS, "FSEventStreamStart"); }
  return p(s);
}

void FSEventStreamStop(FSEventStreamRef s) {
  static void (*p)(FSEventStreamRef);
  if (!p) { ensure_CS(); p = SYM(h_CS, "FSEventStreamStop"); }
  p(s);
}

FSEventStreamEventId FSEventsGetCurrentEventId(void) {
  static FSEventStreamEventId (*p)(void);
  if (!p) { ensure_CS(); p = SYM(h_CS, "FSEventsGetCurrentEventId"); }
  return p();
}

Boolean FSEventsPurgeEventsForDeviceUpToEventId(dev_t dev,
                                                FSEventStreamEventId eventId) {
  static Boolean (*p)(dev_t, FSEventStreamEventId);
  if (!p) {
    ensure_CS();
    p = SYM(h_CS, "FSEventsPurgeEventsForDeviceUpToEventId");
  }
  return p(dev, eventId);
}

// ---------------------------------------------------------------------------
// Security — Keychain
// ---------------------------------------------------------------------------

CFStringRef SecCopyErrorMessageString(OSStatus status, void *reserved) {
  static CFStringRef (*p)(OSStatus, void *);
  if (!p) { ensure_Sec(); p = SYM(h_Sec, "SecCopyErrorMessageString"); }
  return p(status, reserved);
}

OSStatus SecKeychainAddGenericPassword(
    SecKeychainRef keychain, UInt32 serviceNameLength, const char *serviceName,
    UInt32 accountNameLength, const char *accountName, UInt32 passwordLength,
    const void *passwordData, SecKeychainItemRef *itemRef) {
  static OSStatus (*p)(SecKeychainRef, UInt32, const char *, UInt32,
                       const char *, UInt32, const void *, SecKeychainItemRef *);
  if (!p) { ensure_Sec(); p = SYM(h_Sec, "SecKeychainAddGenericPassword"); }
  return p(keychain, serviceNameLength, serviceName, accountNameLength,
           accountName, passwordLength, passwordData, itemRef);
}

OSStatus SecKeychainCopyDomainDefault(SecPreferencesDomain domain,
                                      SecKeychainRef *keychain) {
  static OSStatus (*p)(SecPreferencesDomain, SecKeychainRef *);
  if (!p) { ensure_Sec(); p = SYM(h_Sec, "SecKeychainCopyDomainDefault"); }
  return p(domain, keychain);
}

OSStatus SecKeychainFindGenericPassword(
    CFTypeRef keychainOrArray, UInt32 serviceNameLength,
    const char *serviceName, UInt32 accountNameLength, const char *accountName,
    UInt32 *passwordLength, void **passwordData, SecKeychainItemRef *itemRef) {
  static OSStatus (*p)(CFTypeRef, UInt32, const char *, UInt32, const char *,
                       UInt32 *, void **, SecKeychainItemRef *);
  if (!p) { ensure_Sec(); p = SYM(h_Sec, "SecKeychainFindGenericPassword"); }
  return p(keychainOrArray, serviceNameLength, serviceName, accountNameLength,
           accountName, passwordLength, passwordData, itemRef);
}

OSStatus SecKeychainItemDelete(SecKeychainItemRef itemRef) {
  static OSStatus (*p)(SecKeychainItemRef);
  if (!p) { ensure_Sec(); p = SYM(h_Sec, "SecKeychainItemDelete"); }
  return p(itemRef);
}

OSStatus SecKeychainItemFreeContent(SecKeychainAttributeList *attrList,
                                    void *data) {
  static OSStatus (*p)(SecKeychainAttributeList *, void *);
  if (!p) { ensure_Sec(); p = SYM(h_Sec, "SecKeychainItemFreeContent"); }
  return p(attrList, data);
}

OSStatus SecKeychainItemModifyAttributesAndData(
    SecKeychainItemRef itemRef, const SecKeychainAttributeList *attrList,
    UInt32 length, const void *data) {
  static OSStatus (*p)(SecKeychainItemRef, const SecKeychainAttributeList *,
                       UInt32, const void *);
  if (!p) {
    ensure_Sec();
    p = SYM(h_Sec, "SecKeychainItemModifyAttributesAndData");
  }
  return p(itemRef, attrList, length, data);
}

// ---------------------------------------------------------------------------
// Foundation — single data constant, KVO. Only reached via AppKit/window
// observation (never in headless Deno). nil is a safe stub: a KVO change
// dictionary lookup with a nil key returns nil.
// ---------------------------------------------------------------------------

void *const NSKeyValueChangeNewKey = NULL;

// ---------------------------------------------------------------------------
// Metal — device enumeration only.
// ---------------------------------------------------------------------------

void *MTLCopyAllDevices(void) {
  static void *(*p)(void);
  if (!p) { ensure_MTL(); p = SYM(h_MTL, "MTLCopyAllDevices"); }
  return p();
}
