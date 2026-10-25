/* No-op Orblite backend. HP DeskJet 1050 J410 uses LEDM (HPLIP scan-type 7). */

#include <stddef.h>
#include "sane.h"
#include "orblitei.h"

SANE_Status orblite_init(SANE_Int *version_code, SANE_Auth_Callback authorize) {
    (void)authorize;
    if (version_code)
        *version_code = SANE_VERSION_CODE(1, 0, 0);
    return SANE_STATUS_GOOD;
}

SANE_Status orblite_get_devices(const SANE_Device ***device_list, SANE_Bool local_only) {
    /* hpaio.c can pass an uninitialized pointer. Do not dereference it. */
    (void)device_list;
    (void)local_only;
    return SANE_STATUS_GOOD;
}

SANE_Status orblite_open(SANE_String_Const devicename, SANE_Handle *handle) {
    (void)devicename;
    (void)handle;
    return SANE_STATUS_UNSUPPORTED;
}

void orblite_close(SANE_Handle handle) {
    (void)handle;
}

SANE_Status orblite_control_option(SANE_Handle handle, SANE_Int option, SANE_Action action, void *value, SANE_Int *info) {
    (void)handle;
    (void)option;
    (void)action;
    (void)value;
    (void)info;
    return SANE_STATUS_UNSUPPORTED;
}

SANE_Status orblite_get_parameters(SANE_Handle handle, SANE_Parameters *params) {
    (void)handle;
    (void)params;
    return SANE_STATUS_UNSUPPORTED;
}

SANE_Status orblite_start(SANE_Handle handle) {
    (void)handle;
    return SANE_STATUS_UNSUPPORTED;
}

SANE_Status orblite_read(SANE_Handle handle, SANE_Byte *data, SANE_Int max_length, SANE_Int *length) {
    (void)handle;
    (void)data;
    (void)max_length;
    (void)length;
    return SANE_STATUS_UNSUPPORTED;
}

void orblite_cancel(SANE_Handle handle) {
    (void)handle;
}
