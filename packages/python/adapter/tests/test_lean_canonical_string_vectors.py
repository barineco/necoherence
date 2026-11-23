# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import pytest

from necoherence import signature_values as sv
from necoherence import type_signatures as ts


CASES = [
    ('ctl-0', '\x00', '"\\u0000"',
     '700174b26850d224c7a156cb6a45cea08031eab640fcfc1eaf7f770ab9aeaa66'),
    ('ctl-1', '\x01', '"\\u0001"',
     'b81cfb0a6715e53b373345b49e8ad94eb55fd777519dc539373d0634973c186e'),
    ('ctl-2', '\x02', '"\\u0002"',
     '6f2b5a0f4963b9641a11009c1c25a75805f7e49ac85a513d7999e966d7da3705'),
    ('ctl-3', '\x03', '"\\u0003"',
     '39b7c3e9fcc7d258f48a42d6183921b18840c1f132a7d881fb3b0f2c51492012'),
    ('ctl-4', '\x04', '"\\u0004"',
     '236ef1e44d9f08a1f6453e7006d14d6c2ef64d2fc0e30bc5b26857158c1e7b1e'),
    ('ctl-5', '\x05', '"\\u0005"',
     'a5ad36793934433a0bfa8e78b9157beede8433779bb8d48fe8338e941e6f555d'),
    ('ctl-6', '\x06', '"\\u0006"',
     '47637acdb13d9058f109ba3132025e211fb33b012422d85673668c32481d6580'),
    ('ctl-7', '\x07', '"\\u0007"',
     'bc4748cf817763f51dc0d0d7034c52d1d6af3974b1fdc86999bb6d339f3366b4'),
    ('ctl-8', '\x08', '"\\u0008"',
     '2307cf86340605a8481504798c43ade28181268fbce6831e2572ad1830a598d5'),
    ('ctl-9', '\t', '"\\u0009"',
     'c50273c7b1bd1f4bfa17d5e557987ae9685ab34312aba4e609540cebcd9f801a'),
    ('ctl-10', '\n', '"\\n"',
     'd7a5e915306d21dc1937ad5616f1dc9682e759e75ef51dd05fd9ddc98a078ea1'),
    ('ctl-11', '\x0b', '"\\u000b"',
     '0b3c45b45a3ea9ac8dec30a87e230862c3e7e6e2e6f83f4dca0009aee5bc71f8'),
    ('ctl-12', '\x0c', '"\\u000c"',
     '8355f2d12e2ba18990c7eff794c087e4a9412b7cde3b9579b14b0ee8b6fac5d1'),
    ('ctl-13', '\r', '"\\r"',
     '8eb852fe331310caa37e80df8a4d52ee8deb3ddc0a5143b52c662d984d9e8018'),
    ('ctl-14', '\x0e', '"\\u000e"',
     'c7d3023ebd33d6980a473a2fb1c93f2281425757c9d6fac2cff0b7da3e067e77'),
    ('ctl-15', '\x0f', '"\\u000f"',
     '058d0704cd6183ffcb0fa41e9e733fb754f64b7c784e009937cbda01d068ed57'),
    ('ctl-16', '\x10', '"\\u0010"',
     'a21c199195f063745039afeff24c706f8239e79027531e2be1660fc5a9fbb643'),
    ('ctl-17', '\x11', '"\\u0011"',
     'f72f54215552142a87cac5404fcdd035393f814b3f8924be765330965e02e0c0'),
    ('ctl-18', '\x12', '"\\u0012"',
     '5d26db5abc2de6cd4390195339073be074163ef5a288b1ccbdfb88cb67f7fa5b'),
    ('ctl-19', '\x13', '"\\u0013"',
     '7ae98bb6aa3ce0d5fee356015c45469346f1bb64f04a37a4edbd9c572a79eee9'),
    ('ctl-20', '\x14', '"\\u0014"',
     '6a7e1c7af7157bd688c6517f2e9014243058b8451694b34adcf4f14be5143d61'),
    ('ctl-21', '\x15', '"\\u0015"',
     '6089bfa90718b2b485ddc4314097ba2ac897a2ccb9156d2143794e5236f9d075'),
    ('ctl-22', '\x16', '"\\u0016"',
     '3bb716d5b7c96a7a0250c208677bf885ab8bda28def6688b51edfc6f72da806f'),
    ('ctl-23', '\x17', '"\\u0017"',
     '9186b55d39726bf2ae0a20330dcc83cdd9a1ac21388e79b326c27f09e2a4d105'),
    ('ctl-24', '\x18', '"\\u0018"',
     '1f776d272d2056d79fe080e79a50332ec3a7414b9b488de0aefa9309c454f775'),
    ('ctl-25', '\x19', '"\\u0019"',
     '925be399e6a474e5c71ce351f674e0571366b97aad7c0f51c15bf82a6c4c4499'),
    ('ctl-26', '\x1a', '"\\u001a"',
     'e03ab01444d2832c583a3a50415c2ab811cce5935746e501bc34c6677418caa4'),
    ('ctl-27', '\x1b', '"\\u001b"',
     '9981bd8cc60e5cd9c790c3aea1a189ea518a45423f2ab3cf07ea5930104b16c2'),
    ('ctl-28', '\x1c', '"\\u001c"',
     '1ab3273b0619d122831439f7c82e4c998b3720827cb41772c4c8b63dc75e9094'),
    ('ctl-29', '\x1d', '"\\u001d"',
     '7338927e1e35d753214ce2835d6dde931aef64763d66ce2034ad1c5d5f372f04'),
    ('ctl-30', '\x1e', '"\\u001e"',
     '2ea65264eb349ad1b685cfaf03f336b5cee389dc50f22ac9bb92db1ce7d36912'),
    ('ctl-31', '\x1f', '"\\u001f"',
     '6e1f297fd3657440862f051f44e4bc0ee6b26348011e5891e91aa1aa7e9c0759'),
    ('sym-127', '\x7f', '"\x7f"',
     '6fe76740e12a93d5598fe685cb6ad3d3c94e44609065a56866b69647772026ec'),
    ('sym-128', '\x80', '"\x80"',
     '2e80e4b870d30a809d5a11744fb413cb41fb82fae8cde9621d8fcb67ba5f20a1'),
    ('sym-159', '\x9f', '"\x9f"',
     '8f2943b731e2a6347d040ffbce6e20c234d7ddb3dda657f71903495faa81e32e'),
    ('sym-160', '\xa0', '"\xa0"',
     'e82d47dec07b50559f503bd6eb8adfa42bfd31b8294f7d9aaffbba8a9ec66aaf'),
    ('sym-8232', '\u2028', '"\u2028"',
     '8aa716ff98153a8b537e4e21f27cb75d7ebe92f4754aca11a38ee7a27b714941'),
    ('sym-65279', '\ufeff', '"\ufeff"',
     'b839e4168b1e2225296aa76599e3ada57bf459000ffb0a192f211b1eeb23e9a8'),
    ('sym-65536', '𐀀', '"𐀀"',
     '80066806fcc52478beec53a2ac42bc6a6324eb67c1161136649a669c15d4b7bf'),
    ('sym-128512', '😀', '"😀"',
     '7a0c50b92434b015545fe93ab723db2d4b2cdd14a441405624a9ce8be29f1d5a'),
    ('sym-1114111', '\U0010ffff', '"\U0010ffff"',
     '216551a7df34e082dd063693c09f0b567df0351251da1fd71057b83fe66003c6'),
    ('sym-34', '"', '"\\""',
     '0c926fba014b31b506cd4ceb60d646c0c867432650fa0671fcafed6b772614a3'),
    ('sym-92', '\\', '"\\\\"',
     '687a9ed5a2b7019504648f874bb683f56e7787e1a4738493d84349c8d4e72b23'),
    ('empty', '', '""',
     '12ae32cb1ec02d01eda3581b127c1fee3b0dc53572ed6baf239721a03d82e126'),
    ('quote-backslash', '"\\', '"\\"\\\\"',
     'c7061f0fe2692c517003ff6f2a463fc36aab70e30ea6a45f97fcf7b5611aec74'),
    ('newline-cr', 'a\nb\rc', '"a\\nb\\rc"',
     '6f750fcb34d30d0028ec4156e365c60f8122d9cf89cf1325bf04f5b2b27be60d'),
    ('tab-backspace-formfeed', '\t\x08\x0c\x01', '"\\u0009\\u0008\\u000c\\u0001"',
     '772558d4de3037930dcc0196ea88b41fefcd00d45830c382e3b2cfbb27c9682a'),
    ('japanese', '文字列ガ', '"文字列ガ"',
     '256b19d71d725d3ea44ffc9552eebd31d7c4651f2c19a2fe065290a3f466cb58'),
    ('mixed', 'A\tあ😀\x1b"', '"A\\u0009あ😀\\u001b\\""',
     'b25cc62a72135d5e88e1753680acb59ac453efbf8f32cbc3d3604c7ade6c6ea7'),
    ('object-control-keys', {'k\t1': 'v\x01', 'a': '"x"', 'b\n': '\x08'}, '{"a":"\\"x\\"","b\\n":"\\u0008","k\\u00091":"v\\u0001"}',
     'bf54f08cfa02bec52d9d5361e204af5b5717fa37028e76555fdcb4ed0f0e3ecf'),
    ('nested', ['\x0c', {'\x1f': ['x\ty', None, True]}, 3], '["\\u000c",{"\\u001f":["x\\u0009y",null,true]},3]',
     '7f7ef5d39c138013d74a87015e92889216d5991c08f02a988e947b06efbc205f'),
]


@pytest.mark.parametrize(("value", "canonical", "digest"), [case[1:] for case in CASES], ids=[case[0] for case in CASES])
def test_hash_path_matches_lean_canonical_json(value, canonical, digest):
    assert ts._canonical(value) == canonical
    assert ts._sha(value) == digest


@pytest.mark.parametrize(("value", "canonical", "digest"), [case[1:] for case in CASES], ids=[case[0] for case in CASES])
def test_wire_encodings_match_lean_canonical_json(value, canonical, digest):
    assert sv.canonical_wire(value) == canonical
    assert sv.encode_wire_json(value) == canonical


def test_reference_key_matches_lean_canonical_object_with_control_keys():
    value = {"k\t1": "v\x01", "a": '"x"', "b\n": "\b"}
    assert sv.ref_key(value) == '{"a":"\\"x\\"","b\\n":"\\u0008","k\\u00091":"v\\u0001"}'
