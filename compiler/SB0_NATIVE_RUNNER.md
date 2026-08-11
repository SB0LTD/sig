# Native SB0 Compiler Runner

Sig 0.3.2 publishes `sig-aarch64-sb0-runner.sb0k`: an allocator-free compiler
service for the consolidated `aarch64-sb0` target. The release gate boots the
same bytes that are published and requires the service to compile `.sig`
source to an SB0X image inside the guest.

The runner, compiler entry point, request encoder, and response extractor are
all strict `.sig` programs. Their variable-size state is caller-owned or fixed
capacity. No allocator is initialized and no Python program participates in
the protocol.

## Fixed boot contract

- SB0K load address: `0x40200000`
- SB0K v1 header size: 64 bytes
- reset entry: `load address + 64`
- SB0C handoff address: `0x41000000`
- maximum source size: 64 KiB
- maximum release artifact file size: 64 KiB
- response transport in the QEMU gate: PL011 at `0x09000000`
- successful compiler output: SB0X

Nexus may replace the QEMU loader and UART transport with its native boot and
capability transport. The SB0C/SB0R payload framing remains independent of
that transport.

## Wire format

All integers are little-endian.

An SB0C request is a ten-byte header followed immediately by `source_len`
source bytes:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | `SB0C` magic |
| 4 | 2 | protocol version, currently 1 |
| 6 | 4 | source length |
| 10 | variable | `.sig` source bytes |

An SB0R response is a sixteen-byte header followed by `output_len` bytes when
the status is zero:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | `SB0R` magic |
| 4 | 2 | protocol version, currently 1 |
| 6 | 2 | status; zero is success |
| 8 | 4 | output length |
| 12 | 4 | compiler error count |
| 16 | variable | SB0X bytes |

The service rejects bad magic, unsupported versions, empty input, input over
64 KiB, compilation errors, and output without the native `SB0X` magic.

## Reproduce the complete gate

From a Sig source checkout on an x86_64 Linux host with
`qemu-system-aarch64` installed:

```sh
SB0_RUNNER_OUTPUT="$PWD/sig-aarch64-sb0-runner.sb0k" \
  bash ci/test-sb0-runner.sh "$(command -v sig)" "$PWD"
```

The gate builds the SB0K service with `-target aarch64-sb0`, validates every
header field, enforces the 64 KiB artifact ceiling, and rejects foreign-format
markers. It boots a minimal native probe and then the compiler service. It
compiles these two host-side protocol tools from strict Sig source:

```sh
sig build-exe ci/sb0_runner_request.sig \
  -target x86_64-linux-musl --zig-lib-dir lib \
  -femit-bin=sb0-runner-request
sig build-exe ci/sb0_runner_client.sig \
  -target x86_64-linux-musl --zig-lib-dir lib \
  -femit-bin=sb0-runner-client

sb0-runner-request input.sig > request.sb0c
sb0-runner-client output.sb0x < response.sb0r
```

The first command reads at most 64 KiB from `input.sig` into static storage.
The second validates the complete response before creating `output.sb0x`.
