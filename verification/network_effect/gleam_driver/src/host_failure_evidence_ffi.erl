%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(host_failure_evidence_ffi).
-export([read_line/0, flag_new/0, flag_set/1, flag_is_set/1]).

read_line() ->
    case io:get_line(standard_io, "") of
        eof -> {error, nil};
        Line -> {ok, unicode:characters_to_binary(Line)}
    end.

flag_new() ->
    atomics:new(1, [{signed, false}]).

flag_set(Flag) ->
    atomics:put(Flag, 1, 1),
    nil.

flag_is_set(Flag) ->
    atomics:get(Flag, 1) =:= 1.
