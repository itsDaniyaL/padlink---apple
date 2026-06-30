//
//  PadLinkVirtualGamepad.cpp
//  DriverKit virtual HID gamepad — implementation.
//
//  NOTE: This is a scaffold. It follows the documented DriverKit / HIDDriverKit
//  patterns but MUST be built and iterated on a Mac with the granted DriverKit
//  HID entitlements (it cannot be compiled outside Xcode's DriverKit toolchain).
//  See README.md in this folder.
//

#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSString.h>
#include <DriverKit/OSNumber.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOMemoryDescriptor.h>

#include <HIDDriverKit/IOHIDDeviceKeys.h>
#include <HIDDriverKit/IOHIDUsageTables.h>

#include "PadLinkVirtualGamepad.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "PadLinkVirtualGamepad - " fmt, ##__VA_ARGS__)

struct PadLinkVirtualGamepad_IVars
{
    // No persistent state needed for the skeleton.
};

// MARK: - HID report descriptor (Xbox-style pad)
// 16 buttons, one 8-way hat, four 16-bit axes (X/Y/Z/Rz), two 8-bit triggers.
// Resulting input report is 13 bytes: see the `Report` struct in postInput().
static const uint8_t kReportDescriptor[] = {
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x05,        // Usage (Game Pad)
    0xA1, 0x01,        // Collection (Application)

    // 16 buttons
    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (1)
    0x29, 0x10,        //   Usage Maximum (16)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x10,        //   Report Count (16)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Hat switch (4 bits) + 4 bits padding
    0x05, 0x01,        //   Usage Page (Generic Desktop)
    0x09, 0x39,        //   Usage (Hat switch)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x07,        //   Logical Maximum (7)
    0x35, 0x00,        //   Physical Minimum (0)
    0x46, 0x3B, 0x01,  //   Physical Maximum (315)
    0x65, 0x14,        //   Unit (Eng Rot: Degrees)
    0x75, 0x04,        //   Report Size (4)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x42,        //   Input (Data,Var,Abs,Null)
    0x65, 0x00,        //   Unit (None)
    0x75, 0x04,        //   Report Size (4)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x03,        //   Input (Const,Var,Abs) — padding

    // Left/right thumbsticks: X, Y, Z, Rz (signed 16-bit)
    0x05, 0x01,        //   Usage Page (Generic Desktop)
    0x09, 0x30,        //   Usage (X)
    0x09, 0x31,        //   Usage (Y)
    0x09, 0x32,        //   Usage (Z)
    0x09, 0x35,        //   Usage (Rz)
    0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
    0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
    0x75, 0x10,        //   Report Size (16)
    0x95, 0x04,        //   Report Count (4)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Two analog triggers (brake / accelerator), 8-bit 0..255
    0x05, 0x02,        //   Usage Page (Simulation Controls)
    0x09, 0xC5,        //   Usage (Brake)
    0x09, 0xC4,        //   Usage (Accelerator)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x02,        //   Report Count (2)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    0xC0               // End Collection
};

// MARK: - Lifecycle

bool
PadLinkVirtualGamepad::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(PadLinkVirtualGamepad_IVars, 1);
    return ivars != nullptr;
}

void
PadLinkVirtualGamepad::free()
{
    IOSafeDeleteNULL(ivars, PadLinkVirtualGamepad_IVars, 1);
    super::free();
}

kern_return_t
IMPL(PadLinkVirtualGamepad, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        Log("super::Start failed: 0x%x", ret);
        return ret;
    }
    Log("started");
    RegisterService();
    return kIOReturnSuccess;
}

kern_return_t
IMPL(PadLinkVirtualGamepad, Stop)
{
    Log("stopping");
    return Stop(provider, SUPERDISPATCH);
}

// MARK: - User client factory

kern_return_t
IMPL(PadLinkVirtualGamepad, NewUserClient)
{
    IOService * client = nullptr;
    // "UserClientProperties" is a dictionary in this driver's Info.plist
    // personality whose IOUserClass = PadLinkUserClient.
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess || client == nullptr) {
        Log("Create(UserClientProperties) failed: 0x%x", ret);
        return ret;
    }
    *userClient = OSDynamicCast(IOUserClient, client);
    if (*userClient == nullptr) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

// MARK: - HID device description / descriptor

OSDictionary *
PadLinkVirtualGamepad::newDeviceDescription(void)
{
    OSDictionary * dict = OSDictionary::withCapacity(8);
    if (dict == nullptr) return nullptr;

    OSString * manufacturer = OSString::withCString("PadLink");
    OSString * product = OSString::withCString("PadLink Virtual Gamepad");
    OSNumber * vendorID = OSNumber::withNumber((uint64_t)0x1209, 32);   // pid.codes
    OSNumber * productID = OSNumber::withNumber((uint64_t)0x5050, 32);
    OSNumber * usagePage = OSNumber::withNumber((uint64_t)kHIDPage_GenericDesktop, 32);
    OSNumber * usage = OSNumber::withNumber((uint64_t)kHIDUsage_GD_GamePad, 32);

    if (manufacturer) { dict->setObject(kIOHIDManufacturerKey, manufacturer); manufacturer->release(); }
    if (product)      { dict->setObject(kIOHIDProductKey, product); product->release(); }
    if (vendorID)     { dict->setObject(kIOHIDVendorIDKey, vendorID); vendorID->release(); }
    if (productID)    { dict->setObject(kIOHIDProductIDKey, productID); productID->release(); }
    if (usagePage)    { dict->setObject(kIOHIDPrimaryUsagePageKey, usagePage); usagePage->release(); }
    if (usage)        { dict->setObject(kIOHIDPrimaryUsageKey, usage); usage->release(); }

    return dict;
}

OSData *
PadLinkVirtualGamepad::newReportDescriptor(void)
{
    return OSData::withBytes(kReportDescriptor, sizeof(kReportDescriptor));
}

// MARK: - Input injection

kern_return_t
PadLinkVirtualGamepad::postInput(const void * bytes, size_t length)
{
    // App submit struct (little-endian, 16 bytes):
    //   u16 buttons | u8 dpad | u8 pad | i16 lx,ly,rx,ry | u16 lt | u16 rt
    if (length < 16 || bytes == nullptr) return kIOReturnBadArgument;
    const uint8_t * b = (const uint8_t *)bytes;

    uint16_t buttons = (uint16_t)(b[0] | (b[1] << 8));
    uint8_t  dpad    = b[2];
    int16_t  lx = (int16_t)(b[4]  | (b[5]  << 8));
    int16_t  ly = (int16_t)(b[6]  | (b[7]  << 8));
    int16_t  rx = (int16_t)(b[8]  | (b[9]  << 8));
    int16_t  ry = (int16_t)(b[10] | (b[11] << 8));
    uint16_t lt = (uint16_t)(b[12] | (b[13] << 8));
    uint16_t rt = (uint16_t)(b[14] | (b[15] << 8));

    struct __attribute__((packed)) Report {
        uint16_t buttons;
        uint8_t  hat;          // low nibble; 0x0F = null (centered)
        int16_t  x, y, z, rz;
        uint8_t  brake, accel;
    } report;

    report.buttons = buttons;
    // PadLink dpad: 0=none, 1=N, 2=NE ... 8=NW. HID hat: 0=N ... 7=NW, null=out-of-range.
    report.hat   = (dpad == 0) ? 0x0F : (uint8_t)(dpad - 1);
    report.x     = lx;
    report.y     = ly;
    report.z     = rx;
    report.rz    = ry;
    report.brake = (uint8_t)((lt > 1023 ? 1023 : lt) * 255 / 1023);
    report.accel = (uint8_t)((rt > 1023 ? 1023 : rt) * 255 / 1023);

    IOBufferMemoryDescriptor * buffer = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut,
                                                         sizeof(report), 0, &buffer);
    if (ret != kIOReturnSuccess || buffer == nullptr) return ret;

    uint64_t address = 0;
    uint64_t mapLen = 0;
    ret = buffer->Map(0, 0, 0, 0, &address, &mapLen);
    if (ret == kIOReturnSuccess && address != 0) {
        memcpy((void *)address, &report, sizeof(report));
        ret = handleReport(0, buffer, sizeof(report), kIOHIDReportTypeInput, 0);
    }

    OSSafeReleaseNULL(buffer);
    return ret;
}
