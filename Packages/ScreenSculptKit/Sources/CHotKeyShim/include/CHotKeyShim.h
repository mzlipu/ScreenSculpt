// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors
//
// Carbon Event Manager hotkey API, declared by hand.
//
// WHY THIS FILE EXISTS
// --------------------
// As of the macOS 26 SDK, essentially the whole Carbon Event Manager has been
// removed from the public headers. Verified against
// Carbon.framework/Frameworks/HIToolbox.framework/Headers on this machine:
// `CarbonEvents.h` is still present (16,667 lines) but declares none of
// RegisterEventHotKey, EventHotKeyRef, EventHotKeyID, EventTargetRef,
// EventTypeSpec, InstallEventHandler, GetEventParameter or CopySymbolicHotKeys.
//
// The symbols are nonetheless still exported from HIToolbox.tbd (all eight
// checked), so redeclaring the prototypes links cleanly.
//
// WHY BOTHER
// ----------
// RegisterEventHotKey is the only API on macOS that grants a genuinely
// system-wide hotkey **without requiring Accessibility permission**. The
// alternatives both need it: CGEventTap (which also taxes every keystroke
// system-wide and gets disabled on timeout) and NSEvent global monitors (which
// additionally cannot consume the event, so the frontmost app sees it too).
// ScreenSculpt already spends the user's Accessibility goodwill on scrolling
// capture; it should not need to spend it twice just to bind a key.
//
// THE RISK, AND WHY IT IS CONTAINED
// ---------------------------------
// Header removal is a loud signal that the exports may follow. That is exactly
// why this lives in its own target with no dependencies: on the day Apple drops
// the symbols, precisely one file fails to link, and SSHotKeys already ships two
// working fallback backends behind the same protocol.

#ifndef CHOTKEYSHIM_H
#define CHOTKEYSHIM_H

#include <CoreFoundation/CoreFoundation.h>
#include <MacTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Opaque types

typedef struct OpaqueEventRef*            SSEventRef;
typedef struct OpaqueEventTargetRef*      SSEventTargetRef;
typedef struct OpaqueEventHandlerRef*     SSEventHandlerRef;
typedef struct OpaqueEventHandlerCallRef* SSEventHandlerCallRef;
typedef struct OpaqueEventHotKeyRef*      SSEventHotKeyRef;

typedef struct SSEventHotKeyID {
    OSType signature;
    UInt32 id;
} SSEventHotKeyID;

typedef struct SSEventTypeSpec {
    UInt32 eventClass;
    UInt32 eventKind;
} SSEventTypeSpec;

typedef OSStatus (*SSEventHandlerProcPtr)(SSEventHandlerCallRef inHandlerCallRef,
                                          SSEventRef            inEvent,
                                          void*                 inUserData);

#pragma mark - Constants
//
// Four-character codes, spelled out so nobody has to decode them later.

enum {
    kSSEventClassKeyboard = 'keyb',   // event class for hotkey events
    kSSEventHotKeyPressed = 6,        // kEventHotKeyPressed
    kSSEventHotKeyReleased = 7,       // kEventHotKeyReleased
    kSSEventParamDirectObject = '----',
    kSSTypeEventHotKeyID = 'hkid'
};

// Carbon modifier masks. These are NOT the same bit values as
// NSEvent.ModifierFlags — converting between them is SSHotKeys' job.
enum {
    kSSCmdKeyMask     = 1 << 8,
    kSSShiftKeyMask   = 1 << 9,
    kSSOptionKeyMask  = 1 << 11,
    kSSControlKeyMask = 1 << 12
};

// Classic OSStatus results. These live in CarbonCore's MacErrors.h, which is
// not reachable from MacTypes.h alone; the values are ABI-stable and have been
// since System 7, so declaring them is safer than pulling in the umbrella.
enum {
    kSSNoErr    = 0,
    kSSParamErr = -50
};

// Returned by RegisterEventHotKey when another process already holds the
// combination exclusively. Surface this in the shortcut recorder as "already
// taken" rather than registering a hotkey that silently never fires.
enum { kSSEventHotKeyExistsErr = -9878 };

// Pass as `inOptions` to get the error above instead of a silent conflict.
enum { kSSEventHotKeyExclusive = 1 };

#pragma mark - Redeclared HIToolbox entry points

extern OSStatus RegisterEventHotKey(UInt32            inHotKeyCode,
                                    UInt32            inHotKeyModifiers,
                                    SSEventHotKeyID   inHotKeyID,
                                    SSEventTargetRef  inTarget,
                                    OptionBits        inOptions,
                                    SSEventHotKeyRef* outRef);

extern OSStatus UnregisterEventHotKey(SSEventHotKeyRef inHotKey);

extern SSEventTargetRef GetEventDispatcherTarget(void);
extern SSEventTargetRef GetApplicationEventTarget(void);

extern OSStatus InstallEventHandler(SSEventTargetRef       inTarget,
                                    SSEventHandlerProcPtr  inHandler,
                                    ItemCount              inNumTypes,
                                    const SSEventTypeSpec* inList,
                                    void*                  inUserData,
                                    SSEventHandlerRef*     outRef);

extern OSStatus RemoveEventHandler(SSEventHandlerRef inHandlerRef);

extern OSStatus GetEventParameter(SSEventRef  inEvent,
                                  UInt32      inName,
                                  UInt32      inDesiredType,
                                  UInt32*     outActualType,
                                  UInt32      inBufferSize,
                                  UInt32*     outActualSize,
                                  void*       outData);

/// Currently-defined system symbolic hotkeys, as an array of dictionaries.
///
/// Used to refuse a binding the system already owns — RegisterEventHotKey will
/// otherwise appear to succeed while the system wins and the user sees nothing
/// happen. Caller owns the returned array.
///
/// Note SSHotKeys prefers reading the `com.apple.symbolichotkeys` domain, which
/// identifies *which* shortcut is which (IDs 28/29/30/31/184 are the screenshot
/// ones); this call only says that some system shortcut owns the combination.
extern OSStatus CopySymbolicHotKeys(CFArrayRef* outHotKeys);

#pragma mark - Convenience wrappers
//
// Thin helpers so the Swift side never has to build a Carbon struct or juggle
// an out-parameter of opaque pointer type.

/// Install the process-wide hotkey handler. Returns 0 on success.
OSStatus ss_install_hotkey_handler(SSEventHandlerProcPtr handler,
                                   void*                 userData,
                                   SSEventHandlerRef*    outHandler);

/// Register one hotkey, exclusively. `outRef` receives the token needed to
/// unregister it. Returns `kSSEventHotKeyExistsErr` if the combination is taken.
OSStatus ss_register_hotkey(UInt32            keyCode,
                            UInt32            carbonModifiers,
                            UInt32            identifier,
                            SSEventHotKeyRef* outRef);

/// Extract the hotkey identifier from a dispatched event.
OSStatus ss_hotkey_id_from_event(SSEventRef event, UInt32* outIdentifier);

#ifdef __cplusplus
}
#endif

#endif /* CHOTKEYSHIM_H */
