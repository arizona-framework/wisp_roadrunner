//// Run [Wisp](https://hexdocs.pm/wisp) apps on
//// [Roadrunner](https://github.com/arizona-framework/roadrunner).
////
//// ```gleam
//// import gleam/erlang/process
//// import roadrunner_gleam
//// import wisp
//// import wisp_roadrunner
////
//// pub fn main() {
////   let secret_key_base = wisp.random_string(64)
////   let assert Ok(_) =
////     wisp_roadrunner.handler(handle_request, secret_key_base)
////     |> roadrunner_gleam.new
////     |> roadrunner_gleam.read_body_on_demand
////     |> roadrunner_gleam.port(8000)
////     |> roadrunner_gleam.start
////   process.sleep_forever()
//// }
//// ```

import exception
import gleam/bytes_tree
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/option.{None, Some}
import gleam/string
import roadrunner_gleam/request.{type Request}
import roadrunner_gleam/response.{type Response}
import wisp
import wisp/internal

/// Turn a Wisp handler into one roadrunner_gleam runs.
///
/// Wisp reads request bodies in pieces as it needs them, up to its own
/// limits, so run the listener with `roadrunner_gleam.read_body_on_demand`:
/// otherwise roadrunner reads each body whole before the handler runs.
///
/// The secret key base signs and encrypts cookies. Use the same one each
/// time the app runs, and keep it secret.
pub fn handler(
  handler: fn(wisp.Request) -> wisp.Response,
  secret_key_base: String,
) -> fn(Request) -> Response {
  fn(request: Request) {
    let connection =
      internal.make_connection(body_reader(request), secret_key_base)
    let wisp_request =
      request.to_http(request)
      |> http_request.set_body(connection)

    use <- exception.defer(fn() {
      let _ = wisp.delete_temporary_files(wisp_request)
      Nil
    })

    wisp_request
    |> handler
    |> to_response
  }
}

// Wisp's reader asks for up to `size` bytes at a time, which is
// `request.read_chunk`'s contract.
fn body_reader(request: Request) -> internal.Reader {
  fn(size) {
    case request.read_chunk(request, size) {
      Ok(request.More(data, next)) ->
        Ok(internal.Chunk(data, body_reader(next)))
      Ok(request.Last(<<>>, _)) -> Ok(internal.ReadingFinished)
      Ok(request.Last(data, _)) -> Ok(internal.Chunk(data, finished))
      Error(_) -> Error(Nil)
    }
  }
}

fn finished(_size: Int) -> Result(internal.Read, Nil) {
  Ok(internal.ReadingFinished)
}

fn to_response(response: wisp.Response) -> Response {
  case response.body {
    wisp.Text(text) ->
      http_response.set_body(
        response,
        response.Bytes(bytes_tree.from_string(text)),
      )
    wisp.Bytes(bytes) -> http_response.set_body(response, response.Bytes(bytes))
    wisp.File(path:, offset:, limit:) ->
      case file_body(path, offset, limit) {
        Ok(body) -> http_response.set_body(response, body)
        Error(Nil) -> {
          wisp.log_error("cannot send file " <> string.inspect(path))
          response.new(500)
        }
      }
  }
}

// Wisp's `limit` is optional; roadrunner sends an exact range, so the
// length defaults to the rest of the file.
fn file_body(
  path: String,
  offset: Int,
  limit: option.Option(Int),
) -> Result(response.Body, Nil) {
  case response.file(path) {
    Ok(response.File(length: size, ..)) -> {
      let rest = size - offset
      let length = case limit {
        Some(limit) if limit < rest -> limit
        Some(_) | None -> rest
      }
      case offset >= 0 && rest >= 0 {
        True -> Ok(response.File(path:, offset:, length:))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}
