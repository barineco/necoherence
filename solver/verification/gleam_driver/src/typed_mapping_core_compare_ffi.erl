%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: AGPL-3.0-only

-module(typed_mapping_core_compare_ffi).
-export([read_stdin/0]).

read_stdin() ->
    read_stdin_loop([]).

read_stdin_loop(Acc) ->
    case io:get_chars(standard_io, "", 1048576) of
        eof -> unicode:characters_to_binary(lists:reverse(Acc));
        Data -> read_stdin_loop([unicode:characters_to_binary(Data) | Acc])
    end.
