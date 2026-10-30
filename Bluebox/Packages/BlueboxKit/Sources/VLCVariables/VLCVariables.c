// libVLC's public API has no way to change the subtitle text renderer's look
// once a player exists, only libVLC instance arguments. libvlccore's variable
// API is in the same static library, and every module reads its options
// through it (var_Inherit walks up from the module to the player, then the
// instance), so a variable set on the player wins over the instance's.

#include "VLCVariables.h"

#include <stddef.h>
#include <stdlib.h>

typedef union {
    int64_t i_int;
    bool b_bool;
    float f_float;
    char *psz_string;
    void *p_address;
    struct { int32_t x; int32_t y; } coords;
} bluebox_vlc_value_t;

enum { VAR_BOOL = 0x0020, VAR_INTEGER = 0x0030, VAR_STRING = 0x0040, VAR_FLOAT = 0x0050 };

extern int config_GetType(const char *name);
extern int var_Create(void *object, const char *name, int type);
extern int var_Type(void *object, const char *name);
extern int var_SetChecked(void *object, const char *name, int type, bluebox_vlc_value_t value);
extern void *vlc_object_parent(void *object);
extern void **vlc_player_vout_HoldAll(void *player, size_t *count);
extern void vout_Release(void *vout);

/// libVLC 4's `libvlc_media_player_t` starts with its `vlc_object_t`; the
/// `vlc_player_t *` follows the object (24 bytes) and the reference count.
static const size_t player_offset = 0x20;

static void *player_of(void *media_player) {
    if (media_player == NULL) return NULL;
    void *player = *(void **)((char *)media_player + player_offset);
    // The player is the media player's child: anything else means another layout.
    if (player == NULL || vlc_object_parent(player) != media_player) return NULL;
    return player;
}

static bool set(void *media_player, const char *name, int type, bluebox_vlc_value_t value) {
    if (player_of(media_player) == NULL) return false;
    // A module option read as another type gets the raw bits (release builds
    // only assert the type): -90 set as an integer reads as a NaN float.
    int option = config_GetType(name) & 0xff;
    if (option != 0 && option != type) return false;
    int existing = var_Type(media_player, name);
    if (existing == 0) {
        if (var_Create(media_player, name, type) != 0) return false;
    } else if ((existing & 0xff) != type) {
        return false;
    }
    return var_SetChecked(media_player, name, type, value) == 0;
}

bool bluebox_vlc_set_integer(void *media_player, const char *name, int64_t value) {
    bluebox_vlc_value_t v = { .i_int = value };
    return set(media_player, name, VAR_INTEGER, v);
}

bool bluebox_vlc_set_float(void *media_player, const char *name, float value) {
    bluebox_vlc_value_t v = { .f_float = value };
    return set(media_player, name, VAR_FLOAT, v);
}

bool bluebox_vlc_set_bool(void *media_player, const char *name, bool value) {
    bluebox_vlc_value_t v = { .b_bool = value };
    return set(media_player, name, VAR_BOOL, v);
}

bool bluebox_vlc_set_string(void *media_player, const char *name, const char *value) {
    bluebox_vlc_value_t v = { .psz_string = (char *)value };
    return set(media_player, name, VAR_STRING, v);
}

int bluebox_vlc_set_vout_integer(void *media_player, const char *name, int64_t value) {
    void *player = player_of(media_player);
    if (player == NULL) return 0;
    size_t count = 0;
    void **vouts = vlc_player_vout_HoldAll(player, &count);
    if (vouts == NULL) return 0;
    int set_count = 0;
    bluebox_vlc_value_t v = { .i_int = value };
    for (size_t i = 0; i < count; i++) {
        if ((var_Type(vouts[i], name) & 0xff) == VAR_INTEGER && var_SetChecked(vouts[i], name, VAR_INTEGER, v) == 0) set_count++;
        vout_Release(vouts[i]);
    }
    free(vouts);
    return set_count;
}
