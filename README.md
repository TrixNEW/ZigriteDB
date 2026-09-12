# ZigiteDB

An embedded storage engine for Quark world and chunk data, written in [Zig](https://github.com/ziglang/zig) v0.16.0.

Early development. The current implementation provides binary chunk-component
keys and region mapping. Persistent storage is not yet implemented.

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
