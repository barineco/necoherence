%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(execution_check_ffi).
-export([read_file/1, arguments/0]).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Contents} -> {ok, Contents};
        {error, _} -> {error, nil}
    end.

arguments() ->
    [unicode:characters_to_binary(Argument) || Argument <- init:get_plain_arguments()].

