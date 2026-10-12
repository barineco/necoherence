%% SPDX-FileCopyrightText: 2026 barineco
%% SPDX-License-Identifier: AGPL-3.0-only

-module(necoherence_semantic_invariant_runner_ffi).
-export([read_line/0, codec/4]).

read_line() ->
    case io:get_line(standard_io, "") of
        eof -> <<>>;
        Line -> unicode:characters_to_binary(Line)
    end.

codec(Source, Name, Checked, Wire) ->
    Key = crypto:hash(sha256, Source),
    Module = case get({codec, Key}) of
        undefined ->
            Compiled = compile_codec(Source, Key),
            put({codec, Key}, Compiled),
            Compiled;
        Cached -> Cached
    end,
    {ok, Context} = Module:initialize(Checked),
    Base = binary_to_list(Name),
    Decode = list_to_atom("decode_" ++ Base),
    Encode = list_to_atom("encode_" ++ Base),
    case apply(Module, Decode, [Context, Wire]) of
        {ok, Value} -> apply(Module, Encode, [Context, Value]);
        {error, Failure} -> {error, Failure}
    end.

compile_codec(Source, Key) ->
    Suffix = binary_to_list(binary:encode_hex(Key, lowercase)),
    Name = "invariant_codec_" ++ Suffix,
    Module = list_to_atom(Name),
    {ok, Cwd} = file:get_cwd(),
    Package = filename:join(filename:dirname(filename:dirname(Cwd)), "gleam"),
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
    Root = filename:join(Base, Name ++ "_" ++ os:getpid()),
    SourcePath = filename:join([Root, "src", Name ++ ".gleam"]),
    ok = filelib:ensure_dir(SourcePath),
    Manifest = io_lib:format(
        "name = \"invariant_codec\"\nversion = \"0.1.0\"\n[dependencies]\nnecoherence = { path = \"~s\" }\ngleam_stdlib = \">= 1.0.0 and < 2.0.0\"\n",
        [Package]),
    ok = file:write_file(filename:join(Root, "gleam.toml"), Manifest),
    ok = file:write_file(SourcePath, Source),
    try
        Port = open_port({spawn_executable, "/bin/sh"}, [
            {args, ["-c", "gleam build"]}, {cd, Root}, exit_status,
            stderr_to_stdout, binary, use_stdio
        ]),
        case collect(Port, <<>>) of
            {0, _} -> ok;
            {Status, Output} -> error({codec_compile, Status, Output})
        end,
        Beam = filename:join([Root, "build", "dev", "erlang", "invariant_codec", "ebin", Name]),
        {module, Module} = code:load_abs(Beam),
        Module
    after
        file:del_dir_r(Root)
    end.

collect(Port, Output) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Output/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {Status, Output}
    end.
