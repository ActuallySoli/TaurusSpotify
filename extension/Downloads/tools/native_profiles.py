"""Exact, independently inspected Spotify executable profiles; unknown UUIDs fail closed."""
from dataclasses import dataclass


@dataclass(frozen=True)
class NativeProfile:
    version: str
    uuid: bytes
    setter: int
    setter_cave: int
    setter_bytes: bytes
    request: int
    window: int
    provider: int
    provider_head: bytes
    mapping: int
    mapping_bytes: bytes
    key_cave: int
    dlsym: int
    dlsym_head: bytes
    success: int
    failure: int
    trace_caves: tuple
    manager_vtable: int


SPOTIFY_9190 = NativeProfile(
    '9.1.90', bytes.fromhex('fbce22c17e1b3e0d9be866ff9291943e'),
    0x101d1debc, 0x100023f00, bytes.fromhex('e6031eaa8f3ef495fe0306aafd7b11a9'),
    0x103594f60, 0x103594f54, 0x1083de7b0,
    bytes.fromhex('ff0306d1fc6f12a9fa6713a9f85f14a9f65715a9f44f16a9fd7b17a9fdc30591f50305aaf40300aaf70308aa08404239'),
    0x1083de894, bytes.fromhex('f60301aa5f080071480080520815881a5f0000711c159f1a'),
    0x100023d00, 0x109b65b68, bytes.fromhex('70840190106a42f900021fd6'),
    0x106231e70, 0x100893730, (0x100023700, 0x100023900, 0x100023b00),
    0x10ca326c8)

SPOTIFY_9194 = NativeProfile(
    '9.1.94', bytes.fromhex('1dfddfa139c03735b9a5fdfa475f4700'),
    0x1094a9f28, 0x10cbe6f00, bytes.fromhex('e6031eaa64be3794fe0306aafd7b11a9'),
    0x10948fe10, 0x10948fe04, 0x1092f6e40,
    bytes.fromhex('ff0306d1fc6f12a9fa6713a9f85f14a9f65715a9f44f16a9fd7b17a9fdc30591f50305aaf40300aafc0308aa08404239'),
    0x1092f6f24, bytes.fromhex('f60301aa5f080071480080520815881a5f00007113159f1a'),
    0x10cbe6d00, 0x10a3db714, bytes.fromhex('f09001d0100640f900021fd6'),
    0x1094900d8, 0x109490160, (0x10cbe6700, 0x10cbe6900, 0x10cbe6b00),
    0x10d46b910)

PROFILES = (SPOTIFY_9190, SPOTIFY_9194)


def profile_for_uuid(uuid):
    for profile in PROFILES:
        if uuid == profile.uuid:
            return profile
    raise ValueError('Unsupported Spotify UUID')


def conditional_header(render):
    return '#if SAP_SPOTIFY_9194\n' + render(SPOTIFY_9194) + '#else\n' + render(SPOTIFY_9190) + '#endif\n'
