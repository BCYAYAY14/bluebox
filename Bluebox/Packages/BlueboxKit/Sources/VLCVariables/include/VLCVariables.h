#ifndef BLUEBOX_VLC_VARIABLES_H
#define BLUEBOX_VLC_VARIABLES_H

#include <stdbool.h>
#include <stdint.h>

/// Sets a libVLC object variable on a media player (`libvlc_media_player_t *`),
/// creating it there first. Modules started by that player afterwards (the text
/// renderer, subtitle decoders, video outputs) inherit it, and the text
/// renderer re-reads some on every frame. Returns false when the player
/// doesn't look like libVLC 4's (nothing is set then).
bool bluebox_vlc_set_integer(void *media_player, const char *name, int64_t value);
bool bluebox_vlc_set_float(void *media_player, const char *name, float value);
bool bluebox_vlc_set_bool(void *media_player, const char *name, bool value);
bool bluebox_vlc_set_string(void *media_player, const char *name, const char *value);

/// Sets an integer variable on each running video output of the player (for
/// variables a video output acts on when they change, like `sub-margin`).
/// Returns how many outputs took it.
int bluebox_vlc_set_vout_integer(void *media_player, const char *name, int64_t value);

/// Sets a string variable on the player's audio output, which acts on it at
/// once: `audio-filter` rebuilds the output's filter chain live (the
/// compressor and the equalizer run there). Returns 1 when the output took
/// it, 0 when there's no output yet or the variable isn't a string there.
int bluebox_vlc_set_aout_string(void *media_player, const char *name, const char *value);

/// Pauses the media player itself (`libvlc_media_player_set_pause`), under
/// SwiftVLC: for a pause SwiftVLC believes it already made while libVLC plays
/// on. Returns false when the player doesn't look like libVLC 4's.
bool bluebox_vlc_pause(void *media_player);

/// What libVLC knows about a video track's picture beyond its public track
/// API: the colour description (for HDR) and the decoded chroma (for bit
/// depth). `checked` is false when the track's format didn't match the layout
/// this was written against (libVLC 4.0's `es_format_t`), and nothing else is
/// set then. Enum values are libVLC's (`video_color_primaries_t`,
/// `video_transfer_func_t`, `video_color_space_t`).
typedef struct {
    bool checked;
    uint32_t chroma;
    int primaries;
    int transfer;
    int space;
    int range;
} bluebox_vlc_video_format;

/// Looks up the player's video track with this codec and width (from libVLC's
/// public track list) and reads its format. Returns false when there's no
/// such track or the layout didn't check out.
bool bluebox_vlc_video_format_of(void *media_player, uint32_t codec, uint32_t width, uint32_t height,
                                 bluebox_vlc_video_format *out);

#endif
