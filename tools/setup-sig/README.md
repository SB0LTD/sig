# setup-sig

A GitHub Action (and Forgejo Action) that downloads and installs the [Sig](https://github.com/SB0LTD/sig) compiler for use in CI workflows.

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: SB0LTD/sig/tools/setup-sig@master
      - run: sig build test
```

### Pin a specific version

```yaml
      - uses: SB0LTD/sig/tools/setup-sig@master
        with:
          version: 0.3.1
```

### Auto-detect from manifest

When `version` is omitted, the action reads `minimum_sig_version` from
`build.sig.zon` (or `build.zig.zon`), falling back to the latest stable release.
An input such as `0.3.1` resolves to the newest stable immutable `0.3.1`
release identity, while a complete identity pins one exact release (including
a prerelease when explicitly requested).

### Matrix strategy

```yaml
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: SB0LTD/sig/tools/setup-sig@master
        with:
          cache-key: ${{ matrix.os }}
      - run: sig build test
```

### Custom mirror

```yaml
      - uses: ShadovvBeast/setup-sig@v1
        with:
          mirror: https://my-mirror.example.com/sig/releases
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | *(auto-detect)* | Full release identity, Sig semver such as `0.3.1`, `latest`, or empty for auto-detect |
| `mirror` | *(GitHub releases)* | Custom mirror base URL for downloading tarballs |
| `use-cache` | `true` | Cache the compiler tarball between workflow runs |
| `cache-key` | `""` | Additional cache key suffix for matrix disambiguation |
| `cache-size-limit` | `2048` | Max Sig global cache size in MiB before clearing (`0` to disable) |

## Supported platforms

| Runner | Architecture | Status |
|---|---|---|
| `ubuntu-latest` | x86_64 | Supported |
| `ubuntu-latest` (ARM) | aarch64 | Supported |
| `macos-latest` | aarch64 | Supported |
| `windows-latest` | x86_64 | Supported |

## How it works

1. Resolves the Sig version (explicit, from manifest, or latest release)
2. Downloads the platform-appropriate tarball from GitHub releases (or a custom mirror)
3. Verifies the archive against the release's aggregate `SHA256SUMS.txt` (with legacy lowercase support)
4. Extracts the compiler and adds it to `PATH`
5. Caches the tarball and Sig global cache directory for faster subsequent runs
6. Enforces a configurable size limit on the Sig cache directory

## License

Same license as the [Sig](https://github.com/SB0LTD/sig) project.
