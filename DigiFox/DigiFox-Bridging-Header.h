#ifndef DigiFox_Bridging_Header_h
#define DigiFox_Bridging_Header_h

#import "IOKitUSBSerial.h"
#import "CP2102USBDriver.h"
#include <hamlib/rig.h>
// Old CW decoder disabled — replaced by ggmorse
// #include "cw_decoder.h"
#include "ggmorse_c_api.h"

// ft8_lib — LDPC decoder and CRC for FT8/FT4
// https://github.com/kgoba/ft8_lib (MIT license)
#include "constants.h"
#include "ldpc.h"
#include "crc.h"

// LZHUF compression — Haruhiko Okumura (1989), public domain
// C port faithful to wl2k-go/lzhuf (la5nta, MIT license)
// Used by Winlink B2F protocol (Pat client)
// https://github.com/la5nta/wl2k-go/tree/master/lzhuf
#include "lzhuf.h"

#endif
