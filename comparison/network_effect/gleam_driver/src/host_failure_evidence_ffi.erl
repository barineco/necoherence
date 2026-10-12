%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(host_failure_evidence_ffi).
-export([read_line/0]).

read_line() ->
    case io:get_line(standard_io, "") of
        eof -> {error, nil};
        Line -> {ok, unicode:characters_to_binary(Line)}
    end.
