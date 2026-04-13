//
//  CP2102USBDriver.h
//  DigiFox
//
//  Direct USB communication with Silicon Labs CP2102 chip on iOS.
//  Uses public IOKit APIs (IOServiceOpen + IOConnectCallMethod) to
//  perform vendor-specific control transfers and bulk I/O — no kernel
//  serial driver needed.
//
//  CP2102 vendor protocol based on Silicon Labs AN571 and Linux cp210x driver.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Connection state of the CP2102 USB driver
typedef NS_ENUM(NSInteger, CP2102State) {
    CP2102StateDisconnected = 0,
    CP2102StateConnecting,
    CP2102StateConnected,
    CP2102StateError
};

/// Delegate for USB device attach/detach notifications
@protocol CP2102USBDriverDelegate <NSObject>
@optional
- (void)cp2102DeviceDidAttach:(NSString *)deviceName;
- (void)cp2102DeviceDidDetach;
- (void)cp2102DidReceiveData:(NSData *)data;
- (void)cp2102DidEncounterError:(NSError *)error;
@end

/// Low-level USB driver for CP2102 (Silicon Labs) serial chips.
/// Communicates directly via IOKit user client — works on real iOS devices
/// where no /dev/tty.* nodes exist.
@interface CP2102USBDriver : NSObject

/// Current connection state
@property (nonatomic, readonly) CP2102State state;

/// Whether USB host IOKit services are available (real device or simulator)
@property (class, nonatomic, readonly) BOOL isAvailable;

/// Delegate for device events
@property (nonatomic, weak, nullable) id<CP2102USBDriverDelegate> delegate;

/// Discover CP2102 devices in the IOKit registry.
/// Returns array of dictionaries with keys: path, name, vendorID, productID
+ (NSArray<NSDictionary *> *)discoverDevices;

/// Open connection to CP2102 device
/// @param vendorID  USB Vendor ID (0x10C4 for Silicon Labs)
/// @param productID USB Product ID (0xEA60 for CP2102)
/// @param baudRate  Desired baud rate (e.g. 9600, 38400, 115200)
/// @param error     Error output
/// @return YES on success
- (BOOL)openWithVendorID:(uint16_t)vendorID
               productID:(uint16_t)productID
                baudRate:(NSUInteger)baudRate
                   error:(NSError **)error;

/// Open the first CP2102 (Digirig) device found
- (BOOL)openDigirigWithBaudRate:(NSUInteger)baudRate error:(NSError **)error;

/// Close the connection
- (void)close;

/// Write data to the serial port (via USB bulk transfer)
/// @return Number of bytes written, or -1 on error
- (NSInteger)writeData:(NSData *)data error:(NSError **)error;

/// Write a UTF-8 string
- (NSInteger)writeString:(NSString *)string error:(NSError **)error;

/// Read available data (blocking up to timeout)
/// @param maxLength Maximum bytes to read
/// @param timeout   Timeout in seconds (0 = non-blocking)
/// @return Data read, or nil on error
- (nullable NSData *)readDataWithMaxLength:(NSUInteger)maxLength
                                   timeout:(NSTimeInterval)timeout
                                     error:(NSError **)error;

/// Set RTS line state — used for PTT on Digirig
- (BOOL)setRTS:(BOOL)enabled error:(NSError **)error;

/// Set DTR line state
- (BOOL)setDTR:(BOOL)enabled error:(NSError **)error;

/// Change baud rate on an open connection
- (BOOL)setBaudRate:(NSUInteger)baudRate error:(NSError **)error;

/// Start monitoring for USB device attach/detach (calls delegate methods)
- (void)startMonitoring;

/// Stop monitoring
- (void)stopMonitoring;

@end

NS_ASSUME_NONNULL_END
