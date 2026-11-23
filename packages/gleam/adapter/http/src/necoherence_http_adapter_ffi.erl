%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(necoherence_http_adapter_ffi).
-export([
    header_to_bytes/1,
    ensure_http_runtime/0,
    queue_new/0,
    queue_publish/2,
    queue_publish_observation/2,
    queue_bind_worker/2,
    queue_publish_deadline/2,
    queue_pop/1,
    queue_finish/1,
    queue_stop/1,
    queue_core_done/1,
    queue_running/1,
    queue_await/1,
    queue_await_for/2,
    monotonic_millis/0,
    run_safely/1,
    put_stage/1,
    current_stage/0,
    try_call/1,
    queue_deadline_emitted/1,
    dispatch_bits/5
]).

dispatch_bits(Method, Url, Headers, ContentType, Body) ->
    case take_interrupt() of
        true ->
            {error, interrupted};
        false ->
            dispatch_request(Method, Url, Headers, ContentType, Body)
    end.

dispatch_request(Method, Url, Headers, ContentType, Body) ->
    ErlUrl = unicode:characters_to_list(Url),
    ErlHeaders = prepare_headers(Headers),
    HttpOptions = [{autoredirect, false}, {timeout, infinity}],
    Options = [
        {body_format, binary},
        {socket_opts, [{ipfamily, inet6fb4}]},
        {sync, false},
        {receiver, self()}
    ],
    Started = case Method of
        M when M =:= options; M =:= head; M =:= get ->
            httpc:request(Method, {ErlUrl, ErlHeaders}, HttpOptions, Options);
        _ ->
            ErlContentType = unicode:characters_to_list(ContentType),
            httpc:request(
                Method,
                {ErlUrl, ErlHeaders, ErlContentType, Body},
                HttpOptions,
                Options
            )
    end,
    case Started of
        {ok, RequestId} ->
            await_result(RequestId);
        {error, Error} ->
            {error, normalise_error(Error)}
    end.

await_result(RequestId) ->
    receive
        necoherence_interrupt ->
            _ = httpc:cancel_request(RequestId),
            {error, interrupted};
        {http, {RequestId, Result}} ->
            case take_interrupt() of
                true -> {error, interrupted};
                false -> map_result(Result)
            end
    end.

map_result({{_Version, Status, _Reason}, RespHeaders, RespBody}) ->
    {ok, {
        Status,
        [{unicode:characters_to_binary(K), unicode:characters_to_binary(V)}
            || {K, V} <- RespHeaders],
        RespBody
    }};
map_result({error, Error}) ->
    {error, normalise_error(Error)};
map_result(Other) ->
    erlang:error({unexpected_httpc_error, Other}).

take_interrupt() ->
    receive
        necoherence_interrupt -> true
    after 0 -> false
    end.

prepare_headers(Headers) ->
    prepare_headers_loop(Headers, []).

prepare_headers_loop([], Out) ->
    Out;
prepare_headers_loop([{K, V} | In], Out) ->
    prepare_headers_loop(
        In,
        [{unicode:characters_to_list(K), unicode:characters_to_list(V)} | Out]
    ).

normalise_error(Error = {failed_connect, Opts}) ->
    Ipv6 = case lists:keyfind(inet6, 1, Opts) of
        {inet6, _, V1} -> V1;
        _ -> erlang:error({unexpected_httpc_error, Error})
    end,
    Ipv4 = case lists:keyfind(inet, 1, Opts) of
        {inet, _, V2} -> V2;
        _ -> erlang:error({unexpected_httpc_error, Error})
    end,
    {failed_to_connect, normalise_ip_error(Ipv4), normalise_ip_error(Ipv6)};
normalise_error(Error) ->
    erlang:error({unexpected_httpc_error, Error}).

normalise_ip_error(Code) when is_atom(Code) ->
    {posix, erlang:atom_to_binary(Code)};
normalise_ip_error({tls_alert, {A, B}}) ->
    {tls_alert, erlang:atom_to_binary(A), unicode:characters_to_binary(B)};
normalise_ip_error(Error) ->
    erlang:error({unexpected_httpc_ip_error, Error}).

monotonic_millis() ->
    erlang:monotonic_time(millisecond).

header_to_bytes(Value) when is_binary(Value) ->
    Codepoints = unicode:characters_to_list(Value),
    case lists:all(fun(Codepoint) ->
        is_integer(Codepoint) andalso Codepoint =< 255
    end, Codepoints) of
        true -> {ok, list_to_binary(Codepoints)};
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
    spawn(fun() ->
        queue_loop(0, queue:new(), #{
            phase => running,
            waiters => [],
            emitted => false,
            observed => false,
            worker => undefined
        })
    end).

queue_publish(Queue, Observation) ->
    Queue ! {publish_result, Observation},
    nil.

queue_publish_observation(Queue, Observation) ->
    Queue ! {publish_observation, Observation},
    nil.

queue_bind_worker(Queue, Worker) ->
    Queue ! {bind_worker, Worker},
    nil.

queue_publish_deadline(Queue, Observation) ->
    Queue ! {publish_deadline, Observation},
    nil.

queue_finish(Queue) ->
    Queue ! finish,
    nil.

queue_stop(Queue) ->
    Queue ! stop,
    nil.

queue_core_done(Queue) ->
    Queue ! core_done,
    nil.

queue_pop(Queue) ->
    Monitor = erlang:monitor(process, Queue),
    Queue ! {pop, self(), Monitor},
    receive
        {Monitor, Value} ->
            erlang:demonitor(Monitor, [flush]),
            Value;
        {'DOWN', Monitor, process, _, _} ->
            gone
    end.

queue_deadline_emitted(Queue) ->
    Monitor = erlang:monitor(process, Queue),
    Queue ! {deadline_emitted, self(), Monitor},
    receive
        {Monitor, Value} ->
            erlang:demonitor(Monitor, [flush]),
            Value;
        {'DOWN', Monitor, process, _, _} ->
            true
    end.

queue_running(Queue) ->
    Monitor = erlang:monitor(process, Queue),
    Queue ! {running, self(), Monitor},
    receive
        {Monitor, Value} ->
            erlang:demonitor(Monitor, [flush]),
            Value;
        {'DOWN', Monitor, process, _, _} ->
            false
    end.

queue_await(Queue) ->
    Monitor = erlang:monitor(process, Queue),
    Queue ! {await, self(), Monitor},
    receive
        {Monitor, Value} ->
            erlang:demonitor(Monitor, [flush]),
            Value;
        {'DOWN', Monitor, process, _, _} ->
            gone
    end.

queue_await_for(Queue, Limit) ->
    Monitor = erlang:monitor(process, Queue),
    Queue ! {await, self(), Monitor},
    receive
        {Monitor, Value} ->
            erlang:demonitor(Monitor, [flush]),
            Value;
        {'DOWN', Monitor, process, _, _} ->
            gone
    after Limit ->
        Ack = make_ref(),
        Queue ! {cancel_await, self(), Monitor, Ack},
        receive
            {Ack, cancelled} ->
                erlang:demonitor(Monitor, [flush]),
                receive
                    {Monitor, Value} -> Value
                after 0 -> timed_out
                end;
            {'DOWN', Monitor, process, _, _} ->
                receive
                    {Monitor, Value} -> Value
                after 0 -> gone
                end
        end
    end.

queue_loop(Next, Values, #{phase := Phase, waiters := Waiters} = State) ->
    receive
        {publish_result, Observation} ->
            case maps:get(observed, State) of
                true ->
                    queue_loop(Next, Values, State);
                false ->
                    serve_waiters(Next + 1, queue:in({Next, Observation}, Values), State)
            end;
        {publish_observation, Observation} ->
            stop_worker(State),
            serve_waiters(
                Next + 1,
                queue:in({Next, Observation}, Values),
                State#{observed := true}
            );
        {publish_deadline, Observation} ->
            case maps:get(emitted, State) of
                true ->
                    queue_loop(Next, Values, State);
                false ->
                    stop_worker(State),
                    serve_waiters(
                        Next + 1,
                        queue:in({Next, Observation}, Values),
                        State#{emitted := true, observed := true}
                    )
            end;
        {bind_worker, Worker} ->
            queue_loop(Next, Values, State#{worker := Worker});
        finish ->
            case Phase of
                running_settled -> leave(Waiters);
                running -> queue_loop(Next, Values, State#{phase := finished});
                finished -> queue_loop(Next, Values, State)
            end;
        core_done ->
            case Phase of
                finished -> leave(Waiters);
                running -> queue_loop(Next, Values, State#{phase := running_settled});
                running_settled -> queue_loop(Next, Values, State)
            end;
        stop ->
            leave(Waiters);
        {deadline_emitted, Caller, Ref} ->
            Caller ! {Ref, maps:get(emitted, State)},
            queue_loop(Next, Values, State);
        {running, Caller, Ref} ->
            Caller ! {Ref, Phase =/= finished},
            queue_loop(Next, Values, State);
        {pop, Caller, Ref} ->
            case queue:out(Values) of
                {empty, _} ->
                    Caller ! {Ref, drained},
                    queue_loop(Next, Values, State);
                {{value, {Delivery, Observation}}, Rest} ->
                    Caller ! {Ref, {popped, Delivery, Observation}},
                    queue_loop(Next, Rest, State)
            end;
        {await, Caller, Ref} ->
            serve_waiters(Next, Values, State#{waiters := Waiters ++ [{Caller, Ref}]});
        {cancel_await, Caller, Ref, Ack} ->
            Caller ! {Ack, cancelled},
            queue_loop(Next, Values, State#{waiters := lists:keydelete(Ref, 2, Waiters)})
    end.

leave(Waiters) ->
    [Caller ! {Ref, gone} || {Caller, Ref} <- Waiters],
    ok.

stop_worker(#{worker := undefined}) ->
    ok;
stop_worker(#{worker := Worker}) ->
    Worker ! necoherence_interrupt,
    ok.

serve_waiters(Next, Values, #{waiters := Waiters} = State) ->
    case {queue:out(Values), Waiters} of
        {{{value, {Delivery, Observation}}, Rest}, [{Caller, Ref} | Others]} ->
            Caller ! {Ref, {popped, Delivery, Observation}},
            serve_waiters(Next, Rest, State#{waiters := Others});
        _ ->
            queue_loop(Next, Values, State)
    end.

try_call(Thunk) ->
    try
        {ok, Thunk()}
    catch
        _:_ ->
            {error, nil}
    end.

put_stage(Stage) ->
    erlang:put(necoherence_http_stage, Stage),
    nil.

current_stage() ->
    case erlang:get(necoherence_http_stage) of
        undefined -> request_write;
        Stage -> Stage
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
