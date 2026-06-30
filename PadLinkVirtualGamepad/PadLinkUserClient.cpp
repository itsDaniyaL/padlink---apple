//
//  PadLinkUserClient.cpp
//  Bridges the host app's IOConnectCallStructMethod calls to the HID device.
//
//  Scaffold — build/iterate inside Xcode's DriverKit target (see README.md).
//

#include <os/log.h>

#include <DriverKit/IOUserClient.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/OSData.h>

#include "PadLinkUserClient.h"
#include "PadLinkVirtualGamepad.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "PadLinkUserClient - " fmt, ##__VA_ARGS__)

struct PadLinkUserClient_IVars
{
    PadLinkVirtualGamepad * device;   // our provider (the HID device)
};

bool
PadLinkUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(PadLinkUserClient_IVars, 1);
    return ivars != nullptr;
}

void
PadLinkUserClient::free()
{
    IOSafeDeleteNULL(ivars, PadLinkUserClient_IVars, 1);
    super::free();
}

kern_return_t
IMPL(PadLinkUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    ivars->device = OSDynamicCast(PadLinkVirtualGamepad, provider);
    if (ivars->device == nullptr) {
        Log("provider is not PadLinkVirtualGamepad");
        return kIOReturnError;
    }
    Log("user client started");
    return kIOReturnSuccess;
}

kern_return_t
IMPL(PadLinkUserClient, Stop)
{
    ivars->device = nullptr;
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(PadLinkUserClient, ExternalMethod)
{
    // Selector 0 = submitReport: structureInput is the 16-byte app submit struct.
    if (selector == 0) {
        if (arguments != nullptr && arguments->structureInput != nullptr && ivars->device != nullptr) {
            OSData * input = arguments->structureInput;
            size_t length = input->getLength();
            const void * bytes = input->getBytesNoCopy();
            if (bytes != nullptr && length >= 16) {
                return ivars->device->postInput(bytes, length);
            }
        }
        return kIOReturnBadArgument;
    }
    return kIOReturnUnsupported;
}
