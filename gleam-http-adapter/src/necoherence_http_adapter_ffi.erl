%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(necoherence_http_adapter_ffi).
-export([
    bytes_to_binary/1,
    binary_to_bytes/1,
    header_to_bytes/1,
    ensure_http_runtime/0,
    queue_new/0,
    queue_publish/2,
    queue_pop/1,
    run_safely/1
]).

bytes_to_binary(Bytes) when is_list(Bytes) ->
    list_to_binary([B band 16#ff || B <- Bytes]).

binary_to_bytes(Binary) when is_binary(Binary) ->
    binary_to_list(Binary).

header_to_bytes(Value) when is_binary(Value) ->
    Codepoints = unicode:characters_to_list(Value),
    case lists:all(fun(Codepoint) ->
        is_integer(Codepoint) andalso Codepoint =< 255
    end, Codepoints) of
        true -> {ok, Codepoints};
        false -> {error, nil}
    end.

ensure_http_runtime() ->
    case application:ensure_all_started(inets) of
        {ok, _} ->
            case application:ensure_all_started(ssl) of
                {ok, _} -> true;
                {error, _} -> false
            end;
        {error, _} -> false
    end.

queue_new() ->
    spawn(fun() -> queue_loop(0, queue:new()) end).

queue_publish(Queue, Observation) ->
    Queue ! {publish, Observation},
    nil.

queue_pop(Queue) ->
    Ref = make_ref(),
    Queue ! {pop, self(), Ref},
    receive
        {Ref, Value} -> Value
    after 1000 ->
        none
    end.

queue_loop(Next, Values) ->
    receive
        {publish, Observation} ->
            queue_loop(Next + 1, queue:in({Next, Observation}, Values));
        {pop, Caller, Ref} ->
            case queue:out(Values) of
                {empty, _} ->
                    Caller ! {Ref, none},
                    queue_loop(Next, Values);
                {{value, Value}, Rest} ->
                    Caller ! {Ref, {some, Value}},
                    queue_loop(Next, Rest)
            end
    after 2000 ->
        ok
    end.

run_safely(Work) ->
    try
        Work(),
        completed
    catch
        error:{unexpected_httpc_error, {shutdown, server_closed}} ->
            response_body_truncated;
        error:{unexpected_httpc_error, socket_closed_remotely} ->
            closed_before_headers;
        error:{unexpected_httpc_error, {could_not_parse_as_http, _}} ->
            malformed_response;
        error:{unexpected_httpc_error, {invalid_version, _}} ->
            malformed_response;
        _:_ ->
            unclassified
    end.
