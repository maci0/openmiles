//! Shared speaker routing table for v7/v8.
//! Both API versions map MSS_SPEAKER indices to driver channels via the same
//! table; extracting it here breaks the v7 -> v8 wrong-direction import.

/// MSS_SPEAKER enum max index (MSS_SPEAKER enum: FL=0 .. TBR=17)
pub const SPK_MAX_INDEX: usize = 17;
pub const SPK_X: i8 = -1;

/// output_speaker_index[logical_channels][MSS_SPEAKER] -> driver channel, or -1
/// (wavefile.cpp). MSS_SPEAKER: FL=0,FR=1,FC=2,LFE=3,BL=4,BR=5,FLC=6,FRC=7,
/// BC=8,SL=9,SR=10,TC=11,TFL=12,TFC=13,TFR=14,TBL=15,TBC=16,TBR=17 (MAX=17).
pub const output_speaker_index = [10][SPK_MAX_INDEX + 1]i8{
    .{ SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 0: invalid
    .{ 0, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 1: mono
    .{ 0, 1, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 2: stereo
    .{ 0, 1, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, 2, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 3: Dolby ProLogic
    .{ 0, 1, SPK_X, SPK_X, 2, 3, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 4: quad
    .{ 0, 1, 2, SPK_X, 3, 4, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 5: 5.0
    .{ 0, 1, 2, 3, 4, 5, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 6: 5.1
    .{ 0, 1, 2, 3, 4, 5, SPK_X, SPK_X, 6, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 7: 6.1
    .{ 0, 1, 2, 3, 4, 5, SPK_X, SPK_X, SPK_X, 6, 7, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 8: 7.1
    .{ 0, 1, 2, 3, 4, 5, SPK_X, SPK_X, 6, 7, 8, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X, SPK_X }, // 9: 8.1
};
