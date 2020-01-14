
#include "Mouse3DController.hpp"

#include <stdint.h>
#include <dlfcn.h>

#include <array>

#include <cstdio>

static Slic3r::GUI::Mouse3DController* mouse_3d_controller = NULL;

static uint16_t clientID = 0;

static bool driver_loaded = false;
static bool has_old_driver =
    false;  // 3Dconnexion drivers before 10 beta 4 are "old", not all buttons will work
static bool has_new_driver =
    false;  // drivers >= 10.2.2 are "new", and can process events on a separate thread

// replicate just enough of the 3Dx API for our uses, not everything the driver provides

#define kConnexionClientModeTakeOver 1
#define kConnexionMaskAxis 0x3f00
#define kConnexionMaskAll 0x3fff
#define kConnexionMaskAllButtons 0xffffffff
#define kConnexionCmdHandleButtons 2
#define kConnexionCmdHandleAxis 3
#define kConnexionCmdAppSpecific 10
#define kConnexionMsgDeviceState '3dSR'
#define kConnexionCtlGetDeviceID '3did'

#pragma pack(push, 2)  // just this struct
struct ConnexionDeviceState {
  uint16_t version;
  uint16_t client;
  uint16_t command;
  int16_t param;
  int32_t value;
  uint64_t time;
  uint8_t report[8];
  uint16_t buttons8;  // obsolete! (pre-10.x drivers)
  int16_t axis[6];    // tx, ty, tz, rx, ry, rz
  uint16_t address;
  uint32_t buttons;
};
#pragma pack(pop)

// callback functions:
typedef void (*AddedHandler)(uint32_t);
typedef void (*RemovedHandler)(uint32_t);
typedef void (*MessageHandler)(uint32_t, uint32_t msg_type, void *msg_arg);

// driver functions:
typedef int16_t (*SetConnexionHandlers_ptr)(MessageHandler, AddedHandler, RemovedHandler, bool);
typedef int16_t (*InstallConnexionHandlers_ptr)(MessageHandler, AddedHandler, RemovedHandler);
typedef void (*CleanupConnexionHandlers_ptr)();
typedef uint16_t (*RegisterConnexionClient_ptr)(uint32_t signature,
                                                const char *name,
                                                uint16_t mode,
                                                uint32_t mask);
typedef void (*SetConnexionClientButtonMask_ptr)(uint16_t clientID, uint32_t buttonMask);
typedef void (*UnregisterConnexionClient_ptr)(uint16_t clientID);
typedef int16_t (*ConnexionClientControl_ptr)(uint16_t clientID,
                                              uint32_t message,
                                              int32_t param,
                                              int32_t *result);

#define DECLARE_FUNC(name) name##_ptr name = NULL

DECLARE_FUNC(SetConnexionHandlers);
DECLARE_FUNC(InstallConnexionHandlers);
DECLARE_FUNC(CleanupConnexionHandlers);
DECLARE_FUNC(RegisterConnexionClient);
DECLARE_FUNC(SetConnexionClientButtonMask);
DECLARE_FUNC(UnregisterConnexionClient);
DECLARE_FUNC(ConnexionClientControl);

static void *load_func(void *module, const char *func_name)
{
  void *func = dlsym(module, func_name);

#if ENABLE_3DCONNEXION_DEVICES_DEBUG_OUTPUT
  if (func) {
    printf("'%s' loaded\n", func_name);
  }
  else {
    printf("<!> %s\n", dlerror());
  }
#endif

  return func;
}

#define LOAD_FUNC(name) name = (name##_ptr)load_func(module, #name)

static void *module;  // handle to the whole driver

static bool load_driver_functions()
{
  if (driver_loaded) {
    return true;
  }

  module = dlopen("/Library/Frameworks/3DconnexionClient.framework/3DconnexionClient",
                  RTLD_LAZY | RTLD_LOCAL);

  if (module) {
    LOAD_FUNC(SetConnexionHandlers);

    if (SetConnexionHandlers != NULL) {
      driver_loaded = true;
      has_new_driver = true;
    }
    else {
      LOAD_FUNC(InstallConnexionHandlers);

      driver_loaded = (InstallConnexionHandlers != NULL);
    }

    if (driver_loaded) {
      LOAD_FUNC(CleanupConnexionHandlers);
      LOAD_FUNC(RegisterConnexionClient);
      LOAD_FUNC(SetConnexionClientButtonMask);
      LOAD_FUNC(UnregisterConnexionClient);
      LOAD_FUNC(ConnexionClientControl);

      has_old_driver = (SetConnexionClientButtonMask == NULL);
    }
  }
#if DENABLE_3DCONNEXION_DEVICES_DEBUG_OUTPUT
  else {
    printf("<!> %s\n", dlerror());
  }

  printf("loaded: %s\n", driver_loaded ? "YES" : "NO");
  printf("old: %s\n", has_old_driver ? "YES" : "NO");
  printf("new: %s\n", has_new_driver ? "YES" : "NO");
#endif

  return driver_loaded;
}

static void unload_driver()
{
  dlclose(module);
}

static void DeviceAdded(uint32_t unused)
{
#if ENABLE_3DCONNEXION_DEVICES_DEBUG_OUTPUT
  printf("3d device added\n");
#endif

  // determine exactly which device is plugged in
  int32_t result;
  ConnexionClientControl(clientID, kConnexionCtlGetDeviceID, 0, &result);
  int16_t vendorID = result >> 16;
  int16_t productID = result & 0xffff;

  //TODO: verify device


  //ndof_manager->setDevice(vendorID, productID);
}

static void DeviceRemoved(uint32_t unused)
{
#if ENABLE_3DCONNEXION_DEVICES_DEBUG_OUTPUT
  printf("3d device removed\n");
#endif
}

static void DeviceEvent(uint32_t unused, uint32_t msg_type, void *msg_arg)
{
  //std::cout<<"DEVICE EVENT"<<std::endl;
  
  if (msg_type == kConnexionMsgDeviceState) {
  //if(msg_type != 862212163){
    ConnexionDeviceState *s = (ConnexionDeviceState *)msg_arg;

    // device state is broadcast to all clients; only react if sent to us
    //if (s->client == clientID) {
      // TODO: is s->time compatible with GHOST timestamps? if so use that instead.
      //GHOST_TUns64 now = ghost_system->getMilliSeconds();

      switch (s->command) {
        case kConnexionCmdHandleAxis: {
            
           std::array<unsigned char, 13> dataPacket = {{(unsigned char)0,
           (unsigned char)(s->axis[0] & 0xFFFF) , (unsigned char)(s->axis[0] & 0xFFFF0000),
           (unsigned char)(s->axis[1] & 0xFFFF) , (unsigned char)(s->axis[1] & 0xFFFF0000),
           (unsigned char)(s->axis[2] & 0xFFFF) , (unsigned char)(s->axis[2] & 0xFFFF0000),
           (unsigned char)(s->axis[3] & 0xFFFF) , (unsigned char)(s->axis[3] & 0xFFFF0000),
           (unsigned char)(s->axis[4] & 0xFFFF) , (unsigned char)(s->axis[4] & 0xFFFF0000),
           (unsigned char)(s->axis[5] & 0xFFFF) , (unsigned char)(s->axis[5] & 0xFFFF0000)}};

            for (int i = 0; i < 6; i++) {
                //std::cout<<i<<":"<<std::hex<<dataPacket[i]<<", ";
                //std::cout<<i<<":"<<s->axis[i]<<", ";
                printf("0x%.8X ",s->axis[i]);
            }
            std::cout<<std::endl;
           
            
           mouse_3d_controller->handle_packet_translation(dataPacket);
           mouse_3d_controller->handle_packet_rotation(dataPacket,7);

          
          break;
        }
        case kConnexionCmdHandleButtons:
        break;
        case kConnexionCmdAppSpecific:
          break;
        default:
        break;
      }
    //}
  }
  
}

namespace Slic3r {
namespace GUI {
Mouse3DHandlerMac::Mouse3DHandlerMac(Mouse3DController* controller)
{
  if (load_driver_functions()) {
    mouse_3d_controller = controller;

    uint16_t error;
    if (has_new_driver) {
      const bool separate_thread = false;  // TODO: rework Mac event handler to allow this
      error = SetConnexionHandlers(DeviceEvent, DeviceAdded, DeviceRemoved, separate_thread);
    }
    else {
      error = InstallConnexionHandlers(DeviceEvent, DeviceAdded, DeviceRemoved);
    }

    if (error) {
      return;
    }

    // Pascal string *and* a four-letter constant. How old-skool.
    clientID = RegisterConnexionClient(
        0, "\011PrusaSlicer", kConnexionClientModeTakeOver, kConnexionMaskAxis);

    //if (!has_old_driver) {
    //  SetConnexionClientButtonMask(clientID, kConnexionMaskAllButtons);
    //}
  }
}

Mouse3DHandlerMac::~Mouse3DHandlerMac()
{
  if (driver_loaded) {
    UnregisterConnexionClient(clientID);
    CleanupConnexionHandlers();
    unload_driver();
  }
  mouse_3d_controller = nullptr;
}

bool Mouse3DHandlerMac::available()
{
  return driver_loaded;
}

}}//namespace Slic3r::GUI
