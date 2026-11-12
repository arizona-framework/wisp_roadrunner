# wisp_roadrunner

[![CI](https://github.com/arizona-framework/wisp_roadrunner/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/arizona-framework/wisp_roadrunner/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/wisp_roadrunner.svg)](https://hex.pm/packages/wisp_roadrunner)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/wisp_roadrunner/)
[![License](https://img.shields.io/hexpm/l/wisp_roadrunner.svg)](https://github.com/arizona-framework/wisp_roadrunner/blob/main/LICENSE.md)

Run [Wisp](https://hexdocs.pm/wisp) apps on
[Roadrunner](https://github.com/arizona-framework/roadrunner), the
pure-Erlang HTTP/1.1, HTTP/2, HTTP/3 and WebSocket server, through
[roadrunner_gleam](https://github.com/arizona-framework/roadrunner_gleam).

## Requirements

Requires **OTP 27+** and **Gleam 1.19+**, with `rebar3` installed to build
Roadrunner.

## 🚧 Status

wisp_roadrunner is in `0.x`. The core is functional and covered by tests,
but the API may change between minor versions. Pin an exact version in your
deps if you need stability across upgrades.

## Installation

```sh
gleam add wisp_roadrunner roadrunner_gleam
```

## Usage

Swap `wisp_mist` for `wisp_roadrunner` and start a roadrunner_gleam
listener; the Wisp app stays the same.

```gleam
import gleam/erlang/process
import roadrunner_gleam
import wisp
import wisp_roadrunner

pub fn main() {
  let secret_key_base = wisp.random_string(64)
  let assert Ok(_) =
    wisp_roadrunner.handler(handle_request, secret_key_base)
    |> roadrunner_gleam.new
    |> roadrunner_gleam.read_body_on_demand
    |> roadrunner_gleam.port(8000)
    |> roadrunner_gleam.start
  process.sleep_forever()
}

fn handle_request(_request: wisp.Request) -> wisp.Response {
  wisp.ok() |> wisp.string_body("hello, roadrunner!")
}
```

`read_body_on_demand` lets Wisp read request bodies in pieces, as it asks
for them, so its body size limits hold before a large upload is read. TLS,
HTTP/2, HTTP/3 and the other listener options come from roadrunner_gleam.

## WebSockets and server-sent events

Wisp has no API for these, but roadrunner_gleam does. Route their paths to
its [`websocket`](https://hexdocs.pm/roadrunner_gleam/roadrunner_gleam/websocket.html)
and [`push`](https://hexdocs.pm/roadrunner_gleam/roadrunner_gleam/push.html)
modules and hand the rest to Wisp:

```gleam
let wisp_handler = wisp_roadrunner.handler(handle_request, secret_key_base)

fn(request) {
  case request.path_segments(request) {
    ["ws"] -> websocket.new(on_init:, handler:) |> websocket.upgrade
    _ -> wisp_handler(request)
  }
}
|> roadrunner_gleam.new
```

## Features

- Wisp handlers on HTTP/1.1, HTTP/2 and HTTP/3
- Request bodies read in pieces of Wisp's `read_chunk_size`, with its
  `max_body_size` and `max_files_size` limits
- Forms, multipart uploads, and Wisp's temporary files deleted after each
  request
- Text, bytes and file responses, file ranges included, sent by the kernel
- Signed and encrypted cookies, and `serve_static`
- WebSockets and server-sent events next to a Wisp app, on the same
  listener

## Sponsors

wisp_roadrunner is open source and maintained on personal time. If you or your company find it useful,
consider [sponsoring](https://github.com/sponsors/williamthome).

I also accept coffees ☕

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/williamthome)

<a href="https://github.com/sponsors/williamthome">
  <img
    src="https://raw.githubusercontent.com/williamthome/williamthome/sponsorkit/sponsors.svg"
    alt="Sponsors"
  />
</a>

## License

Copyright (c) 2026 [William Fank Thomé](https://github.com/williamthome)

wisp_roadrunner is open-source under the Apache 2.0 License on
[GitHub](https://github.com/arizona-framework/wisp_roadrunner).

See [LICENSE.md](https://github.com/arizona-framework/wisp_roadrunner/blob/main/LICENSE.md) for more information.
