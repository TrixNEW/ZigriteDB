<p align="center">
  <img src="zigritedb_smaller.png" alt="ZigriteDB" width="420">
</p>

<h1 align="center">ZigriteDB</h1>

<p align="center">
  An embedded storage engine for Minecraft Bedrock world and chunk data, written in <a href="https://github.com/ziglang/zig">Zig</a> v0.16.0.
</p>

<p align="center">
  A modern, lightweight, and high-performance alternative to PMMP's <a href="https://github.com/pmmp/leveldb">LevelDB</a>.
</p>

> [!WARNING]
> **ZigriteDB is currently a work in progress and is not ready for production use.**

* This project was created primarily to experiment with an idea I had for improving Minecraft world and chunk storage.
* The API and on-disk format may change while the project is still in development.
* I can't guarantee that this project will be maintained long-term, so ⭐ stars are appreciated if you'd like to see continued development.
* ZigriteDB can be integrated into other languages through its [C ABI](https://gist.github.com/MangaD/506a0f3273724ef3af26b8c085accdcb).
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
* [Quark](https://github.com/Bedrock-Phanatics/Quark) — Minecraft Bedrock server software written in PHP and utilizing a Zig runtime. ZigriteDB was originally created for Quark.
* [zig-nbt](https://github.com/Bedrock-Phanatics/zig-nbt) — An NBT library for Minecraft Bedrock written in Zig.

Feel free to ⭐ any of the projects if you find them useful.

## License

See [LICENSE](LICENSE).
