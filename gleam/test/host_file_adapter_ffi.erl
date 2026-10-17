%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: MIT

-module(host_file_adapter_ffi).
-export([temporary_directory/0, write/2, read/1, atomic_replace/2, remove/1]).

temporary_directory() ->
    Root = filename:absname("necoherence-file-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Root),
    ok = file:make_dir(filename:join(Root, "nested")),
    unicode:characters_to_binary(Root).

write(Path, Contents) ->
    ok = file:write_file(binary_to_list(Path), unicode:characters_to_binary(Contents)), ok.

read(Path) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Contents} -> {ok, unicode:characters_to_binary(Contents)};
        {error, _} -> {error, nil}
    end.

atomic_replace(Path, Contents) ->
    Target = binary_to_list(Path), Temp = Target ++ ".necoherence-tmp",
    case file:write_file(Temp, unicode:characters_to_binary(Contents)) of
        ok -> case file:rename(Temp, Target) of ok -> {ok, nil}; {error, _} -> {error, nil} end;
        {error, _} -> {error, nil}
    end.

remove(Path) ->
    _ = file:del_dir_r(binary_to_list(Path)), nil.
