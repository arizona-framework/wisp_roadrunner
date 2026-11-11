import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gleam/string
import gleeunit
import roadrunner_gleam.{type Builder}
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
