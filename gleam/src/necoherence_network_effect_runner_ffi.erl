%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(necoherence_network_effect_runner_ffi).
-export([read_stdin/0]).

read_stdin() ->
    case io:get_line(standard_io, "") of
        eof -> <<>>;
        Line -> iolist_to_binary([Line | read_rest()])
    end.

read_rest() ->
    case io:get_line(standard_io, "") of
        eof -> [];
        Line -> [Line | read_rest()]
    end.

