# ZigiteDB

An embedded storage engine for Quark world and chunk data, written in [Zig](https://github.com/ziglang/zig) v0.16.0.

**This is currently a WIP, and not yet ready for production use.**
- This project was made entirely to test an idea I had
- I can't guarentee this project will be maintained
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

## License

See [LICENSE](LICENSE).
