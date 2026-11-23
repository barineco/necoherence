%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: AGPL-3.0-only

-module(semantic_invariant_runner_ffi).
-export([read_line/0]).

read_line() ->
    case io:get_line(standard_io, "") of
        eof -> <<>>;
        Line -> unicode:characters_to_binary(Line)
    end.
