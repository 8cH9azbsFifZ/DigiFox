//
//  IOKitUSBSerial.m
//  JS8Call
//
//  IOKit-based USB Serial port access for iOS via dlopen.
//  Finds USB-CDC-ACM serial devices (e.g. CP2102 on Digirig Mobile)
//  and provides standard POSIX serial I/O with RTS/DTR control.
//

#import "IOKitUSBSerial.h"
#include <dlfcn.h>
#include <termios.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <mach/mach.h>

// --- IOKit type definitions (not in public iOS SDK) ---

typedef mach_port_t io_object_t;
typedef io_object_t io_iterator_t;
typedef io_object_t io_service_t;
typedef io_object_t io_registry_entry_t;

#define IO_OBJECT_NULL ((io_object_t)0)

// --- IOKit function pointer types ---

typedef CFMutableDictionaryRef (*IOServiceMatching_f)(const char *name);
typedef kern_return_t (*IOServiceGetMatchingServices_f)(mach_port_t mainPort,
                                                        CFDictionaryRef matching,
                                                        io_iterator_t *existing);
typedef io_object_t (*IOIteratorNext_f)(io_iterator_t iterator);
typedef kern_return_t (*IOObjectRelease_f)(io_object_t object);
typedef CFTypeRef (*IORegistryEntryCreateCFProperty_f)(io_registry_entry_t entry,
                                                       CFStringRef key,
                                                       CFAllocatorRef allocator,
                                                       uint32_t options);
typedef kern_return_t (*IORegistryEntryGetParentEntry_f)(io_registry_entry_t entry,
                                                         const char *plane,
                                                         io_registry_entry_t *parent);

// --- Static function pointers ---

static void *_iokit_handle = NULL;
static IOServiceMatching_f _IOServiceMatching = NULL;
static IOServiceGetMatchingServices_f _IOServiceGetMatchingServices = NULL;
static IOIteratorNext_f _IOIteratorNext = NULL;
static IOObjectRelease_f _IOObjectRelease = NULL;
static IORegistryEntryCreateCFProperty_f _IORegistryEntryCreateCFProperty = NULL;
static IORegistryEntryGetParentEntry_f _IORegistryEntryGetParentEntry = NULL;

static NSString * const kIOKitUSBSerialErrorDomain = @"IOKitUSBSerial";

// --- Helper: Load IOKit ---

static BOOL _loadIOKit(void) {
    static dispatch_once_t onceToken;
    static BOOL loaded = NO;
    dispatch_once(&onceToken, ^{
        _iokit_handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!_iokit_handle) return;

        _IOServiceMatching = dlsym(_iokit_handle, "IOServiceMatching");
        _IOServiceGetMatchingServices = dlsym(_iokit_handle, "IOServiceGetMatchingServices");
        _IOIteratorNext = dlsym(_iokit_handle, "IOIteratorNext");
        _IOObjectRelease = dlsym(_iokit_handle, "IOObjectRelease");
        _IORegistryEntryCreateCFProperty = dlsym(_iokit_handle, "IORegistryEntryCreateCFProperty");
        _IORegistryEntryGetParentEntry = dlsym(_iokit_handle, "IORegistryEntryGetParentEntry");

        loaded = (_IOServiceMatching && _IOServiceGetMatchingServices &&
                  _IOIteratorNext && _IOObjectRelease &&
                  _IORegistryEntryCreateCFProperty);
    });
    return loaded;
}

// --- Helper: Get string property from IORegistry ---

static NSString * _Nullable _getStringProperty(io_registry_entry_t entry, CFStringRef key) {
    if (!_IORegistryEntryCreateCFProperty) return nil;
    CFTypeRef value = _IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return nil;
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nil;
    }
    NSString *str = (__bridge_transfer NSString *)value;
    return str;
}

// --- Helper: Get integer property from IORegistry ---

static NSNumber * _Nullable _getIntProperty(io_registry_entry_t entry, CFStringRef key) {
    if (!_IORegistryEntryCreateCFProperty) return nil;
    CFTypeRef value = _IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return nil;
    if (CFGetTypeID(value) != CFNumberGetTypeID()) {
        CFRelease(value);
        return nil;
    }
    NSNumber *num = (__bridge_transfer NSNumber *)value;
    return num;
}

// --- Helper: Walk up IORegistry tree to find USB device properties ---

static void _getUSBDeviceInfo(io_registry_entry_t entry, uint16_t *vendorID, uint16_t *productID, NSString **name) {
    if (!_IORegistryEntryGetParentEntry) return;

    io_registry_entry_t parent = IO_OBJECT_NULL;
    io_registry_entry_t current = entry;

    // Walk up the IORegistry tree to find the USB device node
    for (int depth = 0; depth < 10; depth++) {
        kern_return_t kr = _IORegistryEntryGetParentEntry(current, "IOService", &parent);
        if (current != entry) _IOObjectRelease(current);
        if (kr != KERN_SUCCESS) break;

        NSNumber *vid = _getIntProperty(parent, CFSTR("idVendor"));
        NSNumber *pid = _getIntProperty(parent, CFSTR("idProduct"));
        if (vid && pid) {
            *vendorID = vid.unsignedShortValue;
            *productID = pid.unsignedShortValue;
            NSString *productName = _getStringProperty(parent, CFSTR("USB Product Name"));
            if (productName) *name = productName;
            _IOObjectRelease(parent);
            return;
        }
        current = parent;
    }
    if (parent != IO_OBJECT_NULL) _IOObjectRelease(parent);
}

// --- Helper: Convert baud rate to speed_t ---

static speed_t _baudRateToSpeed(NSUInteger baudRate) {
    switch (baudRate) {
        case 300:    return B300;
        case 1200:   return B1200;
        case 2400:   return B2400;
        case 4800:   return B4800;
        case 9600:   return B9600;
        case 19200:  return B19200;
        case 38400:  return B38400;
        case 57600:  return B57600;
        case 115200: return B115200;
        case 230400: return B230400;
        default:     return B9600;
    }
}

// ============================================================
#pragma mark - USBSerialDeviceInfo
// ============================================================

@implementation USBSerialDeviceInfo
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ path=%@ name=%@ VID=0x%04X PID=0x%04X>",
            NSStringFromClass(self.class), self.path, self.name, self.vendorID, self.productID];
}
@end

// ============================================================
#pragma mark - IOKitUSBSerial
// ============================================================

@implementation IOKitUSBSerial {
    int _fd;
    struct termios _originalTermios;
}

+ (BOOL)isAvailable {
    return _loadIOKit();
}

+ (NSArray<USBSerialDeviceInfo *> *)discoverDevices {
    NSMutableArray *devices = [NSMutableArray array];

    if (!_loadIOKit()) return devices;

    CFMutableDictionaryRef matching = _IOServiceMatching("IOSerialBSDClient");
    if (!matching) return devices;

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = _IOServiceGetMatchingServices(0, matching, &iterator);
    // matching is consumed by IOServiceGetMatchingServices
    if (kr != KERN_SUCCESS) return devices;

    io_service_t service;
    while ((service = _IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        NSString *path = _getStringProperty(service, CFSTR("IOCalloutDevice"));
        if (path) {
            USBSerialDeviceInfo *info = [[USBSerialDeviceInfo alloc] init];
            info.path = path;
            info.name = _getStringProperty(service, CFSTR("IOTTYBaseName")) ?: @"Unknown";

            uint16_t vid = 0, pid = 0;
            NSString *usbName = nil;
            _getUSBDeviceInfo(service, &vid, &pid, &usbName);
            info.vendorID = vid;
            info.productID = pid;
            if (usbName) info.name = usbName;

            [devices addObject:info];
        }
        _IOObjectRelease(service);
    }
    _IOObjectRelease(iterator);

    return devices;
}

- (nullable instancetype)initWithPath:(NSString *)path
                             baudRate:(NSUInteger)baudRate
                                error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _devicePath = [path copy];
    _baudRate = baudRate;
    _fd = -1;

    // Open the serial port
    _fd = open(path.UTF8String, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (_fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Cannot open %@: %s", path, strerror(errno)]}];
        }
        return nil;
    }

    // Get exclusive access
    if (ioctl(_fd, TIOCEXCL) < 0) {
        NSLog(@"IOKitUSBSerial: Warning — could not get exclusive access to %@", path);
    }

    // Clear O_NONBLOCK after open
    int flags = fcntl(_fd, F_GETFL);
    fcntl(_fd, F_SETFL, flags & ~O_NONBLOCK);

    // Save original termios and configure
    tcgetattr(_fd, &_originalTermios);

    struct termios options;
    tcgetattr(_fd, &options);

    // Raw mode
    cfmakeraw(&options);

    // Baud rate
    speed_t speed = _baudRateToSpeed(baudRate);
    cfsetispeed(&options, speed);
    cfsetospeed(&options, speed);

    // 8N1
    options.c_cflag &= ~(PARENB | CSTOPB | CSIZE);
    options.c_cflag |= (CS8 | CLOCAL | CREAD);

    // No flow control
    options.c_cflag &= ~CRTSCTS;
    options.c_iflag &= ~(IXON | IXOFF | IXANY);

    // Read timeout: 0.1s, minimum 0 bytes
    options.c_cc[VMIN] = 0;
    options.c_cc[VTIME] = 1;

    if (tcsetattr(_fd, TCSANOW, &options) < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Cannot configure %@: %s", path, strerror(errno)]}];
        }
        close(_fd);
        _fd = -1;
        return nil;
    }

    // Flush buffers
    tcflush(_fd, TCIOFLUSH);

    return self;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    if (_fd >= 0) {
        // Restore original termios
        tcsetattr(_fd, TCSANOW, &_originalTermios);
        close(_fd);
        _fd = -1;
    }
}

- (BOOL)isOpen {
    return _fd >= 0;
}

- (NSInteger)writeData:(NSData *)data error:(NSError **)error {
    if (_fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Port not open"}];
        }
        return -1;
    }

    ssize_t written = write(_fd, data.bytes, data.length);
    if (written < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Write error: %s", strerror(errno)]}];
        }
        return -1;
    }
    return written;
}

- (NSInteger)writeString:(NSString *)string error:(NSError **)error {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot encode string"}];
        }
        return -1;
    }
    return [self writeData:data error:error];
}

- (nullable NSData *)readDataWithMaxLength:(NSUInteger)maxLength error:(NSError **)error {
    if (_fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Port not open"}];
        }
        return nil;
    }

    uint8_t *buffer = malloc(maxLength);
    if (!buffer) return nil;

    ssize_t bytesRead = read(_fd, buffer, maxLength);
    if (bytesRead < 0) {
        free(buffer);
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Read error: %s", strerror(errno)]}];
        }
        return nil;
    }

    NSData *data = [NSData dataWithBytes:buffer length:bytesRead];
    free(buffer);
    return data;
}

- (nullable NSData *)readDataWithMaxLength:(NSUInteger)maxLength
                                   timeout:(NSTimeInterval)timeout
                                     error:(NSError **)error {
    if (_fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Port not open"}];
        }
        return nil;
    }

    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(_fd, &readSet);

    struct timeval tv;
    tv.tv_sec = (long)timeout;
    tv.tv_usec = (long)((timeout - (long)timeout) * 1000000);

    int result = select(_fd + 1, &readSet, NULL, NULL, &tv);
    if (result < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Select error: %s", strerror(errno)]}];
        }
        return nil;
    }
    if (result == 0) {
        // Timeout — return empty data
        return [NSData data];
    }

    return [self readDataWithMaxLength:maxLength error:error];
}

- (BOOL)setRTS:(BOOL)enabled error:(NSError **)error {
    if (_fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Port not open"}];
        }
        return NO;
    }

    int flag = TIOCM_RTS;
    int result = ioctl(_fd, enabled ? TIOCMBIS : TIOCMBIC, &flag);
    if (result < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Cannot set RTS: %s", strerror(errno)]}];
        }
        return NO;
    }
    return YES;
}

- (BOOL)setDTR:(BOOL)enabled error:(NSError **)error {
    if (_fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Port not open"}];
        }
        return NO;
    }

    int flag = TIOCM_DTR;
    int result = ioctl(_fd, enabled ? TIOCMBIS : TIOCMBIC, &flag);
    if (result < 0) {
        if (error) {
            *error = [NSError errorWithDomain:kIOKitUSBSerialErrorDomain
                                         code:errno
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"Cannot set DTR: %s", strerror(errno)]}];
        }
        return NO;
    }
    return YES;
}

@end
