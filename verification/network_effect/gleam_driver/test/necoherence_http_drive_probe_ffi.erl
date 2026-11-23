%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(necoherence_http_drive_probe_ffi).
-export([count_start/0, count_stop/1]).

count_start() ->
    Tracer = spawn(fun() -> counter(0) end),
    erlang:trace_pattern({necoherence_http_adapter_ffi, queue_pop, 1}, true, [local]),
    erlang:trace(self(), true, [call, {tracer, Tracer}]),
    Tracer.

count_stop(Tracer) ->
    erlang:trace(self(), false, [call]),
    erlang:trace_pattern({necoherence_http_adapter_ffi, queue_pop, 1}, false, [local]),
    Delivered = erlang:trace_delivered(self()),
    receive
        {trace_delivered, _, Delivered} -> ok
    end,
    Ref = make_ref(),
    Tracer ! {stop, self(), Ref},
    receive
        {Ref, Count} -> Count
    end.

counter(Count) ->
    receive
        {trace, _, call, _} -> counter(Count + 1);
        {stop, Caller, Ref} -> Caller ! {Ref, Count}
    end.
