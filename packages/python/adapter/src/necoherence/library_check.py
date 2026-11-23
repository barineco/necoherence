# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from enum import Enum
from typing import TypeAlias


class ProfilePredicate(Enum):
    PR01 = "PR01"
    PR02 = "PR02"
    PR03 = "PR03"
    PR04 = "PR04"
    PR05 = "PR05"
    PR06 = "PR06"
    PR07 = "PR07"
    PR08 = "PR08"
    PR09 = "PR09"
    PR10 = "PR10"
    PR11 = "PR11"
    PR12 = "PR12"
    PR13 = "PR13"
    PR14 = "PR14"
    PR15 = "PR15"
    PR16 = "PR16"


class LibraryPredicate(Enum):
    LB01 = "LB01"
    LB02 = "LB02"
    LB03 = "LB03"
    LB04 = "LB04"
    LB05 = "LB05"
    LB06 = "LB06"
    LB07 = "LB07"
    LB08 = "LB08"
    LB09 = "LB09"
    LB10 = "LB10"
    LB11 = "LB11"
    LB12 = "LB12"
    LB13 = "LB13"
    LB14 = "LB14"
    LB15 = "LB15"
    LB16 = "LB16"
    LB17 = "LB17"
    LB18 = "LB18"
    LB19 = "LB19"


@dataclass(frozen=True, slots=True)
class ProfileRef:
    identity: str
    revision: str
    content_digest: str


@dataclass(frozen=True, slots=True)
class ProfileFailure:
    reference: ProfileRef
    predicate: ProfilePredicate
    location: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class LibraryFailure:
    reference: str
    predicate: LibraryPredicate
    location: tuple[str, ...]


LibraryCheckFailure: TypeAlias = ProfileFailure | LibraryFailure


def library_check_failure(
    reference: Mapping[str, str] | str, predicate: str, location: Iterable[str]
) -> LibraryCheckFailure:
    """Select the variant by the predicate family: PR belongs to the profile, LB to the library declarations."""
    steps = tuple(location)
    if predicate.startswith("PR"):
        if not isinstance(reference, Mapping):
            raise ValueError("profile failure needs the profile reference")
        return ProfileFailure(
            ProfileRef(reference["identity"], reference["revision"], reference["content_digest"]),
            ProfilePredicate(predicate),
            steps,
        )
    if not isinstance(reference, str):
        raise ValueError("library failure needs the library identity")
    return LibraryFailure(reference, LibraryPredicate(predicate), steps)
