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
extern void *vlc_player_aout_Hold(void *player);
extern void aout_Release(void *aout);
extern void libvlc_media_player_set_pause(void *media_player, int do_pause);

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

int bluebox_vlc_set_aout_string(void *media_player, const char *name, const char *value) {
    void *player = player_of(media_player);
    if (player == NULL) return 0;
    void *aout = vlc_player_aout_Hold(player);
    if (aout == NULL) return 0;
    int ok = 0;
    // The output made the variable (with the callback that rebuilds its
    // filters); one of another type means another layout: leave it.
    if ((var_Type(aout, name) & 0xff) == VAR_STRING) {
        bluebox_vlc_value_t v = { .psz_string = (char *)value };
        ok = var_SetChecked(aout, name, VAR_STRING, v) == 0;
    }
    aout_Release(aout);
    return ok;
}

bool bluebox_vlc_pause(void *media_player) {
    if (player_of(media_player) == NULL) return false;
    libvlc_media_player_set_pause(media_player, 1);
    return true;
}

// MARK: - The video track's format

extern void vlc_player_Lock(void *player);
extern void vlc_player_Unlock(void *player);
extern size_t vlc_player_GetTrackCount(void *player, int cat);
extern const void *vlc_player_GetTrackAt(void *player, int cat, size_t index);

enum { VIDEO_ES = 1 };

/// `struct vlc_player_track` is `{ vlc_es_id_t *es_id; char *name; es_format_t fmt; ... }`;
/// `es_format_t` has six 32-bit fields, two strings, a count and a pointer
/// before its union, which starts with `video_format_t` for video:
/// chroma, width, height, x/y offset, visible width/height, SAR, frame rate
/// (eleven 32-bit fields), the palette pointer, then orientation, primaries,
/// transfer, space and range.
static const size_t track_fmt = 16;
static const size_t fmt_video = 56;
static const size_t video_orientation = 48 + 8;

bool bluebox_vlc_video_format_of(void *media_player, uint32_t codec, uint32_t width, uint32_t height,
                                 bluebox_vlc_video_format *out) {
    if (out == NULL) return false;
    out->checked = false;
    void *player = player_of(media_player);
    if (player == NULL) return false;
    bool found = false;
    vlc_player_Lock(player);
    size_t count = vlc_player_GetTrackCount(player, VIDEO_ES);
    for (size_t i = 0; i < count && !found; i++) {
        const char *track = vlc_player_GetTrackAt(player, VIDEO_ES, i);
        if (track == NULL) continue;
        const char *fmt = track + track_fmt;
        const char *video = fmt + fmt_video;
        // The category, codec and size must be the ones libVLC's public API
        // reported for this track, or the offsets are wrong.
        if (*(const int *)fmt != VIDEO_ES || *(const uint32_t *)(fmt + 4) != codec) continue;
        // Once decoding, the size is the coded one (1080p decodes as 1088
        // lines) and the visible size is the track's.
        const uint32_t *size = (const uint32_t *)(video + 4), *visible = (const uint32_t *)(video + 20);
        bool coded = size[0] == width && size[1] == height, shown = visible[0] == width && visible[1] == height;
        if (!coded && !shown) continue;
        const int *colour = (const int *)(video + video_orientation);
        int orientation = colour[0], primaries = colour[1], transfer = colour[2], space = colour[3], range = colour[4];
        if (orientation < 0 || orientation > 7 || primaries < 0 || primaries > 10 || transfer < 0 || transfer > 12
            || space < 0 || space > 4 || range < 0 || range > 2) continue;
        out->checked = true;
        out->chroma = *(const uint32_t *)video;
        out->primaries = primaries;
        out->transfer = transfer;
        out->space = space;
        out->range = range;
        found = true;
    }
    vlc_player_Unlock(player);
    return found;
}
