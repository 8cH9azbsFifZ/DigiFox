//
//  IOKitUSBSerial.h
//  JS8Call
//
//  IOKit-based USB Serial port access for iOS.
//  Uses dlopen to load IOKit at runtime (private API).
//  Required for USB CDC-ACM devices like Digirig Mobile (CP2102).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents a discovered USB serial device
@interface USBSerialDeviceInfo : NSObject
@property (nonatomic, copy) NSString *path;       // e.g. /dev/tty.usbserial-0001
@property (nonatomic, copy) NSString *name;       // e.g. "CP2102 USB to UART Bridge"
@property (nonatomic, assign) uint16_t vendorID;
@property (nonatomic, assign) uint16_t productID;
@end

/// Low-level IOKit USB Serial port access
@interface IOKitUSBSerial : NSObject

/// Check if IOKit is available on this device
+ (BOOL)isAvailable;

/// Discover all USB serial devices currently connected
+ (NSArray<USBSerialDeviceInfo *> *)discoverDevices;

/// Open a serial port at the given path
/// @param path Device path, e.g. /dev/tty.usbserial-0001
/// @param baudRate Baud rate, e.g. 9600, 38400, 115200
/// @param error Error output
/// @return Instance or nil on failure
- (nullable instancetype)initWithPath:(NSString *)path
                             baudRate:(NSUInteger)baudRate
                                error:(NSError **)error;

/// Close the serial port
- (void)close;

/// Whether the port is currently open
@property (nonatomic, readonly) BOOL isOpen;

/// Write data to the serial port
/// @return Number of bytes written, or -1 on error
- (NSInteger)writeData:(NSData *)data error:(NSError **)error;

/// Write a string (UTF-8) to the serial port
- (NSInteger)writeString:(NSString *)string error:(NSError **)error;

/// Read available data (non-blocking)
/// @param maxLength Maximum bytes to read
/// @return Data read, or nil on error
- (nullable NSData *)readDataWithMaxLength:(NSUInteger)maxLength error:(NSError **)error;

/// Read data with timeout
/// @param maxLength Maximum bytes to read
/// @param timeout Timeout in seconds
/// @return Data read, or nil on error/timeout
- (nullable NSData *)readDataWithMaxLength:(NSUInteger)maxLength
                                   timeout:(NSTimeInterval)timeout
                                     error:(NSError **)error;

/// Set RTS (Request To Send) line state — used for PTT on Digirig
- (BOOL)setRTS:(BOOL)enabled error:(NSError **)error;

/// Set DTR (Data Terminal Ready) line state
- (BOOL)setDTR:(BOOL)enabled error:(NSError **)error;

/// Device path this port was opened with
@property (nonatomic, copy, readonly) NSString *devicePath;

/// Current baud rate
@property (nonatomic, readonly) NSUInteger baudRate;

/// Raw file descriptor for direct POSIX write (used by CW keyer for zero-latency writes)
@property (nonatomic, readonly) int fileDescriptor;

@end

NS_ASSUME_NONNULL_END
