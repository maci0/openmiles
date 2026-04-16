# OpenMiles API Implementation Status (MSS 6.6)

This document tracks the implementation status of the Miles Sound System (MSS) 6.6 API.

## Core System
*(Appeared in MSS v3+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_HWND` | ⚪ Stub | Returns null; not applicable under miniaudio |
| `AIL_MMX_available` | ⚪ Stub | Returns 0; MMX detection not applicable |
| `AIL_background` | ⚪ Stub | Returns null; not applicable |
| `AIL_delay` | 🟢 Implemented | |
| `AIL_lock` | ⚪ Stub | No-op; miniaudio manages its own synchronization |
| `AIL_lock_mutex` | ⚪ Stub | No-op; miniaudio manages its own synchronization |
| `AIL_ms_count` | 🟢 Implemented | |
| `AIL_set_error` | 🟢 Implemented | |
| `AIL_unlock` | ⚪ Stub | No-op; miniaudio manages its own synchronization |
| `AIL_unlock_mutex` | ⚪ Stub | No-op; miniaudio manages its own synchronization |
| `AIL_us_count` | 🟢 Implemented | |
| `AIL_debug_printf` | 🟢 Implemented | |
| `AIL_sprintf` | 🟢 Implemented | |
| `AIL_get_DirectSound_info` | ⚪ Stub | Returns 0; DirectSound not used |
| `AIL_set_DirectSound_HWND` | ⚪ Stub | No-op; DirectSound not used |
| `AIL_digital_CPU_percent` | 🟡 Partial | Estimated from active sound count vs nominal 32-voice budget |
| `AIL_digital_latency` | 🟢 Implemented | Queries miniaudio device period for real latency |
| `AIL_digital_configuration` | 🟢 Implemented | |
| `DllMain` | 🟢 Implemented | |
| `AIL_file_error` | 🟢 Implemented | |
| `AIL_file_read` | 🟢 Implemented | |
| `AIL_file_size` | 🟢 Implemented | |
| `AIL_file_type` | 🟢 Implemented | |
| `AIL_file_write` | 🟢 Implemented | |
| `AIL_set_file_callbacks` | 🟢 Implemented | |
| `AIL_set_file_async_callbacks` | 🟢 Implemented | |
| `AIL_startup` | 🟢 Implemented | Registers built-in ASI codec provider |
| `AIL_shutdown` | 🟢 Implemented | Tears down digital and MIDI drivers |
| `AIL_set_redist_directory` | 🟢 Implemented | Stores path and triggers provider scanning on existing drivers |
| `AIL_last_error` | 🟢 Implemented | Returns last error set by API calls; empty string when none |
| `AIL_get_preference` | 🟢 Implemented | |
| `AIL_set_preference` | 🟢 Implemented | |
| `AIL_serve` | ⚪ Stub | No-op; miniaudio uses its own audio thread |

## RIB / ASI Plugin System
*(Appeared in MSS v4+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_request_EOB_ASI_reset` | 🟢 Implemented | |
| `RIB_enumerate_interface` | 🟢 Implemented | |
| `RIB_error` | 🟢 Implemented | |
| `RIB_find_file_dec_provider` | 🟢 Implemented | |
| `RIB_find_file_provider` | 🟢 Implemented | |
| `RIB_find_provider` | 🟢 Implemented | |
| `RIB_free_provider_library` | 🟢 Implemented | |
| `RIB_load_provider_library` | 🟢 Implemented | |
| `RIB_provider_system_data` | 🟢 Implemented | |
| `RIB_provider_user_data` | 🟢 Implemented | |
| `RIB_request_interface_entry` | 🟢 Implemented | |
| `RIB_set_provider_system_data` | 🟢 Implemented | |
| `RIB_set_provider_user_data` | 🟢 Implemented | |
| `RIB_type_string` | 🟢 Implemented | |
| `RIB_alloc_provider_handle` | 🟢 Implemented | Creates and returns a new Provider |
| `RIB_free_provider_handle` | 🟢 Implemented | Deinitializes provider |
| `RIB_register_interface` | 🟢 Implemented | Registers interface entries on a provider |
| `RIB_unregister_interface` | 🟢 Implemented | Removes interface by name from provider |
| `RIB_provider_library_handle` | 🟢 Implemented | Returns current loading provider or startup provider |
| `RIB_load_application_providers` | 🟢 Implemented | Scans directory for .asi/.m3d/.flt plugins; returns 1 on success |
| `RIB_enumerate_providers` | 🟢 Implemented | Iterates all registered providers matching requested interface |
| `RIB_request_interface` | 🟢 Implemented | Copies built-in ASI interface entries |
| `RIB_find_files_provider` | 🟢 Implemented | Delegates to RIB_enumerate_providers |
| `AIL_open_ASI_provider` | 🟢 Implemented | Writes buffer to temp DLL file and loads via Provider.load |
| `AIL_close_ASI_provider` | 🟢 Implemented | |
| `AIL_ASI_provider_attribute` | 🟢 Implemented | Searches registered interfaces |

## Digital Audio Driver
*(Appeared in MSS v3+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_primary_digital_driver` | 🟢 Implemented | |
| `AIL_process_digital_audio` | 🟢 Implemented | Captures engine output via onProcess callback; returns 16-bit PCM with optional mono down-mix |
| `AIL_set_digital_driver_processor` | 🟡 Partial | Callback is stored and returned on subsequent set (round-tripping); not invoked during processing |
| `AIL_size_processed_digital_audio` | 🟢 Implemented | Computes output size from format parameters |
| `AIL_open_digital_driver` | 🟢 Implemented | Uses miniaudio engine; `bits` parameter ignored |
| `AIL_close_digital_driver` | 🟢 Implemented | |
| `AIL_set_digital_master_volume` | 🟢 Implemented | Cubic perceptual curve (0-127 → ~60dB range) |
| `AIL_digital_master_volume` | 🟢 Implemented | Returns current engine volume mapped to 0-127 |

## Sample Management
*(Appeared in MSS v3+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_WAV_file_write` | 🟢 Implemented | |
| `AIL_WAV_info` | 🟢 Implemented | |
| `AIL_allocate_file_sample` | 🟢 Implemented | |
| `AIL_compress_ADPCM` | 🟢 Implemented | |
| `AIL_decompress_ADPCM` | 🟢 Implemented | |
| `AIL_load_sample_buffer` | 🟢 Implemented | |
| `AIL_minimum_sample_buffer_size` | 🟢 Implemented | |
| `AIL_register_EOB_callback` | 🟢 Implemented | |
| `AIL_register_SOB_callback` | 🟢 Implemented | |
| `AIL_sample_buffer_info` | 🟢 Implemented | |
| `AIL_sample_buffer_ready` | ⚪ Stub | Always returns 1 (buffer always reported as ready); double-buffered streaming not implemented |
| `AIL_sample_granularity` | 🟢 Implemented | |
| `AIL_sample_reverb` | 🟢 Implemented | Returns current room_type, level, reflect_time |
| `AIL_sample_user_data` | 🟢 Implemented | |
| `AIL_set_sample_adpcm_block_size` | 🟢 Implemented | Stores block size hint on Sample (miniaudio handles actual decoding) |
| `AIL_set_sample_loop_block` | 🟢 Implemented | |
| `AIL_set_sample_processor` | 🟡 Partial | Callback stored per stage (input/output) for round-tripping; not invoked |
| `AIL_set_sample_reverb` | 🟢 Implemented | Creates ma_delay_node per-sample; maps room_type→decay, level→wet/dry, reflect_time→delay frames |
| `AIL_set_sample_user_data` | 🟢 Implemented | |
| `AIL_allocate_sample_handle` | 🟢 Implemented | |
| `AIL_release_sample_handle` | 🟢 Implemented | |
| `AIL_init_sample` | 🟢 Implemented | Resets sample properties and engine state |
| `AIL_set_sample_file` | 🟢 Implemented | Memory-based decoding via miniaudio |
| `AIL_set_named_sample_file` | 🟢 Implemented | Same as `set_sample_file`; ignores file type string |
| `AIL_set_sample_address` | 🟢 Implemented | Loads from memory via miniaudio decoder |
| `AIL_set_sample_type` | 🟢 Implemented | Configures raw PCM format before playback |
| `AIL_start_sample` | 🟢 Implemented | |
| `AIL_stop_sample` | 🟢 Implemented | Stops and rewinds to start |
| `AIL_pause_sample` | 🟢 Implemented | |
| `AIL_resume_sample` | 🟢 Implemented | |
| `AIL_end_sample` | 🟢 Implemented | Transitions to SMP_DONE (unlike stop which goes to SMP_STOPPED) |
| `AIL_sample_status` | 🟢 Implemented | Returns SMP_DONE/SMP_STOPPED/SMP_PLAYING |
| `AIL_sample_volume` | 🟢 Implemented | Returns current volume as 0-127 |
| `AIL_sample_pan` | 🟢 Implemented | Returns current pan as 0-127 |
| `AIL_sample_playback_rate` | 🟢 Implemented | Returns target rate or default 44100 |
| `AIL_set_sample_volume` | 🟢 Implemented | Cubic perceptual curve (0-127 → ~60dB range) matching original MSS attenuation |
| `AIL_set_sample_pan` | 🟢 Implemented | |
| `AIL_set_sample_volume_pan` | 🟢 Implemented | Sets both volume and pan |
| `AIL_set_sample_playback_rate` | 🟢 Implemented | Adjusts pitch relative to native sample rate |
| `AIL_set_sample_loop_count` | 🟢 Implemented | 0 = infinite, 1 = once, N = plays N times; handled via EOS callback chaining |
| `AIL_sample_ms_position` | 🟢 Implemented | Returns total and current position in ms |
| `AIL_set_sample_ms_position` | 🟢 Implemented | Seeks to ms position |
| `AIL_sample_position` | 🟢 Implemented | Returns position in bytes using actual format info; falls back to 16-bit stereo |
| `AIL_set_sample_position` | 🟢 Implemented | Seeks to byte position using actual format info; falls back to 16-bit stereo |
| `AIL_sample_loop_count` | 🟢 Implemented | Returns current loop count |
| `AIL_active_sample_count` | 🟢 Implemented | Returns number of currently playing samples |
| `AIL_register_EOS_callback` | 🟢 Implemented | Stores callback; fires from miniaudio end-of-sound event |

## Streaming Audio
*(Appeared in MSS v3+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_register_EOF_callback` | 🟢 Implemented | |
| `AIL_service_stream` | ⚪ Stub | Returns 1; miniaudio handles servicing internally |
| `AIL_set_stream_loop_block` | 🟢 Implemented | |
| `AIL_set_stream_position` | 🟢 Implemented | |
| `AIL_set_stream_processor` | 🟡 Partial | Callback stored per stage (input/output) for round-tripping; not invoked |
| `AIL_set_stream_reverb` | 🟢 Implemented | Same ma_delay_node reverb as sample reverb |
| `AIL_set_stream_user_data` | 🟢 Implemented | |
| `AIL_stream_info` | 🟢 Implemented | |
| `AIL_stream_position` | 🟢 Implemented | |
| `AIL_stream_reverb` | 🟢 Implemented | |
| `AIL_stream_user_data` | 🟢 Implemented | |
| `AIL_open_stream` | 🟢 Implemented | File-based streaming via miniaudio; returns a Sample internally |
| `AIL_close_stream` | 🟢 Implemented | |
| `AIL_start_stream` | 🟢 Implemented | |
| `AIL_pause_stream` | 🟢 Implemented | |
| `AIL_set_stream_volume` | 🟢 Implemented | |
| `AIL_set_stream_pan` | 🟢 Implemented | |
| `AIL_set_stream_playback_rate` | 🟢 Implemented | |
| `AIL_set_stream_loop_count` | 🟢 Implemented | Same mechanism as sample loop count |
| `AIL_set_stream_ms_position` | 🟢 Implemented | |
| `AIL_stream_status` | 🟢 Implemented | |
| `AIL_stream_volume` | 🟢 Implemented | |
| `AIL_stream_pan` | 🟢 Implemented | |
| `AIL_stream_playback_rate` | 🟢 Implemented | |
| `AIL_stream_loop_count` | 🟢 Implemented | |
| `AIL_stream_ms_position` | 🟢 Implemented | Returns total and current position in ms |
| `AIL_register_stream_callback` | 🟢 Implemented | Stores callback; fires at end-of-stream via EOS mechanism |
| `AIL_auto_service_stream` | ⚪ Stub | No-op; miniaudio handles servicing internally |

## MIDI API
*(Appeared in MSS v3+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_MIDI_handle_reacquire` | ⚪ Stub | Returns 1; device sharing not applicable |
| `AIL_MIDI_handle_release` | ⚪ Stub | No-op; device sharing not applicable |
| `AIL_create_wave_synthesizer` | 🟢 Implemented | |
| `AIL_destroy_wave_synthesizer` | 🟢 Implemented | |
| `AIL_map_sequence_channel` | 🟢 Implemented | Per-sequence 16-channel mapping applied in MIDI event dispatch |
| `AIL_register_ICA_array` | 🟢 Implemented | Sends initial CC values per channel to TinySoundFont |
| `AIL_true_sequence_channel` | 🟢 Implemented | Returns mapped physical channel from sequence channel_map |
| `AIL_filter_DLS_attribute` | 🟢 Implemented | Reads Cutoff/Compression DLS prefs from MidiDriver |
| `AIL_filter_DLS_with_XMI` | ⚪ Stub | Returns 0 |
| `AIL_set_DLS_processor` | 🟡 Partial | Callback stored for round-tripping; not invoked |
| `AIL_set_filter_DLS_preference` | 🟢 Implemented | Stores Cutoff/Compression DLS prefs on MidiDriver |
| `DLSMSSGetCPU` | 🟡 Partial | Delegates to digital driver CPU estimate |
| `DLSSetAttribute` | 🟢 Implemented | Stores Cutoff/Compression attributes on MidiDriver |
| `AIL_open_midi_driver` | 🟢 Implemented | Uses TinySoundFont |
| `AIL_close_midi_driver` | 🟢 Implemented | |
| `AIL_open_XMIDI_driver` | 🟢 Implemented | Alias for `AIL_open_midi_driver` |
| `AIL_close_XMIDI_driver` | 🟢 Implemented | Alias for `AIL_close_midi_driver` |
| `AIL_DLS_load_file` | 🟢 Implemented | Loads SF2 soundfont banks |
| `AIL_DLS_unload_file` | 🟢 Implemented | Closes and clears the loaded soundfont |
| `AIL_DLS_load_memory` | 🟢 Implemented | Loads SF2 soundfont from memory |
| `AIL_DLS_unload` | 🟢 Implemented | Alias for unload_file |
| `AIL_DLS_compact` | ⚪ Stub | No-op (miniaudio handles memory management) |
| `AIL_DLS_get_info` | 🟢 Implemented | Returns soundfont memory footprint via DlsInfo struct |
| `AIL_DLS_get_reverb` / `AIL_DLS_set_reverb` | 🟢 Implemented | Stores room_type/level/reflect_time on MidiDriver |
| `AIL_DLS_open` | 🟢 Implemented | Opens MIDI driver with DLS bank |
| `AIL_DLS_close` | 🟢 Implemented | |
| `AIL_allocate_sequence_handle` | 🟢 Implemented | |
| `AIL_release_sequence_handle` | 🟢 Implemented | |
| `AIL_init_sequence` | 🟢 Implemented | Loads MIDI data from memory |
| `AIL_start_sequence` | 🟢 Implemented | Real-time rendering via miniaudio data source |
| `AIL_stop_sequence` | 🟢 Implemented | |
| `AIL_pause_sequence` | 🟢 Implemented | |
| `AIL_resume_sequence` | 🟢 Implemented | |
| `AIL_end_sequence` | 🟢 Implemented | Alias for stop |
| `AIL_sequence_status` | 🟢 Implemented | Returns SEQ_DONE/SEQ_PLAYING/SEQ_STOPPED |
| `AIL_set_sequence_volume` | 🟢 Implemented | Fades correctly using miniaudio fade logic |
| `AIL_sequence_volume` | 🟢 Implemented | |
| `AIL_set_sequence_loop_count` | 🟢 Implemented | |
| `AIL_sequence_loop_count` | 🟢 Implemented | |
| `AIL_sequence_ms_position` / `AIL_set_sequence_ms_position` | 🟢 Implemented | Tracks running ms accumulator; seek replays channel state |
| `AIL_sequence_tempo` / `AIL_set_sequence_tempo` | 🟢 Implemented | Supports gradual tempo fade over `ms` duration via linear interpolation |
| `AIL_active_sequence_count` | 🟢 Implemented | |
| `AIL_sequence_position` | 🟢 Implemented | Returns current beat and measure |
| `AIL_sequence_user_data` / `AIL_set_sequence_user_data` | 🟢 Implemented | |
| `AIL_branch_index` | 🟢 Implemented | Sets branch index internally |
| `AIL_channel_notes` | 🟢 Implemented | Counts active voices per channel via TinySoundFont |
| `AIL_controller_value` | 🟢 Implemented | Reads directly from TinySoundFont |
| `AIL_send_channel_voice_message` | 🟢 Implemented | Parses and forwards to TSF |
| `AIL_send_sysex_message` | 🟢 Implemented | Recognizes GM/GS/XG reset; resets all channels (notes off, controllers, volume, pan) |
| `AIL_lock_channel` / `AIL_release_channel` | 🟢 Implemented | Global 16-channel reservation system; lock returns first free non-drum channel |
| `AIL_register_beat_callback` | 🟢 Implemented | Fires continuously during playback |
| `AIL_register_event_callback` | 🟢 Implemented | Fires on Control Change messages |
| `AIL_register_prefix_callback` | 🟢 Implemented | Handles system exclusive prefixes |
| `AIL_register_trigger_callback` | 🟢 Implemented | Fires on CC 111 (XMIDI trigger) |
| `AIL_register_sequence_callback` | 🟢 Implemented | Fires when sequence ends naturally |
| `AIL_register_timbre_callback` | 🟢 Implemented | Fires on Program Change |
| `AIL_XMIDI_master_volume` / `AIL_set_XMIDI_master_volume` | 🟢 Implemented | Scales global TSF output volume |
| `AIL_MIDI_to_XMI` | 🟢 Implemented | Passes data through as-is; AIL_init_sequence handles both SMF and XMIDI |
| `AIL_compress_DLS` / `AIL_extract_DLS` / `AIL_find_DLS` | ⚪ Stub | Returns 0 |
| `AIL_list_DLS` / `AIL_list_MIDI` / `AIL_merge_DLS_with_XMI` | ⚪ Stub | Returns 0 |
| `DLSClose` / `DLSLoadFile` / `DLSLoadMemFile` / `DLSMSSOpen` | 🟢 Implemented | Aliases for corresponding AIL_DLS_* functions |
| `DLSUnloadFile` | 🟢 Implemented | Alias for AIL_DLS_unload |
| `DLSCompactMemory` | ⚪ Stub | No-op (miniaudio handles memory management) |
| `DLSUnloadAll` | 🟢 Implemented | Unloads all soundfonts from the MidiDriver |
| `DLSGetInfo` | 🟢 Implemented | Delegates to `AIL_DLS_get_info` |

## 3D Audio API
*(Appeared in MSS v5+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_3D_provider_attribute` | 🟢 Implemented | |
| `AIL_3D_sample_attribute` | 🟢 Implemented | |
| `AIL_auto_update_3D_position` | 🟢 Implemented | |
| `AIL_enumerate_3D_provider_attributes` | 🟢 Implemented | |
| `AIL_enumerate_3D_sample_attributes` | 🟢 Implemented | |
| `AIL_set_3D_provider_preference` | 🟢 Implemented | |
| `AIL_set_3D_sample_info` | 🟢 Implemented | |
| `AIL_set_3D_sample_loop_block` | 🟢 Implemented | |
| `AIL_set_3D_sample_preference` | 🟢 Implemented | |
| `AIL_set_3D_velocity_vector` | 🟢 Implemented | |
| `AIL_update_3D_position` | 🟢 Implemented | |
| `AIL_allocate_3D_sample_handle` | 🟢 Implemented | Allocates Sample3D with full spatial audio support |
| `AIL_release_3D_sample_handle` | 🟢 Implemented | Frees Sample3D handle |
| `AIL_set_3D_sample_file` | 🟢 Implemented | Loads audio data from memory buffer into Sample3D |
| `AIL_set_3D_position` | 🟢 Implemented | Sets position on Sample3D via miniaudio spatial audio |
| `AIL_set_3D_velocity` | 🟢 Implemented | Sets velocity on Sample3D via miniaudio spatial audio |
| `AIL_set_3D_orientation` | 🟡 Partial | Sets forward + up for listener; up vector stored but not applied to individual Sample3D objects (miniaudio per-sound limitation) |
| `AIL_set_3D_sample_distances` | 🟢 Implemented | Sets min/max distance via miniaudio spatial audio |
| `AIL_set_listener_3D_position` | 🟢 Implemented | Sets listener position via `ma_engine_listener_set_position` |
| `AIL_set_listener_3D_velocity` | 🟢 Implemented | Sets listener velocity via `ma_engine_listener_set_velocity` |
| `AIL_set_listener_3D_orientation` | 🟢 Implemented | Sets listener direction + world-up via miniaudio |
| `AIL_enumerate_3D_providers` | 🟢 Implemented | Returns built-in OpenMiles Software 3D provider |
| `AIL_start_3D_sample` | 🟢 Implemented | Starts 3D sample playback |
| `AIL_stop_3D_sample` | 🟢 Implemented | Stops 3D sample |
| `AIL_resume_3D_sample` | 🟢 Implemented | Resumes 3D sample |
| `AIL_end_3D_sample` | 🟢 Implemented | Transitions to SMP_DONE (unlike stop which goes to SMP_STOPPED) |
| `AIL_3D_sample_status` | 🟢 Implemented | Returns SMP_DONE/SMP_STOPPED/SMP_PLAYING |
| `AIL_3D_sample_volume` | 🟢 Implemented | |
| `AIL_set_3D_sample_volume` | 🟢 Implemented | |
| `AIL_3D_sample_loop_count` | 🟢 Implemented | |
| `AIL_set_3D_sample_loop_count` | 🟢 Implemented | |
| `AIL_3D_sample_playback_rate` | 🟢 Implemented | |
| `AIL_set_3D_sample_playback_rate` | 🟢 Implemented | |
| `AIL_3D_sample_offset` | 🟢 Implemented | Returns PCM byte offset |
| `AIL_set_3D_sample_offset` | 🟢 Implemented | Seeks to PCM byte offset |
| `AIL_3D_sample_length` | 🟢 Implemented | Returns total PCM length |
| `AIL_3D_sample_ms_position` | 🟢 Implemented | |
| `AIL_set_3D_sample_ms_position` | 🟢 Implemented | |
| `AIL_register_3D_EOS_callback` | 🟢 Implemented | |
| `AIL_active_3D_sample_count` | 🟢 Implemented | |
| `AIL_3D_user_data` / `AIL_set_3D_user_data` | 🟢 Implemented | |
| `AIL_3D_sample_distances` | 🟢 Implemented | Returns current min/max distances |
| `AIL_set_3D_sample_cone` / `AIL_3D_sample_cone` | 🟢 Implemented | Uses miniaudio sound cones |
| `AIL_set_3D_sample_effects_level` / `AIL_3D_sample_effects_level` | 🟢 Implemented | |
| `AIL_set_3D_sample_obstruction` / `AIL_3D_sample_obstruction` | 🟢 Implemented | |
| `AIL_set_3D_sample_occlusion` / `AIL_3D_sample_occlusion` | 🟢 Implemented | |
| `AIL_3D_distance_factor` / `AIL_set_3D_distance_factor` | 🟢 Implemented | |
| `AIL_3D_doppler_factor` / `AIL_set_3D_doppler_factor` | 🟢 Implemented | Maps to miniaudio engine doppler |
| `AIL_3D_rolloff_factor` / `AIL_set_3D_rolloff_factor` | 🟢 Implemented | Maps to miniaudio engine rolloff |
| `AIL_3D_room_type` / `AIL_set_3D_room_type` | 🟢 Implemented | |
| `AIL_3D_speaker_type` / `AIL_set_3D_speaker_type` | 🟢 Implemented | |
| `AIL_open_3D_provider` / `AIL_close_3D_provider` | 🟢 Implemented | Returns driver handle as 3D provider |
| `AIL_open_3D_listener` / `AIL_close_3D_listener` | 🟢 Implemented | Returns provider as listener handle |
| `AIL_open_3D_object` / `AIL_close_3D_object` | 🟢 Implemented | Allocates/frees Sample3D |
| `AIL_3D_orientation` / `AIL_3D_position` / `AIL_3D_velocity` | 🟢 Implemented | Returns listener orientation/position/velocity |

## Filter API
*(Appeared in MSS v6+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_enumerate_filter_attributes` | 🟢 Implemented | Enumerates Cutoff and Order attributes |
| `AIL_enumerate_filter_sample_attributes` | 🟢 Implemented | Enumerates Cutoff and Order attributes |
| `AIL_filter_sample_attribute` | 🟢 Implemented | Reads Cutoff/Order from sample's attached filter |
| `AIL_filter_stream_attribute` | 🟢 Implemented | Reads Cutoff/Order from stream's attached filter |
| `AIL_set_filter_preference` | 🟢 Implemented | Sets Cutoff/Order on filter handle |
| `AIL_set_filter_sample_preference` | 🟢 Implemented | Sets Cutoff/Order via sample's attached filter |
| `AIL_set_filter_stream_preference` | 🟢 Implemented | Sets Cutoff/Order via stream's attached filter |
| `AIL_open_filter` | 🟢 Implemented | Creates Filter with miniaudio ma_lpf_node for low-pass filtering |
| `AIL_close_filter` | 🟢 Implemented | Detaches all samples and frees filter node |
| `AIL_set_sample_filter` | 🟢 Implemented | Routes sample audio through filter's LPF node |
| `AIL_filter_attribute` | 🟢 Implemented | Reads Cutoff (Hz) and Order attributes |
| `AIL_set_filter_attribute` | 🟢 Implemented | Sets Cutoff (Hz) and Order; reinitializes LPF in real-time |
| `AIL_enumerate_filters` | 🟢 Implemented | Returns built-in OpenMiles Low-Pass Filter |

## Timer API
*(Appeared in MSS v3+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_get_timer_highest_delay` | 🟢 Implemented | |
| `AIL_release_all_timers` | 🟢 Implemented | |
| `AIL_set_timer_divisor` | 🟢 Implemented | |
| `AIL_set_timer_user` | 🟢 Implemented | |
| `AIL_register_timer` | 🟢 Implemented | Creates timer with callback thread |
| `AIL_set_timer_frequency` | 🟢 Implemented | Sets timer period from frequency |
| `AIL_set_timer_period` | 🟢 Implemented | Sets timer period in microseconds |
| `AIL_set_timer_user_data` | 🟢 Implemented | Sets user data passed to callback |
| `AIL_start_timer` | 🟢 Implemented | Starts timer thread |
| `AIL_stop_timer` | 🟢 Implemented | Stops timer thread |
| `AIL_release_timer_handle` | 🟢 Implemented | Stops and frees timer |
| `AIL_start_all_timers` | 🟢 Implemented | Starts all registered timers via global timer registry |
| `AIL_stop_all_timers` | 🟢 Implemented | Stops all registered timers via global timer registry |

## Quick API
*(Appeared in MSS v4+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_quick_halt` | 🟢 Implemented | |
| `AIL_quick_handles` | 🟢 Implemented | |
| `AIL_quick_load_and_play` | 🟢 Implemented | |
| `AIL_quick_set_reverb` | 🟢 Implemented | |
| `AIL_quick_type` | 🟢 Implemented | |
| `AIL_quick_startup` | 🟢 Implemented | Opens digital and/or MIDI driver based on flags |
| `AIL_quick_shutdown` | 🟢 Implemented | Closes digital and MIDI drivers |
| `AIL_quick_load` | 🟢 Implemented | File-based loading |
| `AIL_quick_load_mem` | 🟢 Implemented | Memory-based loading |
| `AIL_quick_copy` | 🟢 Implemented | Copies owned audio buffer to new sample handle |
| `AIL_quick_unload` | 🟢 Implemented | |
| `AIL_quick_play` | 🟢 Implemented | |
| `AIL_quick_stop` | 🟢 Implemented | |
| `AIL_quick_status` | 🟢 Implemented | |
| `AIL_quick_set_volume` | 🟢 Implemented | |
| `AIL_quick_set_speed` | 🟢 Implemented | Delegates to playback rate (pitch-based) |
| `AIL_quick_ms_length` | 🟢 Implemented | Queries miniaudio for total length |
| `AIL_quick_ms_position` | 🟢 Implemented | Queries miniaudio for current position |
| `AIL_quick_set_ms_position` | 🟢 Implemented | Seeks to ms position |

## Redbook (CD) API
*(Appeared in MSS v3+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_redbook_open` / `AIL_redbook_open_drive` | 🟢 Implemented | Creates emulated Redbook handle |
| `AIL_redbook_close` | 🟢 Implemented | Frees handle |
| `AIL_redbook_play` | 🟢 Implemented | Tracks play state (start/end track); no actual audio (no CD) |
| `AIL_redbook_stop` | 🟢 Implemented | |
| `AIL_redbook_pause` | 🟢 Implemented | Pauses and remembers position |
| `AIL_redbook_resume` | 🟢 Implemented | Resumes from paused position |
| `AIL_redbook_status` | 🟢 Implemented | Returns stopped/playing/paused |
| `AIL_redbook_tracks` | 🟢 Implemented | Returns 0 (no physical disc — games fall back gracefully) |
| `AIL_redbook_track` | 🟢 Implemented | Returns current track |
| `AIL_redbook_track_info` | 🟢 Implemented | Returns zeros (no disc) |
| `AIL_redbook_position` | 🟢 Implemented | Real-time ms-from-play-start while playing |
| `AIL_redbook_eject` | 🟢 Implemented | Stops playback |
| `AIL_redbook_retract` | 🟢 Implemented | Returns 1 |
| `AIL_redbook_id` | 🟢 Implemented | Returns empty string (no disc ID) |
| `AIL_redbook_set_volume` | 🟢 Implemented | Stored volume (0-127) |
| `AIL_redbook_volume` | 🟢 Implemented | Returns stored volume |

## Memory API
*(Appeared in MSS v4+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_mem_use_free` | ⚪ Stub | No-op; custom allocator callbacks ignored; OpenMiles always uses its own allocator |
| `AIL_mem_use_malloc` | ⚪ Stub | No-op; custom allocator callbacks ignored; OpenMiles always uses its own allocator |
| `AIL_set_mem_callbacks` | ⚪ Stub | No-op; custom allocator callbacks ignored; OpenMiles always uses its own allocator |
| `AIL_mem_alloc_lock` | 🟢 Implemented | Uses C allocator |
| `AIL_mem_free_lock` | 🟢 Implemented | |

## Compression API
*(Appeared in MSS v4+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_compress_ASI` | ⚪ Stub | Always returns 0 |
| `AIL_decompress_ASI` | 🟢 Implemented | Decodes to 16-bit stereo PCM at 44100 Hz via miniaudio, writes as WAV |

## Input API
*(Appeared in MSS v4+)*
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_close_input` | 🟢 Implemented | Stops and frees miniaudio capture device |
| `AIL_get_input_info` | 🟢 Implemented | Returns current captured sample count |
| `AIL_open_input` | 🟢 Implemented | Creates miniaudio ma_device in capture mode (16-bit mono 44100Hz) |
| `AIL_set_input_state` | 🟢 Implemented | Starts/stops capture; records into internal ring buffer |

## Legacy Compatibility
| Function | Status | Notes |
|----------|--------|-------|
| `AIL_waveOutClose` | 🟢 Implemented | |
| `AIL_midiOutClose` | ⚪ Stub | No-op; legacy midiOut not applicable |
| `AIL_midiOutOpen` | ⚪ Stub | Returns 0; legacy midiOut not applicable |
| `AIL_waveOutOpen` | 🟢 Implemented | Opens digital driver; returns dummy waveOut handle |
| `AIL_digital_handle_release` | ⚪ Stub | No-op |
| `AIL_digital_handle_reacquire` | ⚪ Stub | Always returns 1 |

## Legend
- 🟢 Implemented — Functional
- 🟡 Partial — Works but with known limitations
- ⚪ Stub — Exported for compatibility, no-op or returns default

## Test Coverage (2026-04-14)
Verified end-to-end with **Europa 1400 Gold: The Guild** (TL edition) under Wine 11.6:
- `AIL_startup` → 4 external ASI plugins loaded, built-in codec registered
- `AIL_waveOutOpen` → 3 digital drivers opened (WASAPI backend)
- 48 `AIL_allocate_sample_handle` calls succeeded
- `AIL_open_stream` → MP3 file streaming confirmed (`KraeuterUndPhiolen.mp3`)
- `AIL_set_named_sample_file` → WAV sample loading confirmed (RIFF, 252 bytes)
- Volume, pan, loop count, position seek, pause/resume all exercised
- Build: `zig build -Dtarget=x86-windows -Doptimize=ReleaseSmall`