## Executive Summary
- **Top performance concerns**: Logger lock contention, ADPCM decompression memory usage, and unbounded slice creation for memory streams.
- **Overall assessment**: The application is relatively well-optimized with a few areas showing clear signs of inefficiency, mostly around memory reallocation and locking.
- **Top 3 highest impact optimizations**:
  1. Fix Logger Mutex Contention (Fixed)
  2. Pre-allocate buffer during ADPCM decompression (Fixed)
  3. Optimize plugin discovery logic to avoid redundant disk I/O on initialization.

## Critical Path Issues
### Title: Logger Mutex Contention During String Formatting
- **Severity**: High
- **Category**: Concurrency and parallelism
- **Location**: `src/utils/logger.zig` (`pub fn log`)
- **Confidence**: Confirmed
- **Why it matters**: The `log` function acquires a mutex and then calls `std.fmt.bufPrint`. String formatting can be relatively slow, and holding a global mutex during this blocks all other threads attempting to log, leading to severe contention in multithreaded environments.
- **Evidence from the code**:
  ```zig
  mutex.lock();
  defer mutex.unlock();
  var buf: [1024]u8 = undefined;
  const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
  ```
- **Recommendation**: Move `std.fmt.bufPrint` before the mutex lock.
- **Expected benefit**: Increased throughput in multi-threaded contexts by reducing lock duration.
- **Estimated effort**: Low. (Fixed)

## Resource and Memory Issues
### Title: Unbounded Buffer Growth During ADPCM Decompression
- **Severity**: High
- **Category**: Memory usage
- **Location**: `src/api/digital.zig` (`AIL_decompress_ADPCM`)
- **Confidence**: Confirmed
- **Why it matters**: The ADPCM decompression routine was decoding into an `ArrayListUnmanaged(u8)` and dynamically resizing it. This leads to multiple memory reallocations and copies for large audio files.
- **Evidence from the code**:
  ```zig
  var pcm = std.ArrayListUnmanaged(u8){};
  while (true) {
      // ...
      pcm.appendSlice(openmiles.global_allocator.?, chunk_buf[0..fr]) catch break;
  }
  ```
- **Recommendation**: Call `ma_decoder_get_length_in_pcm_frames` before the loop and use `ensureTotalCapacity` to pre-allocate the memory.
- **Expected benefit**: Memory allocation efficiency, reduced GC pressure (if applicable), and faster load times.
- **Estimated effort**: Low. (Fixed)

### Title: Risk of Segfaults due to Unbounded Slice for Unknown Stream Sizes
- **Severity**: High
- **Category**: Resource management
- **Location**: `src/engine/digital.zig` (`Sample.loadFromUnownedMemoryUnknownSize`)
- **Confidence**: Potential
- **Why it matters**: If a file is not recognized as WAV, a hardcoded fallback size of 16MB is assumed (after `detectAudioSize` fails to determine the real size). If the buffer is smaller than 16MB, the decoder might read out of bounds, causing a segfault.
- **Recommendation**: Pass a custom IO callback structure to `ma_decoder_init` instead of relying on a hardcoded slice.
- **Expected benefit**: Reliability and memory safety.
- **Estimated effort**: Medium. (Fixed)
- **Resolution**: For formats with known header sizes (RIFF, FORM, MIDI), `detectAudioSize` determines the exact size. For streaming formats (MP3, OGG, FLAC), a new `loadFromBoundedPointer` method uses custom `ma_decoder_init` read/seek callbacks (`BoundedMemCtx`) that bounds-check all reads and return `MA_AT_END` if the cursor exceeds the limit — no unbounded Zig slice is created. The `load()` function now also delegates to `loadFromUnownedMemoryUnknownSize` when size ≤ 0 instead of blindly using the sentinel.

## I/O and Network Issues
### Title: Redundant Disk I/O on Plugin Loading
- **Severity**: Medium
- **Category**: I/O
- **Location**: `src/engine/digital.zig` (`DigitalDriver.loadAllAsi`)
- **Confidence**: Likely
- **Why it matters**: Iterating through a directory to load plugins occurs during the critical digital driver initialization path. This could add a few milliseconds of delay at startup.
- **Evidence from the code**:
  ```zig
  var d = fs_compat.openDir(redist_dir, .{ .iterate = true }) catch return;
  // ...
  while (it.next() catch null) |entry| {
  ```
- **Recommendation**: Cache plugin directory listings if called repeatedly, or lazy-load plugins only when requested by `AIL_open_stream`.
- **Expected benefit**: Faster startup time for applications creating multiple digital drivers.
- **Estimated effort**: Low.

## Scalability Concerns
### Title: O(N) Sample Count Loop
- **Severity**: Low
- **Category**: Algorithmic Complexity
- **Location**: `src/engine/digital.zig` (`DigitalDriver.getActiveSampleCount`)
- **Confidence**: Likely
- **Why it matters**: Calling `status()` on every sample iteratively in `getActiveSampleCount` is O(N). While N is typically low for audio samples, at a high scale, it might become an issue.
- **Evidence from the code**:
  ```zig
  for (self.samples.items) |s| {
      if (s.status() == .playing) count += 1;
  }
  ```
- **Recommendation**: Maintain a running `active_sample_count` variable that is incremented on `start()` and decremented on `stop()` or when the EOS callback is hit.
- **Expected benefit**: O(1) query time for active samples.
- **Estimated effort**: Medium (requires thread-safe atomic integer or careful synchronization).

## Quick Wins
- ✅ **Logger Mutex Contention**: String formatting was moved out of the critical section.
- ✅ **ADPCM Pre-allocation**: Handled with `ensureTotalCapacity`.
- ✅ **Unbounded Slice Safety**: Streaming formats now use bounded decoder callbacks instead of 16MB slices.

## Optimization Plan
1. **Immediate fixes (high impact, low risk)**:
   - Logger string formatting out of mutex (Done).
   - Pre-allocate memory during ADPCM decoding (Done).
2. **Short-term optimizations**:
   - Refactor `loadFromUnownedMemoryUnknownSize` to avoid relying on hardcoded sizes for OGG/MP3 files. (Done)
3. **Medium-term improvements**:
   - Implement O(1) active sample counting.
4. **Long-term architectural changes**:
   - Implement streaming for large memory files rather than decoding entirely to memory where applicable.

## Measurement Recommendations
- **Metrics to track**: Application startup time, time spent in `AIL_decompress_ADPCM`, lock contention time in `log()`.
- **Suggested profiling**: Use a profiler to measure the impact of `log` when it's heavily spammed.
- **Baseline measurements**: Compare start times of `AIL_startup` before and after any changes to `loadAllAsi`.

## Build & Runtime Notes
- **Debug/ReleaseSafe builds stack-overflow on Wine** (WOW64 i386). The Zig runtime's TLS and stack-check code exceeds Wine's default 1MB thread stack for 32-bit guests. Use `ReleaseSmall` for game testing.
- Europa 1400 Gold TL confirmed working under Wine 11.6 with ReleaseSmall. Startup, MP3 streaming, WAV sample playback, and multiple digital driver instances all function correctly.

## Open Questions
- ~~Do any game clients legitimately pass tiny memory streams of OGG/MP3 to `AIL_open_stream` where the 16MB slice would segfault?~~ **Resolved:** Bounded decoder callbacks now handle this safely.
- Should the build system default to `ReleaseSmall` for the Windows cross-compile target?
