# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from typing import Any

import pytest

from necoherence import signature_values as sv
from necoherence import type_signatures as ts
from necoherence.signature_values import WireFailure
from necoherence.declaration_wire import exact_json

VECTORS: dict[str, Any] = {'NUMBER_CANONICAL': [('0', '0'),
                      ('-0', '0'),
                      ('0.0', '0'),
                      ('-0.0', '0'),
                      ('0e0', '0'),
                      ('-0e-5', '0'),
                      ('0E+3', '0'),
                      ('0.00000000000', '0.e-1'),
                      ('-0.00000000000', '0.e-1'),
                      ('0.000000000000000000000e5', '0.e-6'),
                      ('-0.000e-307', '0.e-300'),
                      ('5.000', '5'),
                      ('100e-2', '1'),
                      ('-709.000', '-709'),
                      ('80.000E+0', '80'),
                      ('-5344393085576679206397590.000E+2', '-534439308557667920639759000'),
                      ('1e-9', '0.000000001'),
                      ('1e-10', '0.0000000001'),
                      ('1e9', '1000000000'),
                      ('1e10', '10000000000'),
                      ('1.5e-7', '0.00000015'),
                      ('2.5E+3', '2500'),
                      ('1e-400', '0.0000000001e-390'),
                      ('-1e-400', '-0.0000000001e-390'),
                      ('1.0e400',
                       '10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'),
                      ('1.23456789012345678901234567890e-30', '0.00000000012345678901234567890123456789e-20'),
                      ('-1e-18446744073709551617', '-0.0000000001e-18446744073709551607'),
                      ('123e-456789', '0.000000000123e-456777'),
                      ('9.99999999999e-10', '0.000000000999999999999'),
                      ('0.000000001000', '0.000000001'),
                      ('1.50', '1.5'),
                      ('10', '10'),
                      ('-123456789012345678901234567890.5000', '-123456789012345678901234567890.5')],
 'NUMBER_INVALID': ['01', '1.', '.5', '+1', '1e', 'NaN', '--1', '1e+'],
 'DECIMAL_ACCEPTED': ['-0', '1E+5', '0.5e05'],
 'DECIMAL_REJECTED': ['1e-18446744073709551617', '1e18446744073709551617', '1.5e+18446744073709551617', '01', '1.', '+1', '1e', 'NaN'],
 'WHITESPACE_DECIMALS': [' 1', '1 '],
 'TIMESTAMP': [('2000-12-31T23:59:60Z', True, True),
               ('2000-12-31T23:59:60+00:00', True, True),
               ('2000-01-01T00:00:00+01:00', False, False),
               ('2000-01-01T00:00:00-00:00', False, False),
               ('2001-12-31T23:59:59-00:01', False, False),
               ('2001-12-31T23:59:59+00:01', True, True),
               ('2000-02-30T00:00:00Z', False, False),
               ('2000-06-15T12:30:00.5Z', True, True),
               ('2000-06-15T12:30:00.Z', False, False),
               ('2000-06-15T12:30:00', False, False)],
 'ABSOLUTE_URI': [('http://[::1]:80/a?b#c', True, True),
                  ('mailto:x@y', True, True),
                  ('x:[v1.abc]', False, False),
                  ('h+t:%41/%4', False, False),
                  ('1a:/a b', False, False),
                  ('urn:a%zz', False, False),
                  ('a:[::1]x', False, False)],
 'LANGUAGE_TAG': [('en-US', True, True),
                  ('i-klingon', True, True),
                  ('x-private', True, True),
                  ('zh-Hant-TW', True, True),
                  ('en-a-bbb-x-a-ccc', True, True),
                  ('en-US-u-ca', True, True),
                  ('sl-rozaj-biske', True, True),
                  ('EN-gb-oed', False, False),
                  ('de-1901', True, True),
                  ('en-a-bbb-a-ccc', False, False)],
 'LABELS': [('ab/cd', True, True),
            ('a//b', False, False),
            ('abcdef', False, False),
            ('', True, True),
            ('a/b/c', False, False)],
 'BOUNDED_GRAPHEMES': [('éa', True, True), ('ab', True, True), ('😀', True, True)],
 'BASE64': [(('Standard', True, True), 'YQ==', '1'),
            (('Standard', True, True), 'YR==', None),
            (('Standard', True, True), 'YWI', '2'),
            (('Standard', True, True), 'YWJj', '3'),
            (('Standard', True, True), 'YQ', '1'),
            (('Standard', True, True), 'Y', None),
            (('Standard', True, True), 'Y=', None),
            (('Standard', True, True), 'YWJjZA', '4'),
            (('Standard', True, True), '-_-_', None),
            (('Standard', True, True), '+/+/', '3'),
            (('Either', False, False), 'YQ==', '1'),
            (('Either', False, False), 'YR==', '1'),
            (('Either', False, False), 'YWI', None),
            (('Either', False, False), 'YWJj', '3'),
            (('Either', False, False), 'YQ', None),
            (('Either', False, False), 'Y', None),
            (('Either', False, False), 'Y=', None),
            (('Either', False, False), 'YWJjZA', None),
            (('Either', False, False), '-_-_', '3'),
            (('Either', False, False), '+/+/', '3'),
            (('UrlSafe', True, False), 'YQ==', '1'),
            (('UrlSafe', True, False), 'YR==', '1'),
            (('UrlSafe', True, False), 'YWI', '2'),
            (('UrlSafe', True, False), 'YWJj', '3'),
            (('UrlSafe', True, False), 'YQ', '1'),
            (('UrlSafe', True, False), 'Y', None),
            (('UrlSafe', True, False), 'Y=', None),
            (('UrlSafe', True, False), 'YWJjZA', '4'),
            (('UrlSafe', True, False), '-_-_', '3'),
            (('UrlSafe', True, False), '+/+/', None)],
 'GRAPHEME': [('éa', '2', ['0', '2', '3']),
              ('🇦🇧🇨', '2', ['0', '2', '3']),
              ('각', '1', ['0', '3']),
              ('\r\n', '1', ['0', '2']),
              ('क्का', '3', ['0', '1', '3', '4'])],
 'LOWER': [('ÀB', 'Àb'), ('İ', 'İ'), ('ǅ', 'ǅ'), ('ABC', 'abc'), ('ＡA', 'Ａa')],
 'WIRE_ESCAPE': [('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\t"}, "origin": {"source": {"repository": "r", "revision": '
                  '"v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\\u0009","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\b"}, "origin": {"source": {"repository": "r", "revision": '
                  '"v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\\u0008","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\f"}, "origin": {"source": {"repository": "r", "revision": '
                  '"v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\\u000c","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\n"}, "origin": {"source": {"repository": "r", "revision": '
                  '"v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\\n","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\r"}, "origin": {"source": {"repository": "r", "revision": '
                  '"v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\\r","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\u0001\\u001f"}, "origin": {"source": {"repository": "r", '
                  '"revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\\u0001\\u001f","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\u007f"}, "origin": {"source": {"repository": "r", '
                  '"revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\x7f","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\""}, "origin": {"source": {"repository": "r", "revision": '
                  '"v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\\"","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\\\"}, "origin": {"source": {"repository": "r", "revision": '
                  '"v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"\\\\","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}'),
                 ('{"type_ref": {"source": {"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "definition_name": "T", "pointer": []}, "definition_ref": {"source": '
                  '{"repository": "r", "revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "name": "\\u00e9\\u2028"}, "origin": {"source": {"repository": "r", '
                  '"revision": "v", "path": "p", "content_digest": '
                  '"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "document_id": "d", '
                  '"declared_revision": null}, "pointer": []}, "value_path": [], "condition": {"tag": '
                  '"BelowMinimum"}, "observed": {"tag": "Absent"}, "reference_trace": []}',
                  '{"condition":{"tag":"BelowMinimum"},"definition_ref":{"name":"é\u2028'
                  '","source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"observed":{"tag":"Absent"},"origin":{"pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"reference_trace":[],"type_ref":{"definition_name":"T","pointer":[],"source":{"content_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","declared_revision":null,"document_id":"d","path":"p","repository":"r","revision":"v"}},"value_path":[]}')]}



GRAPHEME_PROPERTIES = [{'first': '768', 'last': '879', 'property': {'tag': 'Extend'}},
 {'first': '769', 'last': '769', 'property': {'tag': 'Other'}},
 {'first': '2307', 'last': '2307', 'property': {'tag': 'SpacingMark'}},
 {'first': '1536', 'last': '1541', 'property': {'tag': 'Prepend'}},
 {'first': '8205', 'last': '8205', 'property': {'tag': 'Zwj'}},
 {'first': '127462', 'last': '127487', 'property': {'tag': 'RegionalIndicator'}},
 {'first': '4352', 'last': '4447', 'property': {'tag': 'L'}},
 {'first': '4448', 'last': '4519', 'property': {'tag': 'V'}},
 {'first': '4520', 'last': '4607', 'property': {'tag': 'T'}},
 {'first': '44032', 'last': '44032', 'property': {'tag': 'Lv'}},
 {'first': '44033', 'last': '44059', 'property': {'tag': 'Lvt'}},
 {'first': '13', 'last': '13', 'property': {'tag': 'Cr'}},
 {'first': '10', 'last': '10', 'property': {'tag': 'Lf'}},
 {'first': '0', 'last': '9', 'property': {'tag': 'Control'}},
 {'first': '11', 'last': '12', 'property': {'tag': 'Control'}},
 {'first': '14', 'last': '31', 'property': {'tag': 'Control'}},
 {'first': '65039', 'last': '65039', 'property': {'tag': 'Extend'}},
 {'first': '127995', 'last': '127999', 'property': {'tag': 'Extend'}},
 {'first': '65', 'last': '90', 'property': {'tag': 'Other'}},
 {'first': '2325', 'last': '2325', 'property': {'tag': 'Other'}}]

GRAPHEME_INDIC = [{'first': '2325', 'last': '2361', 'property': {'tag': 'Consonant'}},
 {'first': '2366', 'last': '2367', 'property': {'tag': 'Extend'}},
 {'first': '2381', 'last': '2381', 'property': {'tag': 'Linker'}},
 {'first': '2304', 'last': '2306', 'property': {'tag': 'Extend'}}]

GRAPHEME_PICTOGRAPHIC = [{'first': '127744', 'last': '129791'},
 {'first': '9728', 'last': '10175'},
 {'first': '169', 'last': '169'},
 {'first': '174', 'last': '174'}]


GRAPHEME_RULES = {
    "reference": {"identity": "g", "revision": "1", "content_digest": "0" * 64},
    "component": {"unicode_version": "16.0.0", "uax29_revision": "45",
                  "cluster_profile": "C1-1-default-extended-grapheme-cluster-no-tailoring"},
    "table_sha256": "0" * 64,
    "sources": [],
    "properties": GRAPHEME_PROPERTIES,
    "indic_conjunct": GRAPHEME_INDIC,
    "extended_pictographic": GRAPHEME_PICTOGRAPHIC,
}


@pytest.mark.parametrize(("spelling", "canonical"), VECTORS["NUMBER_CANONICAL"])
def test_canonical_number_matches_lean_json_number_text(spelling, canonical):
    assert ts._canonical_number(spelling) == canonical


@pytest.mark.parametrize("spelling", VECTORS["NUMBER_INVALID"])
def test_canonical_number_rejects_spellings_outside_json_grammar(spelling):
    with pytest.raises(ValueError):
        ts._canonical_number(spelling)


@pytest.mark.parametrize("text", VECTORS["DECIMAL_ACCEPTED"])
def test_exact_decimal_accepts_lean_grammar(text):
    exact_json({"tag": "Decimal", "text": text}, "$")


@pytest.mark.parametrize("text", VECTORS["WHITESPACE_DECIMALS"] + VECTORS["DECIMAL_REJECTED"])
def test_exact_decimal_rejects_outside_lean_grammar(text):
    with pytest.raises(WireFailure) as failure:
        exact_json({"tag": "Decimal", "text": text}, "$")
    assert failure.value.kind == "Syntax"


@pytest.mark.parametrize(("text", "canonical"), VECTORS["WIRE_ESCAPE"])
def test_encode_diagnostic_string_escapes_match_lean_canonical_json(text, canonical):
    assert ts.encode_diagnostic(text) == canonical


@pytest.mark.parametrize(("text", "accepts", "fast"), VECTORS["TIMESTAMP"])
def test_timestamp_recognition_matches_lean(text, accepts, fast):
    rule = {"tag": "Timestamp", "value": {"allow_second_60": True, "minimum_year": "2000", "maximum_year": "2001",
                                          "rejectUtcYearOutsideRange": True}}
    assert sv.format_accepts(None, rule, text) is accepts
    assert sv.format_accepts_fast(None, rule, text) is fast


@pytest.mark.parametrize(("text", "accepts", "fast"), VECTORS["ABSOLUTE_URI"])
def test_absolute_uri_recognition_matches_lean(text, accepts, fast):
    rule = {"tag": "AbsoluteUri", "fields": {"max_bytes": None}}
    assert sv.format_accepts(None, rule, text) is accepts
    assert sv.format_accepts_fast(None, rule, text) is fast


@pytest.mark.parametrize(("text", "accepts", "fast"), VECTORS["LANGUAGE_TAG"])
def test_language_tag_recognition_matches_lean(text, accepts, fast):
    rule = {"tag": "LanguageTag", "fields": {"grandfathered": ["i-klingon"]}}
    assert sv.format_accepts(None, rule, text) is accepts
    assert sv.format_accepts_fast(None, rule, text) is fast


@pytest.mark.parametrize(("text", "accepts", "fast"), VECTORS["LABELS"])
def test_labels_recognition_matches_lean(text, accepts, fast):
    rule = {"tag": "Labels", "fields": {"separator": "/", "min_count": "1", "max_count": "2", "total_max": "5",
                                        "rule": {"tag": "Text"}}}
    assert sv.format_accepts(None, rule, text) is accepts
    assert sv.format_accepts_fast(None, rule, text) is fast


@pytest.mark.parametrize(("text", "accepts", "fast"), VECTORS["BOUNDED_GRAPHEMES"])
def test_bounded_graphemes_recognition_matches_lean(text, accepts, fast):
    rule = {"tag": "Bounded", "fields": {"unit": {"tag": "Graphemes"}, "maximum": "2", "rule": {"tag": "Text"}}}
    assert sv.format_accepts(GRAPHEME_RULES, rule, text) is accepts
    assert sv.format_accepts_fast(GRAPHEME_RULES, rule, text) is fast


@pytest.mark.parametrize(("policy", "text", "length"), VECTORS["BASE64"])
def test_base64_length_matches_lean(policy, text, length):
    name, optional, strict = policy
    bytes_policy = {"reference": {"identity": "p", "revision": "1", "content_digest": "0" * 64},
                    "padding_optional": optional, "alphabet": {"tag": name}, "strict_pad_bits": strict,
                    "wrapper": None}
    expected = None if length is None else int(length)
    assert sv.base64_length(bytes_policy, text) == expected


@pytest.mark.parametrize(("text", "length"), [(text, length) for text, length, _ in VECTORS["GRAPHEME"]])
def test_grapheme_length_matches_lean(text, length):
    assert sv.grapheme_length(GRAPHEME_RULES, text) == int(length)


@pytest.mark.parametrize(("text", "lower"), VECTORS["LOWER"])
def test_ascii_lower_matches_lean_to_lower(text, lower):
    assert sv._ascii_lower(text) == lower
