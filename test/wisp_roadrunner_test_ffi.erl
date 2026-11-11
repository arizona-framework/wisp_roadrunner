-module(wisp_roadrunner_test_ffi).
-export([request/4, silence_logger/0, is_file/1]).
-export([write_cert/1, curl/1, free_port/0, h3_request/4]).

silence_logger() ->
    _ = logger:remove_handler(default),
    nil.

%% A plain HTTP/1.1 request through `httpc`, returning
%% `{Status, Headers, Body}` with binary headers and body.
request(Method, Url, Headers, Body) ->
    {ok, _} = application:ensure_all_started(inets),
    HttpcHeaders = [{binary_to_list(N), binary_to_list(V)} || {N, V} <- Headers],
    {ContentType, Rest} =
        case lists:keytake("content-type", 1, HttpcHeaders) of
            {value, {_, CT}, Others} -> {CT, Others};
            false -> {"application/octet-stream", HttpcHeaders}
        end,
    Request =
        case Method of
            get -> {binary_to_list(Url), HttpcHeaders};
            _ -> {binary_to_list(Url), Rest, ContentType, Body}
        end,
    {ok, {{_, Status, _}, RespHeaders, RespBody}} =
        httpc:request(Method, Request, [{autoredirect, false}], [{body_format, binary}]),
    {Status, [{list_to_binary(N), list_to_binary(V)} || {N, V} <- RespHeaders], RespBody}.

is_file(Path) ->
    filelib:is_regular(Path).

%% A test certificate chain and key written as PEM files under `Dir`.
write_cert(Dir) ->
    Key = fun() -> public_key:generate_key({namedCurve, secp256r1}) end,
    Chain = [{key, Key()}, {digest, sha256}],
    #{server_config := Config} = public_key:pkix_test_data(#{
        server_chain => #{root => Chain, peer => [{key, Key()}, {digest, sha256}]},
        client_chain => #{root => Chain, peer => [{key, Key()}, {digest, sha256}]}
    }),
    Cert = proplists:get_value(cert, Config),
    CaCerts = proplists:get_value(cacerts, Config),
    {KeyType, KeyDer} = proplists:get_value(key, Config),
    ok = filelib:ensure_path(Dir),
    CertFile = filename:join(Dir, ~"cert.pem"),
    KeyFile = filename:join(Dir, ~"key.pem"),
    ok = file:write_file(
        CertFile,
        public_key:pem_encode([{'Certificate', C, not_encrypted} || C <- [Cert | CaCerts]])
    ),
    ok = file:write_file(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    {CertFile, KeyFile}.

%% Run curl with these arguments and return what it printed, failing the
%% test when curl fails. curl speaks HTTP/2 and HTTP/3, which `httpc` does
%% not.
curl(Args) ->
    Curl = os:find_executable("curl"),
    true = is_list(Curl),
    Port = open_port({spawn_executable, Curl}, [
        {args, Args}, exit_status, binary, stderr_to_stdout
    ]),
    collect_curl(Port, <<>>).

collect_curl(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect_curl(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> Acc;
        {Port, {exit_status, Status}} -> error({curl_failed, Status, Acc})
    after 10000 -> error({curl_timeout, Acc})
    end.

%% A port free on both TCP and UDP, for a listener that serves HTTP/3,
%% which needs a fixed port.
free_port() ->
    {ok, Tcp} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Tcp),
    case gen_udp:open(Port, [{ip, {127, 0, 0, 1}}]) of
        {ok, Udp} ->
            ok = gen_udp:close(Udp),
            ok = gen_tcp:close(Tcp),
            Port;
        {error, _} ->
            ok = gen_tcp:close(Tcp),
            free_port()
    end.

%% The quiche client roadrunner's HTTP/3 interop job runs, pinned by digest.
-define(QUICHE_IMAGE,
    ~"cloudflare/quiche@sha256:25e0f78b133bc11a098ccd70f3ad44d8ac866e269db2f4683e596049b0d4419f"
).

%% One HTTP/3 request, returning the response body. With
%% `ROADRUNNER_GLEAM_H3_CLIENT=docker` it runs quiche in Docker; otherwise
%% the local curl, which must support HTTP/3.
h3_request(Port, Path, Method, Body) ->
    Url = iolist_to_binary([~"https://127.0.0.1:", integer_to_binary(Port), Path]),
    case os:getenv("ROADRUNNER_GLEAM_H3_CLIENT") of
        "docker" -> quiche(Url, Method, Body);
        _ -> curl_h3(Url, Method, Body)
    end.

curl_h3(Url, Method, Body) ->
    case binary:match(curl([~"--version"]), ~"HTTP3") of
        nomatch ->
            error(
                {no_http3_client,
                    ~"the local curl has no HTTP/3: set ROADRUNNER_GLEAM_H3_CLIENT=docker"}
            );
        _ ->
            curl([~"-s", ~"-k", ~"--http3-only", ~"-X", Method | data_args(Body)] ++ [Url])
    end.

data_args(<<>>) -> [];
data_args(Body) -> [~"--data-binary", Body].

quiche(Url, Method, Body) ->
    Dir = filename:join(
        filename:basedir(user_cache, "roadrunner_gleam_h3"),
        integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "body"), Body),
    BodyArgs =
        case Body of
            <<>> -> [];
            _ -> [~"--body", ~"/in/body"]
        end,
    docker(
        [
            ~"run", ~"--rm", ~"--network", ~"host", ~"-v", iolist_to_binary([Dir, ~":/in:ro"]),
            ?QUICHE_IMAGE, ~"quiche-client", ~"--no-verify", ~"--method", Method
        ] ++ BodyArgs ++ [Url]
    ).

docker(Args) ->
    Docker = os:find_executable("docker"),
    true = is_list(Docker),
    Port = open_port({spawn_executable, Docker}, [{args, Args}, exit_status, binary]),
    collect_curl(Port, <<>>).
