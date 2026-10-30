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

#endif
