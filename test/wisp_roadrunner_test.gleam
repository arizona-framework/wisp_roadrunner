import gleam/bytes_tree
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/http
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/string
import gleeunit
import roadrunner_gleam.{type Builder}
import roadrunner_gleam/push
import roadrunner_gleam/request as rr_request
import roadrunner_gleam/websocket
import wisp
import wisp_roadrunner

pub fn main() -> Nil {
  silence_logger()
  gleeunit.main()
}

// --- helpers --------------------------------------------------------

const secret = "test-secret-key-base-that-is-long-enough-for-wisp-signing"

fn serve(
  name: String,
  handler: fn(wisp.Request) -> wisp.Response,
  test_body: fn(String) -> a,
) -> a {
  wisp_roadrunner.handler(handler, secret)
  |> roadrunner_gleam.new
  |> roadrunner_gleam.read_body_on_demand
  |> start(name, test_body)
}

fn start(builder: Builder, name: String, test_body: fn(String) -> a) -> a {
  let assert Ok(actor.Started(data: listener, ..)) =
    builder
    |> roadrunner_gleam.port(0)
    |> roadrunner_gleam.bind("127.0.0.1")
    |> roadrunner_gleam.name(name)
    |> roadrunner_gleam.start
  let port = roadrunner_gleam.listener_port(listener)
  let result = test_body("http://127.0.0.1:" <> int.to_string(port))
  roadrunner_gleam.stop(listener)
  result
}

fn call(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> #(Int, List(#(String, String)), BitArray) {
  http_call(atom.create(method), url, headers, body)
}

@external(erlang, "wisp_roadrunner_test_ffi", "request")
fn http_call(
  method: Atom,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> #(Int, List(#(String, String)), BitArray)

@external(erlang, "wisp_roadrunner_test_ffi", "silence_logger")
fn silence_logger() -> Nil

@external(erlang, "wisp_roadrunner_test_ffi", "is_file")
fn is_file(path: String) -> Bool

// --- tests ----------------------------------------------------------

pub fn text_test() {
  use url <- serve("wr_text", fn(_) {
    wisp.ok() |> wisp.string_body("hello, wisp!")
  })
  let #(status, _, body) = call("get", url, [], <<>>)
  assert status == 200
  assert body == <<"hello, wisp!">>
}

pub fn method_and_path_test() {
  use url <- serve("wr_method_path", fn(req) {
    wisp.ok()
    |> wisp.string_body(
      http.method_to_string(req.method)
      <> " "
      <> string.join(wisp.path_segments(req), "/"),
    )
  })
  let #(_, _, body) = call("put", url <> "/a/b", [], <<"x">>)
  assert body == <<"PUT a/b">>
}

fn echo_string(req: wisp.Request) -> wisp.Response {
  use text <- wisp.require_string_body(req)
  wisp.ok() |> wisp.string_body(text)
}

pub fn string_body_test() {
  use url <- serve("wr_string_body", echo_string)
  let #(status, _, body) = call("post", url, [], <<"some text">>)
  assert status == 200
  assert body == <<"some text">>
}

// Wisp reads the body in pieces of its `read_chunk_size`: a body larger
// than one piece must come through whole.
pub fn body_in_pieces_test() {
  use url <- serve("wr_pieces", fn(req) {
    req
    |> wisp.set_read_chunk_size(7)
    |> echo_string
  })
  let text = string.repeat("0123456789", 10)
  let #(_, _, body) = call("post", url, [], <<text:utf8>>)
  assert body == <<text:utf8>>
}

// The same on a listener that reads bodies before the handler.
pub fn body_read_before_handler_test() {
  let builder =
    wisp_roadrunner.handler(echo_string, secret)
    |> roadrunner_gleam.new
  use url <- start(builder, "wr_auto_body")
  let #(_, _, body) = call("post", url, [], <<"read first">>)
  assert body == <<"read first">>
}

pub fn body_too_large_test() {
  use url <- serve("wr_too_large", fn(req) {
    req
    |> wisp.set_max_body_size(4)
    |> echo_string
  })
  let #(status, _, _) = call("post", url, [], <<"too long">>)
  assert status == 413
}

pub fn form_test() {
  use url <- serve("wr_form", fn(req) {
    use form <- wisp.require_form(req)
    let assert Ok(name) = list.key_find(form.values, "name")
    wisp.ok() |> wisp.string_body("hi " <> name)
  })
  let #(_, _, body) =
    call("post", url, [#("content-type", "application/x-www-form-urlencoded")], <<
      "name=gleam+user",
    >>)
  assert body == <<"hi gleam user">>
}

pub fn multipart_upload_test() {
  let self = process.new_subject()
  use url <- serve("wr_upload", fn(req) {
    use form <- wisp.require_form(req)
    let assert [#("file", upload)] = form.files
    process.send(self, upload.path)
    let assert Ok(contents) = read_file(upload.path)
    wisp.ok() |> wisp.string_body(upload.file_name <> ":" <> contents)
  })
  let boundary = "XyZboundary"
  let body =
    "--"
    <> boundary
    <> "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n"
    <> "content-type: text/plain\r\n\r\nfile contents\r\n--"
    <> boundary
    <> "--\r\n"
  let #(status, _, response) =
    call(
      "post",
      url,
      [#("content-type", "multipart/form-data; boundary=" <> boundary)],
      <<body:utf8>>,
    )
  assert status == 200
  assert response == <<"a.txt:file contents">>
  // Wisp's temporary files are gone once the request is handled.
  let assert Ok(path) = process.receive(self, 1000)
  assert !is_file(path)
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(String, Nil)

pub fn file_test() {
  use url <- serve("wr_file", fn(_) {
    wisp.ok() |> wisp.file_download(named: "gleam.toml", from: "gleam.toml")
  })
  let #(status, headers, body) = call("get", url, [], <<>>)
  let assert Ok(contents) = read_file("gleam.toml")
  assert status == 200
  assert body == <<contents:utf8>>
  assert list.key_find(headers, "content-disposition")
    == Ok("attachment; filename=\"gleam.toml\"")
}

pub fn file_range_test() {
  use url <- serve("wr_file_range", fn(_) {
    wisp.ok()
    |> wisp.set_body(wisp.File(path: "gleam.toml", offset: 7, limit: Some(17)))
  })
  let #(_, _, body) = call("get", url, [], <<>>)
  assert body == <<"\"wisp_roadrunner\"">>
}

pub fn missing_file_test() {
  use url <- serve("wr_missing_file", fn(_) {
    wisp.ok() |> wisp.file_download(named: "x", from: "does/not/exist")
  })
  let #(status, _, _) = call("get", url, [], <<>>)
  assert status == 500
}

pub fn signed_cookie_test() {
  use url <- serve("wr_cookie", fn(req) {
    case wisp.get_cookie(req, "session", wisp.Signed) {
      Ok(value) -> wisp.ok() |> wisp.string_body("got " <> value)
      Error(Nil) ->
        wisp.ok()
        |> wisp.set_cookie(req, "session", "abc", wisp.Signed, 60)
        |> wisp.string_body("set")
    }
  })
  let #(_, headers, body) = call("get", url, [], <<>>)
  assert body == <<"set">>
  let assert Ok(set_cookie) = list.key_find(headers, "set-cookie")
  let assert [cookie, ..] = string.split(set_cookie, ";")
  let #(_, _, body) = call("get", url, [#("cookie", cookie)], <<>>)
  assert body == <<"got abc">>
}

pub fn serve_static_test() {
  use url <- serve("wr_static", fn(req) {
    use <- wisp.serve_static(req, under: "/static", from: "src")
    wisp.not_found()
  })
  let #(status, headers, body) =
    call("get", url <> "/static/wisp_roadrunner.gleam", [], <<>>)
  let assert Ok(contents) = read_file("src/wisp_roadrunner.gleam")
  assert status == 200
  assert body == <<contents:utf8>>
  let assert Ok(_) = list.key_find(headers, "content-type")
  let #(status, _, _) = call("get", url <> "/static/nope.txt", [], <<>>)
  assert status == 404
}

// Server-sent events come from roadrunner_gleam, routed before the rest
// reach Wisp on the same listener.
pub fn push_next_to_wisp_test() {
  let wisp_handler =
    wisp_roadrunner.handler(
      fn(_) { wisp.ok() |> wisp.string_body("from wisp") },
      secret,
    )
  let builder =
    fn(request) {
      case rr_request.path_segments(request) {
        ["events"] ->
          push.new(
            on_init: fn(subject) {
              process.send(subject, "hello")
              push.continue(Nil)
            },
            handler: fn(state, message) {
              case message {
                push.Custom(text) ->
                  push.stop(state) |> push.send_event(push.event(text))
                push.Draining(_) -> push.stop(state)
              }
            },
          )
          |> push.response(200)
          |> http_response.set_header("content-type", "text/event-stream")
        _ -> wisp_handler(request)
      }
    }
    |> roadrunner_gleam.new
    |> roadrunner_gleam.read_body_on_demand
  use url <- start(builder, "wr_push")
  let #(status, headers, body) = call("get", url <> "/events", [], <<>>)
  assert status == 200
  assert list.key_find(headers, "content-type") == Ok("text/event-stream")
  assert body == <<"data: hello\n\n">>
  let #(status, _, body) = call("get", url <> "/other", [], <<>>)
  assert status == 200
  assert body == <<"from wisp">>
}

pub fn bytes_body_test() {
  use url <- serve("wr_bytes", fn(_) {
    wisp.ok()
    |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(<<0, 1, 255>>)))
  })
  let #(status, _, body) = call("get", url, [], <<>>)
  assert status == 200
  assert body == <<0, 1, 255>>
}

// A limit past the end of the file sends the rest of it.
pub fn file_limit_past_end_test() {
  use url <- serve("wr_file_limit", fn(_) {
    wisp.ok()
    |> wisp.set_body(wisp.File(
      path: "gleam.toml",
      offset: 7,
      limit: Some(1_000_000),
    ))
  })
  let #(status, _, body) = call("get", url, [], <<>>)
  let assert Ok(contents) = read_file("gleam.toml")
  assert status == 200
  assert <<"name = ", body:bits>> == <<contents:utf8>>
}

pub fn file_offset_past_end_test() {
  use url <- serve("wr_file_offset", fn(_) {
    wisp.ok()
    |> wisp.set_body(wisp.File(
      path: "gleam.toml",
      offset: 1_000_000,
      limit: option.None,
    ))
  })
  let #(status, _, _) = call("get", url, [], <<>>)
  assert status == 500
}

fn upload_body(boundary: String) -> BitArray {
  let body =
    "--"
    <> boundary
    <> "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n"
    <> "content-type: text/plain\r\n\r\nfile contents\r\n--"
    <> boundary
    <> "--\r\n"
  <<body:utf8>>
}

pub fn files_too_large_test() {
  use url <- serve("wr_files_too_large", fn(req) {
    use _ <- wisp.require_form(wisp.set_max_files_size(req, 4))
    wisp.ok()
  })
  let #(status, _, _) =
    call(
      "post",
      url,
      [#("content-type", "multipart/form-data; boundary=b0undary")],
      upload_body("b0undary"),
    )
  assert status == 413
}

// Wisp's temporary files are deleted even when the handler crashes.
pub fn temporary_files_deleted_on_crash_test() {
  let self = process.new_subject()
  use url <- serve("wr_crash", fn(req) {
    use form <- wisp.require_form(req)
    let assert [#("file", upload)] = form.files
    process.send(self, upload.path)
    panic as "handler crashed"
  })
  let #(status, _, _) =
    call(
      "post",
      url,
      [#("content-type", "multipart/form-data; boundary=b0undary")],
      upload_body("b0undary"),
    )
  assert status == 500
  let assert Ok(path) = process.receive(self, 1000)
  assert !is_file(path)
}

// A client that goes away halfway through the body: Wisp's read fails
// instead of hanging or crashing.
pub fn body_cut_short_test() {
  let self = process.new_subject()
  use url <- serve("wr_cut_short", fn(req) {
    process.send(self, wisp.read_body_bits(req))
    wisp.ok()
  })
  truncated_post(port_of(url), "/", 100, 10)
  assert process.receive(self, 5000) == Ok(Error(Nil))
}

// WebSockets come from roadrunner_gleam, routed before the rest reach Wisp
// on the same listener.
pub fn websocket_next_to_wisp_test() {
  let wisp_handler =
    wisp_roadrunner.handler(
      fn(_) { wisp.ok() |> wisp.string_body("from wisp") },
      secret,
    )
  let builder =
    fn(request) {
      case rr_request.path_segments(request) {
        ["ws"] ->
          websocket.new(
            on_init: fn(_subject) { websocket.continue(Nil) },
            handler: fn(state, message) {
              case message {
                websocket.Text(text) ->
                  websocket.continue(state)
                  |> websocket.send([websocket.TextFrame("echo " <> text)])
                _ -> websocket.continue(state)
              }
            },
          )
          |> websocket.upgrade
        _ -> wisp_handler(request)
      }
    }
    |> roadrunner_gleam.new
    |> roadrunner_gleam.read_body_on_demand
  use url <- start(builder, "wr_websocket")
  assert websocket_echo(port_of(url), "/ws", "hi") == #(101, <<"echo hi">>)
  let #(status, _, body) = call("get", url <> "/other", [], <<>>)
  assert status == 200
  assert body == <<"from wisp">>
}

fn port_of(url: String) -> Int {
  let assert Ok(#(_, port)) = string.split_once(url, "127.0.0.1:")
  let assert Ok(port) = int.parse(port)
  port
}

@external(erlang, "wisp_roadrunner_test_ffi", "websocket_echo")
fn websocket_echo(port: Int, path: String, text: String) -> #(Int, BitArray)

@external(erlang, "wisp_roadrunner_test_ffi", "truncated_post")
fn truncated_post(port: Int, path: String, declared: Int, sent: Int) -> Nil
