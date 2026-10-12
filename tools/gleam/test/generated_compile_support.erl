%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: AGPL-3.0-only

-module(generated_compile_support).
-export([run_shell/2, scratch_root/0, package_root/0]).

run_shell(Directory, Command) ->
    Port = open_port({spawn_executable, "/bin/sh"}, [
        {args, ["-c", unicode:characters_to_list(Command)]},
        {cd, unicode:characters_to_list(Directory)},
        exit_status,
        stderr_to_stdout,
        binary,
        use_stdio
    ]),
    collect(Port, <<>>).

collect(Port, Output) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Output/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {Status, Output}
    end.

scratch_root() ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> string:trim(Directory, trailing, "/")
    end,
    unicode:characters_to_binary(Base ++ "/necoherence-gleam-generated").

package_root() ->
    {ok, Directory} = file:get_cwd(),
    Package = filename:join(filename:dirname(filename:dirname(Directory)), "gleam"),
    unicode:characters_to_binary(Package).
