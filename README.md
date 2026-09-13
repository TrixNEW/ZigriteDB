# ZigiteDB

An embedded storage engine for Minecraft Bedrock world and chunk data, written in [Zig](https://github.com/ziglang/zig) v0.16.0.
A modern and lightning fast replacement of PMMP's [LevelDB](https://github.com/pmmp/leveldb)

## This is currently a WIP, and not yet ready for production use.
- This project was made entirely to test an idea I had
- I can't guarentee this project will be maintained; ⭐'s are appreciated!
- This code can be used in many different languages using [C ABI](https://gist.github.com/MangaD/506a0f3273724ef3af26b8c085accdcb)
- I know this is gonna be skidded so at least give credit where credit is due :)

## Requirements

- Zig 0.16.0

## Build

```sh
zig build
```

## Test

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
```

## Similar/Useful Projects (feel free to ⭐)
- [zig-protocol](https://github.com/Bedrock-Phanatics/zig-protocol) - A protocol library for Minecraft Bedrock written in Zig
- [Quark](https://github.com/Bedrock-Phanatics/Quark) - A server software for Minecraft Bedrock written in PHP (utilizing a Zig Runtime), which ZigriteDB was created for.
- [zig-nbt](https://github.com/Bedrock-Phanatics/zig-nbt) - A NBT library for Minecraft Bedrock written in Zig

## License

See [LICENSE](LICENSE).
