# ZigiteDB

An embedded storage engine for Minecraft Bedrock world and chunk data, written in [Zig](https://github.com/ziglang/zig) v0.16.0.

A modern, lightweight, and high-performance alternative to PMMP's [LevelDB](https://github.com/pmmp/leveldb).

> [!WARNING]
> **ZigiteDB is currently a work in progress and is not ready for production use.**

* This project was created primarily to experiment with an idea I had for improving Minecraft world and chunk storage.
* The API and on-disk format may change while the project is still in development.
* I can't guarantee that this project will be maintained long-term, so ⭐ stars are appreciated if you'd like to see continued development.
* ZigiteDB can be integrated into other languages through its [C ABI](https://gist.github.com/MangaD/506a0f3273724ef3af26b8c085accdcb).
* If you use or build upon this project, credit is appreciated. :)

## Requirements

* [Zig](https://ziglang.org/) 0.16.0

## Build

```sh
zig build
```

For an optimized release build:

```sh
zig build -Doptimize=ReleaseFast
```

## Tests

Run the test suite:

```sh
zig build test
```

Run tests with safety checks enabled:

```sh
zig build test -Doptimize=ReleaseSafe
```

## Related Projects

Other projects in the Bedrock-Phanatics ecosystem:

* [zig-protocol](https://github.com/Bedrock-Phanatics/zig-protocol) — A Minecraft Bedrock protocol library written in Zig.
* [Quark](https://github.com/Bedrock-Phanatics/Quark) — Minecraft Bedrock server software written in PHP and utilizing a Zig runtime. ZigiteDB was originally created for Quark.
* [zig-nbt](https://github.com/Bedrock-Phanatics/zig-nbt) — An NBT library for Minecraft Bedrock written in Zig.

Feel free to ⭐ any of the projects if you find them useful.

## License

See [LICENSE](LICENSE).
