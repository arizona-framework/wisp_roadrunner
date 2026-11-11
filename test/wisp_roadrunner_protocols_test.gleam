//// The same Wisp app over HTTP/2 and HTTP/3, through curl (and quiche in
//// Docker with `ROADRUNNER_GLEAM_H3_CLIENT=docker`).

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string
import roadrunner_gleam
import wisp
import wisp_roadrunner

type Protocol {
  H2
  H3
}

fn handle(req: wisp.Request) -> wisp.Response {
  case wisp.path_segments(req) {
    ["echo"] -> {
      // Small pieces, so the body comes in several reads.
      let req = wisp.set_read_chunk_size(req, 3)
      use text <- wisp.require_string_body(req)
      wisp.ok() |> wisp.string_body(text)
    }
    ["file"] ->
      wisp.ok() |> wisp.file_download(named: "gleam.toml", from: "gleam.toml")
    _ -> wisp.not_found()
  }
}

/// A TLS listener on port 0 serving HTTP/1.1, HTTP/2 and HTTP/3, handing
/// the test its TCP port and the UDP port HTTP/3 got.
fn serve(name: String, test_body: fn(Int, Int) -> a) -> a {
  let #(certfile, keyfile) = write_cert("build/test_tls")
  let assert Ok(actor.Started(data: listener, ..)) =
    wisp_roadrunner.handler(handle, "test-secret-key-base-long-enough-to-sign")
    |> roadrunner_gleam.new
    |> roadrunner_gleam.read_body_on_demand
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name(name)
    |> roadrunner_gleam.tls(certfile:, keyfile:)
    |> roadrunner_gleam.http3
    |> roadrunner_gleam.start
  let assert Ok(quic_port) = roadrunner_gleam.listener_quic_port(listener)
  let result = test_body(roadrunner_gleam.listener_port(listener), quic_port)
  roadrunner_gleam.stop(listener)
  result
}

fn fetch(
  protocol: Protocol,
  port: Int,
  path: String,
  method: String,
  body: String,
) -> String {
  case protocol {
    H2 -> {
      let url = "https://127.0.0.1:" <> int.to_string(port) <> path
      let data = case body {
        "" -> []
        _ -> ["--data-binary", body]
      }
      to_string(
        curl(list.flatten([["-s", "-k", "--http2", "-X", method], data, [url]])),
      )
    }
    H3 -> to_string(h3_request(port, path, method, <<body:utf8>>))
  }
}

fn to_string(data: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(data)
  text
}

@external(erlang, "wisp_roadrunner_test_ffi", "curl")
fn curl(args: List(String)) -> BitArray

@external(erlang, "wisp_roadrunner_test_ffi", "h3_request")
fn h3_request(
  port: Int,
  path: String,
  method: String,
  body: BitArray,
) -> BitArray

@external(erlang, "wisp_roadrunner_test_ffi", "write_cert")
fn write_cert(dir: String) -> #(String, String)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(String, Nil)

fn each_protocol(name: String, check: fn(Protocol, Int) -> Nil) -> Nil {
  use tcp_port, quic_port <- serve(name)
  check(H2, tcp_port)
  check(H3, quic_port)
}

pub fn body_in_pieces_test() {
  use protocol, port <- each_protocol("wr_proto_echo")
  let text = string.repeat("roadrunner", 20)
  assert fetch(protocol, port, "/echo", "POST", text) == text
}

pub fn file_test() {
  use protocol, port <- each_protocol("wr_proto_file")
  let assert Ok(contents) = read_file("gleam.toml")
  assert fetch(protocol, port, "/file", "GET", "") == contents
}
