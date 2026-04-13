//
//  CP2102USBDriver.m
//  DigiFox
//
//  Direct USB communication with Silicon Labs CP2102 on real iOS devices.
//  Uses public IOKit APIs: IOServiceMatching, IOServiceOpen, IOConnectCallMethod.
//
//  CP2102 vendor protocol reference:
//    - Silicon Labs AN571 (CP210x Virtual COM Port Interface)
//    - Linux kernel drivers/usb/serial/cp210x.c
//

#import "CP2102USBDriver.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/IOTypes.h>
#import <IOKit/IOReturn.h>
#import <mach/mach.h>

// ============================================================
#pragma mark - CP2102 Vendor Protocol Constants
// ============================================================

// CP2102 Vendor-specific request codes (bmRequestType = 0x41 OUT, 0xC1 IN)
enum {
    CP210X_IFC_ENABLE     = 0x00,  // Enable/disable UART interface
    CP210X_SET_BAUDDIV    = 0x01,  // Set baud rate divisor
    CP210X_GET_BAUDDIV    = 0x02,
    CP210X_SET_LINE_CTL   = 0x03,  // Set data format (bits/parity/stop)
    CP210X_GET_LINE_CTL   = 0x04,
    CP210X_SET_BREAK      = 0x05,
    CP210X_IMM_CHAR       = 0x06,
    CP210X_SET_MHS        = 0x07,  // Set modem handshake (RTS/DTR)
    CP210X_GET_MDMSTS     = 0x08,  // Get modem status
    CP210X_SET_XON        = 0x09,
    CP210X_SET_XOFF       = 0x0A,
    CP210X_SET_EVENTMASK  = 0x0B,
    CP210X_GET_EVENTMASK  = 0x0C,
    CP210X_SET_CHAR       = 0x0D,
    CP210X_GET_CHARS      = 0x0E,
    CP210X_GET_PROPS      = 0x0F,
    CP210X_GET_COMM_STATUS = 0x10,
    CP210X_RESET          = 0x11,
    CP210X_PURGE          = 0x12,
    CP210X_SET_FLOW       = 0x13,
    CP210X_GET_FLOW       = 0x14,
    CP210X_EMBED_EVENTS   = 0x15,
    CP210X_GET_EVENTSTATE = 0x16,
    CP210X_SET_BAUDRATE   = 0x1E,  // Set baud rate directly (4 bytes LE)
    CP210X_GET_BAUDRATE   = 0x1F,
};

// IFC_ENABLE values
enum {
    CP210X_UART_ENABLE  = 0x0001,
    CP210X_UART_DISABLE = 0x0000,
};

// SET_LINE_CTL: data bits (high byte), parity (bits 7-4), stop bits (bits 3-0)
enum {
    CP210X_LINE_CTL_8N1 = 0x0800,  // 8 data bits, no parity, 1 stop bit
};

// SET_MHS bit masks
enum {
    CP210X_MHS_DTR_STATE = 0x0001,  // DTR line state
    CP210X_MHS_RTS_STATE = 0x0002,  // RTS line state
    CP210X_MHS_DTR_MASK  = 0x0100,  // Update DTR
    CP210X_MHS_RTS_MASK  = 0x0200,  // Update RTS
};

// PURGE masks
enum {
    CP210X_PURGE_TX = 0x0001,
    CP210X_PURGE_RX = 0x0002,
    CP210X_PURGE_ALL = 0x000F,
};

// USB identification
static const uint16_t CP2102_VENDOR_ID  = 0x10C4;  // Silicon Labs
static const uint16_t CP2102_PRODUCT_ID = 0xEA60;  // CP2102/CP2102N

// IOKit USB class names (for matching)
static NSString * const kUSBHostDeviceClass     = @"IOUSBHostDevice";
static NSString * const kUSBHostInterfaceClass  = @"IOUSBHostInterface";
static NSString * const kAppleUSBDeviceClass    = @"AppleUSBHostDevice";

// IOUSBHostInterface user client selectors
// Ref: IOUSBHostFamily open source / kernel headers
enum {
    kUSBHostInterfaceMethodIO               = 0,
    kUSBHostInterfaceMethodIOAsync           = 1,
    kUSBHostInterfaceMethodAbort             = 2,
    kUSBHostInterfaceMethodCopyDescriptor    = 3,
    kUSBHostInterfaceMethodDeviceRequest     = 4,
    kUSBHostInterfaceMethodDeviceRequestAsync = 5,
};

// IOUSBHostDevice user client selectors
enum {
    kUSBHostDeviceMethodDeviceRequest       = 0,
    kUSBHostDeviceMethodDeviceRequestAsync  = 1,
    kUSBHostDeviceMethodAbort               = 2,
    kUSBHostDeviceMethodCopyDescriptor      = 3,
};

// USB request type constants
enum {
    kUSBRequestTypeVendorOut = 0x41,  // Host→Device, Vendor, Interface
    kUSBRequestTypeVendorIn  = 0xC1,  // Device→Host, Vendor, Interface
};

static NSString * const kCP2102ErrorDomain = @"CP2102USBDriver";

// ============================================================
#pragma mark - CP2102USBDriver Private
// ============================================================

@interface CP2102USBDriver () {
    io_service_t         _deviceService;
    io_service_t         _interfaceService;
    io_connect_t         _deviceConnection;
    io_connect_t         _interfaceConnection;
    io_iterator_t        _addedIterator;
    io_iterator_t        _removedIterator;
    IONotificationPortRef _notificationPort;
    NSUInteger           _baudRate;
    uint8_t              _bulkInPipe;
    uint8_t              _bulkOutPipe;
    BOOL                 _deviceOpen;
    dispatch_queue_t     _ioQueue;
}
@end

@implementation CP2102USBDriver

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = CP2102StateDisconnected;
        _deviceService = IO_OBJECT_NULL;
        _interfaceService = IO_OBJECT_NULL;
        _deviceConnection = IO_OBJECT_NULL;
        _interfaceConnection = IO_OBJECT_NULL;
        _addedIterator = IO_OBJECT_NULL;
        _removedIterator = IO_OBJECT_NULL;
        _notificationPort = NULL;
        _baudRate = 9600;
        _bulkInPipe = 1;   // CP2102 standard: EP1 IN
        _bulkOutPipe = 1;  // CP2102 standard: EP1 OUT
        _deviceOpen = NO;
        _ioQueue = dispatch_queue_create("cp2102.io", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self close];
    [self stopMonitoring];
}

// ============================================================
#pragma mark - Device Discovery
// ============================================================

+ (BOOL)isAvailable {
    // IOKit is now public on iOS — check if the basic function works
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (!matching) {
        // Fallback: try AppleUSBHostDevice
        matching = IOServiceMatching("AppleUSBHostDevice");
    }
    if (!matching) return NO;

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr == KERN_SUCCESS && iterator != IO_OBJECT_NULL) {
        IOObjectRelease(iterator);
        return YES;
    }
    
    // Even if no USB devices are found, IOKit is still available if the call succeeded
    return (kr == KERN_SUCCESS);
}

+ (NSArray<NSDictionary *> *)discoverDevices {
    NSMutableArray *result = [NSMutableArray array];

    // Try both class names — different iOS versions use different names
    NSArray *classNames = @[@"IOUSBHostDevice", @"AppleUSBHostDevice"];

    for (NSString *className in classNames) {
        CFMutableDictionaryRef matching = IOServiceMatching(className.UTF8String);
        if (!matching) continue;

        io_iterator_t iterator = IO_OBJECT_NULL;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
        if (kr != KERN_SUCCESS) continue;

        io_service_t service;
        while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            // Get VID/PID from this device node
            uint16_t vid = [self _getUInt16Property:service key:CFSTR("idVendor")];
            uint16_t pid = [self _getUInt16Property:service key:CFSTR("idProduct")];

            // Only report devices we can handle (CP2102 / CH340)
            if (vid == 0x10C4 || vid == 0x1A86) {
                NSString *name = [self _getStringProperty:service key:CFSTR("USB Product Name")]
                              ?: [self _getStringProperty:service key:CFSTR("kUSBProductString")]
                              ?: @"USB Serial Device";

                NSString *path = [NSString stringWithFormat:@"usb:%04x:%04x", vid, pid];

                // Check if this VID/PID combo is already in results (from different class name)
                BOOL duplicate = NO;
                for (NSDictionary *existing in result) {
                    if ([existing[@"vendorID"] unsignedShortValue] == vid &&
                        [existing[@"productID"] unsignedShortValue] == pid) {
                        duplicate = YES;
                        break;
                    }
                }

                if (!duplicate) {
                    [result addObject:@{
                        @"path": path,
                        @"name": name,
                        @"vendorID": @(vid),
                        @"productID": @(pid),
                    }];
                    NSLog(@"CP2102USBDriver: Found device: %@ VID=0x%04X PID=0x%04X", name, vid, pid);
                }
            }

            IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
    }

    return result;
}

// ============================================================
#pragma mark - Open / Close
// ============================================================

- (BOOL)openWithVendorID:(uint16_t)vendorID
               productID:(uint16_t)productID
                baudRate:(NSUInteger)baudRate
                   error:(NSError **)error {
    if (_deviceOpen) {
        [self close];
    }

    _state = CP2102StateConnecting;
    _baudRate = baudRate;

    // Step 1: Find the USB device by VID/PID
    io_service_t deviceService = [self _findUSBDeviceWithVID:vendorID PID:productID];
    if (deviceService == IO_OBJECT_NULL) {
        [self _setError:error code:-1 message:
         [NSString stringWithFormat:@"USB device not found (VID=0x%04X PID=0x%04X)", vendorID, productID]];
        _state = CP2102StateError;
        return NO;
    }
    _deviceService = deviceService;

    // Step 2: Find the first USB interface child
    io_service_t interfaceService = [self _findFirstInterface:deviceService];
    if (interfaceService == IO_OBJECT_NULL) {
        // Fallback: try opening the device directly
        NSLog(@"CP2102USBDriver: No interface child found, trying device directly");
        interfaceService = deviceService;
        IOObjectRetain(interfaceService);
    }
    _interfaceService = interfaceService;

    // Step 3: Open user client on the device
    kern_return_t kr = IOServiceOpen(_deviceService, mach_task_self(), 0, &_deviceConnection);
    if (kr != KERN_SUCCESS) {
        NSLog(@"CP2102USBDriver: IOServiceOpen(device) failed: 0x%x", kr);
        // Try the interface instead
        _deviceConnection = IO_OBJECT_NULL;
    }

    // Step 4: Open user client on the interface
    kr = IOServiceOpen(_interfaceService, mach_task_self(), 0, &_interfaceConnection);
    if (kr != KERN_SUCCESS) {
        NSLog(@"CP2102USBDriver: IOServiceOpen(interface) failed: 0x%x", kr);
        _interfaceConnection = IO_OBJECT_NULL;

        // If both device and interface connections failed, give up
        if (_deviceConnection == IO_OBJECT_NULL) {
            [self _setError:error code:kr message:
             [NSString stringWithFormat:@"Cannot open USB user client (0x%x). "
              "Ensure the app has USB access entitlements.", kr]];
            _state = CP2102StateError;
            [self _cleanup];
            return NO;
        }
    }

    // Pick the best connection for control transfers
    io_connect_t controlConnection = _deviceConnection ?: _interfaceConnection;

    // Step 5: Configure CP2102 via vendor control transfers
    if (![self _enableUART:YES connection:controlConnection error:error]) {
        [self _cleanup];
        return NO;
    }

    if (![self _setBaudRate:baudRate connection:controlConnection error:error]) {
        [self _cleanup];
        return NO;
    }

    if (![self _setLineControl:CP210X_LINE_CTL_8N1 connection:controlConnection error:error]) {
        [self _cleanup];
        return NO;
    }

    if (![self _setFlowControl:controlConnection error:error]) {
        [self _cleanup];
        return NO;
    }

    if (![self _purge:CP210X_PURGE_ALL connection:controlConnection error:error]) {
        // Non-fatal: some devices don't support purge
        NSLog(@"CP2102USBDriver: Purge warning (non-fatal)");
    }

    _deviceOpen = YES;
    _state = CP2102StateConnected;
    NSLog(@"CP2102USBDriver: Connected at %lu baud", (unsigned long)baudRate);

    return YES;
}

- (BOOL)openDigirigWithBaudRate:(NSUInteger)baudRate error:(NSError **)error {
    return [self openWithVendorID:CP2102_VENDOR_ID
                        productID:CP2102_PRODUCT_ID
                         baudRate:baudRate
                            error:error];
}

- (void)close {
    if (!_deviceOpen && _state == CP2102StateDisconnected) return;

    NSLog(@"CP2102USBDriver: Closing connection");

    // Disable UART
    io_connect_t conn = _deviceConnection ?: _interfaceConnection;
    if (conn != IO_OBJECT_NULL) {
        [self _enableUART:NO connection:conn error:nil];
    }

    [self _cleanup];

    _deviceOpen = NO;
    _state = CP2102StateDisconnected;
}

- (void)_cleanup {
    if (_interfaceConnection != IO_OBJECT_NULL) {
        IOServiceClose(_interfaceConnection);
        _interfaceConnection = IO_OBJECT_NULL;
    }
    if (_deviceConnection != IO_OBJECT_NULL) {
        IOServiceClose(_deviceConnection);
        _deviceConnection = IO_OBJECT_NULL;
    }
    if (_interfaceService != IO_OBJECT_NULL) {
        IOObjectRelease(_interfaceService);
        _interfaceService = IO_OBJECT_NULL;
    }
    if (_deviceService != IO_OBJECT_NULL) {
        IOObjectRelease(_deviceService);
        _deviceService = IO_OBJECT_NULL;
    }
}

// ============================================================
#pragma mark - Data I/O
// ============================================================

- (NSInteger)writeData:(NSData *)data error:(NSError **)error {
    if (!_deviceOpen) {
        [self _setError:error code:-1 message:@"Device not open"];
        return -1;
    }

    io_connect_t conn = _interfaceConnection ?: _deviceConnection;
    if (conn == IO_OBJECT_NULL) {
        [self _setError:error code:-1 message:@"No valid connection"];
        return -1;
    }

    // Bulk OUT transfer via user client
    // Selector 0 = IO method for interface user client
    uint64_t scalarInput[2];
    scalarInput[0] = _bulkOutPipe;  // pipe/endpoint reference
    scalarInput[1] = 0;             // completion timeout (0 = default)

    kern_return_t kr = IOConnectCallStructMethod(
        conn,
        kUSBHostInterfaceMethodIO,
        data.bytes, data.length,
        NULL, NULL
    );

    if (kr != KERN_SUCCESS) {
        // Fallback: try device request method (some implementations differ)
        kr = IOConnectCallMethod(
            conn,
            kUSBHostInterfaceMethodIO,
            scalarInput, 2,
            data.bytes, data.length,
            NULL, NULL,
            NULL, NULL
        );
    }

    if (kr != KERN_SUCCESS) {
        [self _setError:error code:kr
               message:[NSString stringWithFormat:@"Bulk write failed (0x%x)", kr]];
        return -1;
    }

    return data.length;
}

- (NSInteger)writeString:(NSString *)string error:(NSError **)error {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        [self _setError:error code:-1 message:@"Cannot encode string as UTF-8"];
        return -1;
    }
    return [self writeData:data error:error];
}

- (nullable NSData *)readDataWithMaxLength:(NSUInteger)maxLength
                                   timeout:(NSTimeInterval)timeout
                                     error:(NSError **)error {
    if (!_deviceOpen) {
        [self _setError:error code:-1 message:@"Device not open"];
        return nil;
    }

    io_connect_t conn = _interfaceConnection ?: _deviceConnection;
    if (conn == IO_OBJECT_NULL) {
        [self _setError:error code:-1 message:@"No valid connection"];
        return nil;
    }

    // Bulk IN transfer via user client
    uint8_t *buffer = malloc(maxLength);
    if (!buffer) return nil;
    size_t bytesRead = maxLength;

    uint64_t scalarInput[2];
    scalarInput[0] = _bulkInPipe;
    scalarInput[1] = (uint64_t)(timeout * 1000);  // timeout in ms

    kern_return_t kr = IOConnectCallStructMethod(
        conn,
        kUSBHostInterfaceMethodIO,
        &scalarInput, sizeof(scalarInput),
        buffer, &bytesRead
    );

    if (kr != KERN_SUCCESS) {
        // Try with IOConnectCallMethod
        kr = IOConnectCallMethod(
            conn,
            kUSBHostInterfaceMethodIO,
            scalarInput, 2,
            NULL, 0,
            NULL, NULL,
            buffer, &bytesRead
        );
    }

    if (kr != KERN_SUCCESS) {
        free(buffer);
        if (kr == kIOReturnTimeout || kr == kIOReturnAborted) {
            return [NSData data]; // Timeout: empty data
        }
        [self _setError:error code:kr
               message:[NSString stringWithFormat:@"Bulk read failed (0x%x)", kr]];
        return nil;
    }

    NSData *data = [NSData dataWithBytes:buffer length:bytesRead];
    free(buffer);
    return data;
}

// ============================================================
#pragma mark - Modem Control (RTS / DTR for PTT)
// ============================================================

- (BOOL)setRTS:(BOOL)enabled error:(NSError **)error {
    uint16_t value = CP210X_MHS_RTS_MASK;  // always set mask bit
    if (enabled) value |= CP210X_MHS_RTS_STATE;

    NSLog(@"CP2102USBDriver: Set RTS %@ (0x%04X)", enabled ? @"ON" : @"OFF", value);
    return [self _vendorRequestOut:CP210X_SET_MHS wValue:value wIndex:0
                              data:nil connection:(_deviceConnection ?: _interfaceConnection)
                             error:error];
}

- (BOOL)setDTR:(BOOL)enabled error:(NSError **)error {
    uint16_t value = CP210X_MHS_DTR_MASK;
    if (enabled) value |= CP210X_MHS_DTR_STATE;

    NSLog(@"CP2102USBDriver: Set DTR %@ (0x%04X)", enabled ? @"ON" : @"OFF", value);
    return [self _vendorRequestOut:CP210X_SET_MHS wValue:value wIndex:0
                              data:nil connection:(_deviceConnection ?: _interfaceConnection)
                             error:error];
}

- (BOOL)setBaudRate:(NSUInteger)baudRate error:(NSError **)error {
    io_connect_t conn = _deviceConnection ?: _interfaceConnection;
    if (conn == IO_OBJECT_NULL) {
        [self _setError:error code:-1 message:@"No valid connection"];
        return NO;
    }
    BOOL ok = [self _setBaudRate:baudRate connection:conn error:error];
    if (ok) _baudRate = baudRate;
    return ok;
}

// ============================================================
#pragma mark - USB Device Monitoring
// ============================================================

static void _deviceAdded(void *refCon, io_iterator_t iterator) {
    CP2102USBDriver *driver = (__bridge CP2102USBDriver *)refCon;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint16_t vid = [CP2102USBDriver _getUInt16Property:service key:CFSTR("idVendor")];
        if (vid == CP2102_VENDOR_ID) {
            NSString *name = [CP2102USBDriver _getStringProperty:service key:CFSTR("USB Product Name")]
                          ?: @"CP2102 Device";
            NSLog(@"CP2102USBDriver: Device attached: %@", name);
            dispatch_async(dispatch_get_main_queue(), ^{
                [driver.delegate cp2102DeviceDidAttach:name];
            });
        }
        IOObjectRelease(service);
    }
}

static void _deviceRemoved(void *refCon, io_iterator_t iterator) {
    CP2102USBDriver *driver = (__bridge CP2102USBDriver *)refCon;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        IOObjectRelease(service);
    }
    NSLog(@"CP2102USBDriver: Device detached");
    dispatch_async(dispatch_get_main_queue(), ^{
        [driver.delegate cp2102DeviceDidDetach];
    });
}

- (void)startMonitoring {
    if (_notificationPort) return;

    _notificationPort = IONotificationPortCreate(kIOMainPortDefault);
    if (!_notificationPort) {
        NSLog(@"CP2102USBDriver: Failed to create notification port");
        return;
    }

    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(_notificationPort);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopDefaultMode);

    // Watch for device attach
    CFMutableDictionaryRef matchDict = IOServiceMatching("IOUSBHostDevice");
    if (matchDict) {
        // Add VID match
        CFNumberRef vidRef = CFNumberCreate(NULL, kCFNumberShortType, &(short){CP2102_VENDOR_ID});
        CFDictionarySetValue(matchDict, CFSTR("idVendor"), vidRef);
        CFRelease(vidRef);

        // Note: IOServiceAddMatchingNotification consumes one ref of matchDict
        CFRetain(matchDict); // extra ref for the second notification below

        IOServiceAddMatchingNotification(
            _notificationPort,
            kIOPublishNotification,
            matchDict,
            _deviceAdded,
            (__bridge void *)self,
            &_addedIterator
        );
        // Drain existing entries
        io_service_t s;
        while ((s = IOIteratorNext(_addedIterator)) != IO_OBJECT_NULL) IOObjectRelease(s);
    }

    // Watch for device detach
    matchDict = IOServiceMatching("IOUSBHostDevice");
    if (matchDict) {
        CFNumberRef vidRef = CFNumberCreate(NULL, kCFNumberShortType, &(short){CP2102_VENDOR_ID});
        CFDictionarySetValue(matchDict, CFSTR("idVendor"), vidRef);
        CFRelease(vidRef);

        IOServiceAddMatchingNotification(
            _notificationPort,
            kIOTerminatedNotification,
            matchDict,
            _deviceRemoved,
            (__bridge void *)self,
            &_removedIterator
        );
        io_service_t s;
        while ((s = IOIteratorNext(_removedIterator)) != IO_OBJECT_NULL) IOObjectRelease(s);
    }

    NSLog(@"CP2102USBDriver: Monitoring started");
}

- (void)stopMonitoring {
    if (_addedIterator) { IOObjectRelease(_addedIterator); _addedIterator = IO_OBJECT_NULL; }
    if (_removedIterator) { IOObjectRelease(_removedIterator); _removedIterator = IO_OBJECT_NULL; }
    if (_notificationPort) {
        IONotificationPortDestroy(_notificationPort);
        _notificationPort = NULL;
    }
    NSLog(@"CP2102USBDriver: Monitoring stopped");
}

// ============================================================
#pragma mark - Private: USB Device Discovery
// ============================================================

- (io_service_t)_findUSBDeviceWithVID:(uint16_t)vid PID:(uint16_t)pid {
    // Try both IOUSBHostDevice and AppleUSBHostDevice class names
    NSArray *classNames = @[@"IOUSBHostDevice", @"AppleUSBHostDevice"];

    for (NSString *className in classNames) {
        CFMutableDictionaryRef matching = IOServiceMatching(className.UTF8String);
        if (!matching) continue;

        // Add VID/PID to matching dictionary
        CFNumberRef vidRef = CFNumberCreate(NULL, kCFNumberShortType, &vid);
        CFNumberRef pidRef = CFNumberCreate(NULL, kCFNumberShortType, &pid);
        CFDictionarySetValue(matching, CFSTR("idVendor"), vidRef);
        CFDictionarySetValue(matching, CFSTR("idProduct"), pidRef);
        CFRelease(vidRef);
        CFRelease(pidRef);

        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
        if (service != IO_OBJECT_NULL) {
            NSLog(@"CP2102USBDriver: Found device via %@ matching", className);
            return service;
        }
    }

    // Fallback: scan all USB devices and match by property
    NSLog(@"CP2102USBDriver: Direct matching failed, scanning registry...");
    return [self _scanRegistryForVID:vid PID:pid];
}

- (io_service_t)_scanRegistryForVID:(uint16_t)vid PID:(uint16_t)pid {
    // Walk the IOUSB plane looking for our device
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (!matching) {
        matching = IOServiceMatching("AppleUSBHostDevice");
    }
    if (!matching) return IO_OBJECT_NULL;

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) return IO_OBJECT_NULL;

    io_service_t service;
    io_service_t found = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint16_t devVid = [CP2102USBDriver _getUInt16Property:service key:CFSTR("idVendor")];
        uint16_t devPid = [CP2102USBDriver _getUInt16Property:service key:CFSTR("idProduct")];

        if (devVid == vid && devPid == pid) {
            found = service;
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

- (io_service_t)_findFirstInterface:(io_service_t)device {
    // Look for IOUSBHostInterface child of the device
    io_iterator_t childIterator = IO_OBJECT_NULL;
    kern_return_t kr = IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIterator);
    if (kr != KERN_SUCCESS) return IO_OBJECT_NULL;

    io_service_t child;
    io_service_t found = IO_OBJECT_NULL;
    while ((child = IOIteratorNext(childIterator)) != IO_OBJECT_NULL) {
        io_name_t className;
        IOObjectGetClass(child, className);
        NSString *classStr = [NSString stringWithUTF8String:className];

        if ([classStr containsString:@"Interface"]) {
            found = child;
            NSLog(@"CP2102USBDriver: Found interface: %@", classStr);
            break;
        }

        // Check children of children (some USB stacks have an extra layer)
        io_iterator_t grandchildIter = IO_OBJECT_NULL;
        if (IORegistryEntryGetChildIterator(child, kIOServicePlane, &grandchildIter) == KERN_SUCCESS) {
            io_service_t grandchild;
            while ((grandchild = IOIteratorNext(grandchildIter)) != IO_OBJECT_NULL) {
                IOObjectGetClass(grandchild, className);
                classStr = [NSString stringWithUTF8String:className];
                if ([classStr containsString:@"Interface"]) {
                    found = grandchild;
                    NSLog(@"CP2102USBDriver: Found interface (depth 2): %@", classStr);
                    IOObjectRelease(grandchildIter);
                    IOObjectRelease(child);
                    IOObjectRelease(childIterator);
                    return found;
                }
                IOObjectRelease(grandchild);
            }
            IOObjectRelease(grandchildIter);
        }

        IOObjectRelease(child);
    }
    IOObjectRelease(childIterator);
    return found;
}

// ============================================================
#pragma mark - Private: CP2102 Control Transfers
// ============================================================

- (BOOL)_enableUART:(BOOL)enable connection:(io_connect_t)conn error:(NSError **)error {
    uint16_t value = enable ? CP210X_UART_ENABLE : CP210X_UART_DISABLE;
    NSLog(@"CP2102USBDriver: %@ UART", enable ? @"Enable" : @"Disable");
    return [self _vendorRequestOut:CP210X_IFC_ENABLE wValue:value wIndex:0
                              data:nil connection:conn error:error];
}

- (BOOL)_setBaudRate:(NSUInteger)baudRate connection:(io_connect_t)conn error:(NSError **)error {
    // CP2102 SET_BAUDRATE: 4 bytes little-endian in data phase
    uint32_t rate = (uint32_t)baudRate;
    uint8_t rateBytes[4] = {
        (uint8_t)(rate & 0xFF),
        (uint8_t)((rate >> 8) & 0xFF),
        (uint8_t)((rate >> 16) & 0xFF),
        (uint8_t)((rate >> 24) & 0xFF),
    };
    NSData *data = [NSData dataWithBytes:rateBytes length:4];

    NSLog(@"CP2102USBDriver: Set baud rate %lu", (unsigned long)baudRate);
    return [self _vendorRequestOut:CP210X_SET_BAUDRATE wValue:0 wIndex:0
                              data:data connection:conn error:error];
}

- (BOOL)_setLineControl:(uint16_t)lineCtl connection:(io_connect_t)conn error:(NSError **)error {
    NSLog(@"CP2102USBDriver: Set line control 0x%04X (8N1)", lineCtl);
    return [self _vendorRequestOut:CP210X_SET_LINE_CTL wValue:lineCtl wIndex:0
                              data:nil connection:conn error:error];
}

- (BOOL)_setFlowControl:(io_connect_t)conn error:(NSError **)error {
    // Disable all flow control: 16 bytes of zeros
    uint8_t flowCtl[16] = {0};
    NSData *data = [NSData dataWithBytes:flowCtl length:16];

    NSLog(@"CP2102USBDriver: Disable flow control");
    return [self _vendorRequestOut:CP210X_SET_FLOW wValue:0 wIndex:0
                              data:data connection:conn error:error];
}

- (BOOL)_purge:(uint16_t)mask connection:(io_connect_t)conn error:(NSError **)error {
    NSLog(@"CP2102USBDriver: Purge buffers (mask=0x%04X)", mask);
    return [self _vendorRequestOut:CP210X_PURGE wValue:mask wIndex:0
                              data:nil connection:conn error:error];
}

// ============================================================
#pragma mark - Private: USB Control Transfer via IOConnect
// ============================================================

- (BOOL)_vendorRequestOut:(uint8_t)request
                   wValue:(uint16_t)wValue
                   wIndex:(uint16_t)wIndex
                     data:(nullable NSData *)data
               connection:(io_connect_t)conn
                    error:(NSError **)error {
    if (conn == IO_OBJECT_NULL) {
        [self _setError:error code:-1 message:@"No USB connection"];
        return NO;
    }

    // Pack the USB device request into scalar inputs
    // Format: bmRequestType, bRequest, wValue, wIndex, wLength as scalar args
    uint64_t scalarInput[5];
    scalarInput[0] = kUSBRequestTypeVendorOut;  // bmRequestType
    scalarInput[1] = request;                    // bRequest
    scalarInput[2] = wValue;                     // wValue
    scalarInput[3] = wIndex;                     // wIndex
    scalarInput[4] = data.length;                // wLength

    kern_return_t kr;

    // Try device request method (selector 4 on interface, selector 0 on device)
    uint32_t selector = (_interfaceConnection == conn)
        ? kUSBHostInterfaceMethodDeviceRequest
        : kUSBHostDeviceMethodDeviceRequest;

    kr = IOConnectCallMethod(
        conn,
        selector,
        scalarInput, 5,                  // scalar inputs: request fields
        data.bytes, data.length,         // struct input: data phase
        NULL, NULL,                      // scalar output
        NULL, NULL                       // struct output
    );

    if (kr != KERN_SUCCESS) {
        NSLog(@"CP2102USBDriver: Control transfer failed: request=0x%02X value=0x%04X kr=0x%x",
              request, wValue, kr);
        [self _setError:error code:kr
               message:[NSString stringWithFormat:
                        @"USB control transfer failed (request=0x%02X, kr=0x%x)", request, kr]];
        return NO;
    }

    return YES;
}

// ============================================================
#pragma mark - Private: IOKit Property Helpers
// ============================================================

+ (NSString * _Nullable)_getStringProperty:(io_service_t)entry key:(CFStringRef)key {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return nil;
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nil;
    }
    return (__bridge_transfer NSString *)value;
}

+ (uint16_t)_getUInt16Property:(io_service_t)entry key:(CFStringRef)key {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!value) return 0;
    if (CFGetTypeID(value) != CFNumberGetTypeID()) {
        CFRelease(value);
        return 0;
    }
    uint16_t result = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberSInt16Type, &result);
    CFRelease(value);
    return result;
}

// ============================================================
#pragma mark - Private: Error Helper
// ============================================================

- (void)_setError:(NSError **)error code:(NSInteger)code message:(NSString *)message {
    NSLog(@"CP2102USBDriver: ERROR — %@", message);
    if (error) {
        *error = [NSError errorWithDomain:kCP2102ErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

@end
