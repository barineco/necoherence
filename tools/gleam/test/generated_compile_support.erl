%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: AGPL-3.0-only

-module(generated_compile_support).
-export([run_shell/2, scratch_root/0, package_root/0, generated_representative_compile_test_/0, generated_bytes_compile_test_/0]).

generated_representative_compile_test_() ->
    {timeout, 120, fun() ->
        generated_representative_types_test:generated_representative_carriers_and_codecs_compile(),
        ok = file:del_dir_r(scratch_root())
    end}.

generated_bytes_compile_test_() ->
    {timeout, 120, fun() ->
        generated_bytes_wrapper_test:declared_wrapper_bytes_and_rawbody_roundtrip(),
        generated_bytes_wrapper_test:unwrapped_bytes_and_rawbody_roundtrip(),
        ok
    end}.

run_shell(Directory, Command) ->
    Port = open_port({spawn_executable, "/bin/sh"}, [
        {args, ["-c", "exec " ++ unicode:characters_to_list(Command)]},
        {cd, unicode:characters_to_list(Directory)},
        exit_status,
        stderr_to_stdout,
        binary,
        use_stdio
    ]),
    collect(Port, <<>>, erlang:monotonic_time(millisecond) + 100000).

collect(Port, Output, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} -> collect(Port, <<Output/binary, Data/binary>>, Deadline);
        {Port, {exit_status, Status}} -> {Status, Output}
    after Remaining ->
        port_close(Port),
        {124, <<Output/binary, "\ngenerated compiler exceeded its deadline\n">>}
    end.

scratch_root() ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        Directory -> string:trim(Directory, trailing, "/")
    end,
    unicode:characters_to_binary(Base ++ "/necoherence-gleam-generated-" ++ os:getpid()).

package_root() ->
    {ok, Directory} = file:get_cwd(),
    Package = filename:join(filename:dirname(filename:dirname(Directory)), "gleam"),
    unicode:characters_to_binary(Package).
