%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(necoherence_http_smoke_peer_ffi).
-export([
    peer_start/2,
    peer_release/1,
    peer_count/1,
    peer_request/1,
    peer_stop/1,
    peer_send_split_request/3,
    unused_port/0,
    http_response/3,
    stop_http_runtime/0,
    binary_contains/2,
    classify_fault/3
]).

peer_start(Response, Mode) when is_binary(Response), is_binary(Mode) ->
    Parent = self(),
    Pid = spawn(fun() -> peer_init(Parent, Response, Mode) end),
    receive
        {Pid, ready, Port} -> {{peer, Pid}, Port}
    after 2000 ->
        erlang:error(peer_start_timeout)
    end.

peer_init(Parent, Response, Mode) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {packet, raw}, {active, false},
        {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Parent ! {self(), ready, Port},
    case gen_tcp:accept(Listener, 5000) of
        {ok, Socket} ->
            gen_tcp:close(Listener),
            Request = receive_request(Socket, <<>>, 50),
            peer_action(Mode, Socket, Response, Request);
        {error, _} ->
            gen_tcp:close(Listener),
            peer_state(0, <<>>)
    end.

receive_request(Socket, Acc, RemainingTimeouts) ->
    case gen_tcp:recv(Socket, 0, 100) of
        {ok, Bytes} ->
            Next = <<Acc/binary, Bytes/binary>>,
            case request_complete(Next) of
                true -> Next;
                false -> receive_request(Socket, Next, RemainingTimeouts)
            end;
        {error, timeout} when RemainingTimeouts > 0 ->
            receive_request(Socket, Acc, RemainingTimeouts - 1);
        {error, timeout} -> Acc;
        {error, _} -> Acc
    end.

request_complete(Request) ->
    case binary:match(Request, <<"\r\n\r\n">>) of
        nomatch -> false;
        {HeaderEnd, 4} ->
            HeaderSize = HeaderEnd + 4,
            ContentLength = content_length(Request),
            byte_size(Request) >= HeaderSize + ContentLength
    end.

content_length(Request) ->
    Lower = string:lowercase(binary_to_list(Request)),
    case re:run(Lower, "content-length:[[:space:]]*([0-9]+)", [{capture, [1], list}]) of
        {match, [Digits]} -> list_to_integer(Digits);
        nomatch -> 0
    end.

peer_action(<<"delay">>, Socket, Response, Request) ->
    delayed_peer(Socket, Response, Request);
peer_action(<<"close_headers">>, Socket, _Response, Request) ->
    gen_tcp:close(Socket),
    peer_state(1, Request);
peer_action(<<"close_body">>, Socket, _Response, Request) ->
    gen_tcp:send(Socket, <<"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nx">>),
    gen_tcp:close(Socket),
    peer_state(1, Request);
peer_action(<<"malformed">>, Socket, _Response, Request) ->
    gen_tcp:send(Socket, <<"HTTP/1.1 abc OK\r\nContent-Length: 0\r\n\r\n">>),
    gen_tcp:close(Socket),
    peer_state(1, Request);
peer_action(<<"invalid_framing">>, Socket, _Response, Request) ->
    gen_tcp:send(Socket, <<"HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n">>),
    gen_tcp:close(Socket),
    peer_state(1, Request);
peer_action(_, Socket, Response, Request) ->
    gen_tcp:send(Socket, Response),
    gen_tcp:close(Socket),
    peer_state(1, Request).

delayed_peer(Socket, Response, Request) ->
    receive
        {release, Caller, Ref} ->
            gen_tcp:send(Socket, Response),
            gen_tcp:close(Socket),
            Caller ! {Ref, ok},
            peer_state(1, Request);
        {count, Caller, Ref} ->
            Caller ! {Ref, 1},
            delayed_peer(Socket, Response, Request);
        {request, Caller, Ref} ->
            Caller ! {Ref, Request},
            delayed_peer(Socket, Response, Request);
        stop ->
            gen_tcp:close(Socket),
            ok
    after 5000 ->
        gen_tcp:close(Socket),
        peer_state(1, Request)
    end.

peer_state(Count, Request) ->
    receive
        {count, Caller, Ref} ->
            Caller ! {Ref, Count},
            peer_state(Count, Request);
        {request, Caller, Ref} ->
            Caller ! {Ref, Request},
            peer_state(Count, Request);
        {release, Caller, Ref} ->
            Caller ! {Ref, ok},
            peer_state(Count, Request);
        stop -> ok
    after 5000 ->
        ok
    end.

peer_release({peer, Pid}) ->
    Ref = make_ref(),
    Pid ! {release, self(), Ref},
    receive {Ref, ok} -> nil after 1000 -> nil end.

peer_count({peer, Pid}) ->
    Ref = make_ref(),
    Pid ! {count, self(), Ref},
    receive {Ref, Count} -> Count after 1000 -> 0 end.

peer_request({peer, Pid}) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref},
    receive {Ref, Request} -> Request after 1000 -> <<>> end.

peer_stop({peer, Pid}) ->
    Pid ! stop,
    nil.

peer_send_split_request(Port, Body, Delay) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000),
    Headers = iolist_to_binary([
        <<"POST /split HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>
    ]),
    ok = gen_tcp:send(Socket, Headers),
    timer:sleep(Delay),
    _ = gen_tcp:send(Socket, Body),
    _ = gen_tcp:recv(Socket, 0, 1000),
    gen_tcp:close(Socket),
    nil.

unused_port() ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    gen_tcp:close(Listener),
    Port.

binary_contains(Haystack, Needle) when is_binary(Haystack), is_binary(Needle) ->
    binary:match(Haystack, Needle) =/= nomatch.

stop_http_runtime() ->
    _ = application:stop(inets),
    _ = application:stop(ssl),
    nil.

classify_fault(<<"unsupported_uri">>, _Stage, _Cause) -> unsupported_uri_scheme;
classify_fault(<<"invalid_configuration">>, _Stage, _Cause) -> invalid_host_configuration;
classify_fault(<<"execution_start">>, _Stage, _Cause) -> execution_start_failed;
classify_fault(<<"resolver">>, _Stage, _Cause) -> name_resolution_failed;
classify_fault(<<"connect">>, _Stage, _Cause) -> connection_failed;
classify_fault(<<"partial_write">>, _Stage, _Cause) -> request_write_failed;
classify_fault(<<"headers">>, _Stage, _Cause) -> response_headers_failed;
classify_fault(<<"body">>, _Stage, _Cause) -> response_body_failed;
classify_fault(<<"body_limit">>, _Stage, _Cause) -> response_body_limit_exceeded;
classify_fault(<<"malformed">>, _Stage, _Cause) -> malformed_response;
classify_fault(<<"header_codec">>, _Stage, _Cause) -> header_representation_unavailable;
classify_fault(<<"request_header">>, _Stage, _Cause) -> request_header_encoding_unavailable;
classify_fault(<<"cancel">>, _Stage, _Cause) -> cancellation_rejected;
classify_fault(<<"deadline_control">>, _Stage, _Cause) -> deadline_control_unavailable;
classify_fault(<<"timeout">>, Stage, Cause) -> {timeout, Stage, Cause};
classify_fault(<<"runtime">>, _Stage, _Cause) -> host_runtime_failure;
classify_fault(<<"closed">>, _Stage, _Cause) -> host_closed.

http_response(Status, Headers, Body) ->
    HeaderLines = [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers],
    iolist_to_binary([
        <<"HTTP/1.1 ">>, integer_to_binary(Status), <<" Status\r\n">>,
        HeaderLines,
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n\r\n">>,
        Body
    ]).
