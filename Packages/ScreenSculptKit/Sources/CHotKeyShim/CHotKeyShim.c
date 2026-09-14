// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

#include "include/CHotKeyShim.h"

// Four-char signature identifying our hotkeys in the Carbon registry: 'SSpt'.
static const OSType kScreenSculptSignature = 'SSpt';

OSStatus ss_install_hotkey_handler(SSEventHandlerProcPtr handler,
                                   void*                 userData,
                                   SSEventHandlerRef*    outHandler) {
    if (handler == NULL || outHandler == NULL) return kSSParamErr;

    // Only the pressed event. Registering for released as well would double
    // every capture, since the key-up arrives immediately after the key-down.
    const SSEventTypeSpec spec = {
        .eventClass = kSSEventClassKeyboard,
        .eventKind  = kSSEventHotKeyPressed
    };

    // GetEventDispatcherTarget rather than GetApplicationEventTarget: the
    // dispatcher receives hotkey events even when the app is not frontmost,
    // which is the entire point of a global hotkey.
    return InstallEventHandler(GetEventDispatcherTarget(),
                               handler,
                               1,
                               &spec,
                               userData,
                               outHandler);
}

OSStatus ss_register_hotkey(UInt32            keyCode,
                            UInt32            carbonModifiers,
                            UInt32            identifier,
                            SSEventHotKeyRef* outRef) {
    if (outRef == NULL) return kSSParamErr;

    const SSEventHotKeyID hotKeyID = {
        .signature = kScreenSculptSignature,
        .id        = identifier
    };

    // kSSEventHotKeyExclusive makes a conflict an error we can report, instead
    // of a registration that silently never fires.
    return RegisterEventHotKey(keyCode,
                               carbonModifiers,
                               hotKeyID,
                               GetEventDispatcherTarget(),
                               kSSEventHotKeyExclusive,
                               outRef);
}

OSStatus ss_hotkey_id_from_event(SSEventRef event, UInt32* outIdentifier) {
    if (event == NULL || outIdentifier == NULL) return kSSParamErr;

    SSEventHotKeyID hotKeyID = {0};
    const OSStatus status = GetEventParameter(event,
                                              kSSEventParamDirectObject,
                                              kSSTypeEventHotKeyID,
                                              NULL,
                                              (UInt32)sizeof(hotKeyID),
                                              NULL,
                                              &hotKeyID);
    if (status != kSSNoErr) return status;

    // Ignore anything that is not ours, in case another handler in-process
    // registered hotkeys against the same dispatcher target.
    if (hotKeyID.signature != kScreenSculptSignature) return kSSParamErr;

    *outIdentifier = hotKeyID.id;
    return kSSNoErr;
}
