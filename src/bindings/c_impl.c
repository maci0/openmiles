#define MINIAUDIO_IMPLEMENTATION
#include "../deps/miniaudio.h"

#define TSF_IMPLEMENTATION
#include "../deps/tsf.h"

#define TML_IMPLEMENTATION
#include "../deps/tml.h"

// tml_message uses anonymous unions; Zig's @cImport cannot access anonymous
// union fields, so we provide named accessor functions.
// Count active voices on a specific MIDI channel.
// TSF's internal voice array isn't cleanly exposed to Zig, so we iterate here.
int openmiles_tsf_channel_note_count(tsf* f, int channel) {
    if (!f) return 0;
    int count = 0;
    for (int i = 0; i < f->voiceNum; i++) {
        struct tsf_voice* v = &f->voices[i];
        if (v->playingPreset != -1 && v->playingChannel == channel
            && v->ampenv.segment < TSF_SEGMENT_RELEASE) {
            count++;
        }
    }
    return count;
}

// AIL_sprintf: implemented in C to avoid Zig stage2_llvm miscompilation of
// C varargs on Windows. Exported as AIL_sprintf via linker directives in digital.zig.
#include <stdio.h>
#include <stdarg.h>
char* AIL_sprintf(char* buf, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, 4096, fmt, args);
    va_end(args);
    return buf;
}

unsigned char openmiles_tml_get_key(tml_message* m) { return m->key; }
unsigned char openmiles_tml_get_velocity(tml_message* m) { return m->velocity; }
unsigned char openmiles_tml_get_control(tml_message* m) { return m->control; }
unsigned char openmiles_tml_get_control_value(tml_message* m) { return m->control_value; }
unsigned char openmiles_tml_get_program(tml_message* m) { return m->program; }
unsigned short openmiles_tml_get_pitch_bend(tml_message* m) { return m->pitch_bend; }
