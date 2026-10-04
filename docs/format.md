# Disk format 2

All integers are little-endian. Reserved fields must be zero. Format 1 worlds are
detected and refused with `NeedsMigration`; `zigrite migrate` converts them into a new
directory without touching the original. Newer versions are refused as unsupported.

## World layout

```
world/
  ZIGRITE                       "ZGWD", u16 version 2, u16 zero, CRC-32C of bytes 0..8
  dddddddd-xxxxxxxx-zzzzzzzz.region/
    MANIFEST                    authoritative segment list
    GGGGGGGGGGGGGGGG-IIIIIIIIIIIIIIII.segment
    INDEX                       optional index checkpoint
```

Region names are the dimension, region X and region Z as 32-bit two's complement hex.
A region holds 32x32 chunks; region coordinates use floor division by 32.

## Keys

A key is a chunk position, a component and, for subchunks only, a signed Y byte.
Components are Bedrock's chunk record tags (`0x2b` Data3D, `0x2c` Version,
`0x2f` SubChunkPrefix, `0x31` BlockEntity, `0x32` Entity, ...). Any byte is accepted, so
future tags need no format change. Tags from `0x80` up are reserved for Zigrite;
`0x80` holds Bedrock's per-chunk `digp` record.

Inside a region a key is stored as a 10-bit slot (`z * 32 + x`, both local) and a 16-bit
local key: the tag in the high byte and the Y byte in the low byte.

## Auxiliary keys

Keys that are not chunk records, such as players, maps, scoreboards, actors and any
unknown Bedrock key, live in dimension -2147483648. A key's 64-bit Wyhash picks one of
16 regions, a slot and one of 64 component tags; that record holds every key hashing
there as `u32 key length, key, u32 value length, value`, sorted by key.

## Bedrock conversion

`zigrite import` reads a Bedrock world's LevelDB (tables, MANIFEST and unflushed logs,
newest version per key) without changing it. Keys in Bedrock's exact chunk layout become
chunk components with their bytes unchanged, `digp` included; everything else goes to the
auxiliary keys as-is. Other world files such as `level.dat` are copied to `bedrock/`.
`zigrite export` writes them back with sorted LevelDB tables, a MANIFEST and CURRENT, so the
result opens in Bedrock and PMMP without Zigrite. Both build the output under a temporary
name and rename it into place only once complete and synced.

## Segments

A segment starts with a 48-byte header: `ZGSG`, u16 version 2 at 4, u16 zero at 6,
segment ID u64 at 8, generation u64 at 16, region dimension/X/Z i32 at 24/28/32,
region salt u64 at 36, CRC-32C of bytes 0..44 at 44. Frames follow without padding.
The salt is random per region and shared by all its segments.

## Frames

A frame is one atomic batch from one region:

| Offset | Field |
| ---: | --- |
| 0 | u32 body length |
| 4 | u16 record count, 1..4096 |
| 6 | u8 kind: 1 batch, 2 compacted base |
| 7 | u8 zero |
| 8 | u64 batch ID, non-zero |
| 16 | u32 CRC-32C of the records' own checksums, in order |
| 20 | u32 CRC-32C of the region salt (8 bytes) followed by bytes 0..20 |

The body is the records back to back, at most 64 MiB.

A frame counts only if its header checksum matches with this region's salt, the body is
complete, every record checksum matches, the records fill the body exactly, and the
checksum of their checksums matches. Torn writes, partial batches, reordered records and
stale frames left in reused blocks by other regions all fail one of these checks. No
cryptographic hash is needed: every byte is covered by exactly one record CRC, and the
frame CRC binds the records, their order and their count.

Batch IDs strictly increase within a region. Base frames, written by compaction, all
carry the generation's base batch ID from the manifest and may only appear before the
first ordinary frame.

## Records

| Offset | Field |
| ---: | --- |
| 0 | u16: bits 0-9 slot, bit 10 delete, bits 11-12 compression (0 raw, 1 LZ4), rest zero |
| 2 | u8 component tag |
| 3 | i8 subchunk Y; zero for every other tag |
| 4 | u32 stored length |
| 8 | u32 raw length |
| 12 | stored bytes |
| 12 + stored | u32 CRC-32C of the header and stored bytes |

Records add 16 bytes to their value (format 1 added 53). Deletes have no value.
An LZ4 value is an independent block, used only when smaller than raw. Values are
bounded to 16 MiB.

## Manifest

A 64-byte header: `ZGMF`, u16 version 2 at 4, u16 zero at 6, generation u64 at 8,
region dimension/X/Z at 16/20/24, segment count u32 at 28, active segment ID u64 at 32,
base batch ID u64 at 40, region salt u64 at 48, zero u32 at 56, CRC-32C of bytes 0..60 at 60.
Sorted segment IDs follow as u64, then CRC-32C of everything before. The last segment is
active. At most 4096 IDs are accepted.

The manifest is published by writing `MANIFEST.tmp`, syncing it and the directory,
renaming it over `MANIFEST`, then syncing the directory again. Segments are synced before
they are named in a manifest.

## Index checkpoint

`INDEX` is an optional snapshot of a region's index, written on clean close with no
fsync of its own. It only ever describes data the close had already synced.

A 64-byte header: `ZGIX`, u16 version 1, u16 flags (bit 0: fingerprints present),
generation u64 at 8, salt u64 at 16, covered segment count u32 at 24, entry count u32
at 28, covered offset in the last covered segment u64 at 32, last batch ID u64 at 40,
total bytes u64 at 48, u8 seen-batch flag at 56, zero to 60, CRC-32C of 0..60 at 60.
Then the covered segment IDs (u64), 1024 per-slot entry counts (u16), the entries in
slot and key order (24 bytes each, 28 with fingerprints: local key u16, segment u8,
compression u8, offset u32, stored length u32, raw length u32, batch ID u64, fingerprint
u32), and a CRC-32C of everything after the header.

A checkpoint is used only if every check passes: checksums, version, generation, salt,
segment IDs as a prefix of the manifest, every entry inside the covered bytes, sorted
keys, counts and limits. Otherwise it is ignored and the region is replayed from its
segments, which stay authoritative. Frames after the covered offset are always replayed
with full verification. When the checkpoint ends exactly at the active segment's end,
open skips the directory and segment fsyncs it would otherwise do to make a crashed
writer's state durable.

## Recovery

Open replays committed frames. Anything unreadable at the end of the active segment —
a cut, zeros or garbage — is treated as a torn tail and requires explicit recovery into
an empty directory (`zg_recover_region`), which copies every verified frame and leaves
the source untouched. Damage in a sealed segment is corruption. Segments of the next
generation (an unfinished compaction) and segments newer than the manifest's active one
(an unfinished rotation) are deleted on open; neither can be named by a manifest.

## Compaction

Compaction snapshots the index, copies live records in chunk order into base frames of a
new generation, verifying each record against the index, then copies frames written
meanwhile, verified, after them. Writers only wait for the final tail copy, its fsync and
the manifest swap. The old generation is removed once its readers finish. A failed
publication keeps both generations on disk and stops writes, since the manifest may name
either.

## Durability

Sync writes and save groups acknowledge only after fsync, shared by concurrent writers.
Buffered writes are durable after the next successful flush or close. A failed write,
fsync, rotation or publication stops the region's writer.
