"""Install a guarded, runtime-selectable offline key-request argument.

Only the verified Spotify 9.1.90 caller is redirected. A fixed build-time
trampoline saves its live registers, reads a C atomic in SpotifyAudioProbe,
then executes the original virtual call. No executable page is changed later.
"""
import struct
import subprocess
import tempfile
from pathlib import Path

from patch_native_restrictions import UUID, branch, layout, verify_padding
from native_profiles import SPOTIFY_9190, conditional_header, profile_for_uuid

PREFERRED = 0x100000000
CALL_SITE = 0x103594F60
WINDOW = 0x103594F54
ORIGINAL = bytes.fromhex('e4e30191e5c30091e00317aa2200805220013fd6a18301d1')
PROVIDER = 0x1083DE7B0
PROVIDER_HEAD = bytes.fromhex('ff0306d1fc6f12a9fa6713a9f85f14a9f65715a9f44f16a9fd7b17a9fdc30591f50305aaf40300aaf70308aa08404239')
MAPPING = 0x1083DE894
MAPPING_BYTES = bytes.fromhex('f60301aa5f080071480080520815881a5f0000711c159f1a')
CAVE = 0x100023D00
DLSYM_STUB = 0x109B65B68
DLSYM_STUB_HEAD = bytes.fromhex('70840190106a42f900021fd6')
SELECTOR_NAME = b'SAPCurrentKeyRequestMode\0'
ASSEMBLY = Path(__file__).with_name('key_mode_trampoline.S')


def _compiled_template():
    with tempfile.TemporaryDirectory(prefix='pixie-key-thunk-') as directory:
        obj = Path(directory) / 'thunk.o'
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'clang', '-c', '-arch', 'arm64', '-target', 'arm64-apple-ios15.0',
                        '-isysroot', sdk, str(ASSEMBLY), '-o', str(obj)], check=True)
        data = obj.read_bytes()
    cursor = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, length = struct.unpack_from('<II', data, cursor)
        if command == 0x19:
            section_count = struct.unpack_from('<I', data, cursor + 64)[0]
            for index in range(section_count):
                section = cursor + 72 + index * 80
                if data[section:section + 16].split(b'\0')[0] != b'__text':
                    continue
                size = struct.unpack_from('<Q', data, section + 40)[0]
                offset = struct.unpack_from('<I', data, section + 48)[0]
                relocations = struct.unpack_from('<I', data, section + 60)[0]
                if relocations:
                    raise ValueError('Key trampoline contains unresolved relocations')
                blob = data[offset:offset + size]
                if not blob.endswith(SELECTOR_NAME) or len(blob) > 0x200:
                    raise ValueError('Unexpected key trampoline template')
                return blob
        cursor += length
    raise ValueError('Key trampoline text section absent')


def trampoline(profile=SPOTIFY_9190):
    out = bytearray(_compiled_template())
    words = [struct.unpack_from('<I', out, i)[0] for i in range(0, len(out) & ~3, 4)]
    adrp = words.index(0x90000010) * 4
    if words[adrp // 4 + 1] != 0x91000210:
        raise ValueError('dlsym call template differs')
    page_delta = (profile.dlsym >> 12) - ((profile.key_cave + adrp) >> 12)
    if not -(1 << 20) <= page_delta < (1 << 20):
        raise ValueError('dlsym page out of adrp range')
    struct.pack_into('<I', out, adrp,
                     0x90000010 | ((page_delta & 3) << 29) | (((page_delta >> 2) & 0x7FFFF) << 5))
    struct.pack_into('<I', out, adrp + 4, 0x91000210 | ((profile.dlsym & 0xFFF) << 10))
    # The final self-branch is unique; return to the unmodified blr x9.
    terminator = out.index(struct.pack('<I', 0x14000000), 0x70)
    if terminator + 4 != out.index(SELECTOR_NAME):
        raise ValueError('Key trampoline terminator differs')
    struct.pack_into('<I', out, terminator, branch(profile.key_cave + terminator, profile.request + 4))
    return bytes(out)


def _offset(segments, address, size):
    for name, vm, _, fileoff, filesize, protection in segments:
        if name == b'__TEXT' and vm <= address and address + size <= vm + filesize and protection & 5 == 5:
            return fileoff + address - vm
    raise ValueError('Expected executable file-backed text')


def _verify_dlsym_binding(data, profile=SPOTIFY_9190):
    dlsym_stub = profile.dlsym
    cursor = 32
    symtab = dysym = stubs = None
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, length = struct.unpack_from('<II', data, cursor)
        if command == 2:
            symtab = struct.unpack_from('<IIII', data, cursor + 8)
        elif command == 0xB:
            dysym = struct.unpack_from('<IIIIIIIIIIIIIIIIII', data, cursor + 8)
        elif command == 0x19:
            for index in range(struct.unpack_from('<I', data, cursor + 64)[0]):
                section = cursor + 72 + index * 80
                if data[section:section + 16].split(b'\0')[0] == b'__stubs':
                    address, size = struct.unpack_from('<QQ', data, section + 32)
                    first, width = struct.unpack_from('<II', data, section + 68)
                    if address <= dlsym_stub < address + size:
                        stubs = (address, first, width)
        cursor += length
    if not symtab or not dysym or not stubs:
        raise ValueError('Cannot verify dlsym import binding')
    address, first, width = stubs
    if width != 12 or (dlsym_stub - address) % width:
        raise ValueError('dlsym stub layout changed')
    index = struct.unpack_from('<I', data, dysym[12] + 4 * (first + (dlsym_stub - address) // width))[0]
    if index >= symtab[1]:
        raise ValueError('dlsym indirect symbol index invalid')
    string = symtab[2] + struct.unpack_from('<I', data, symtab[0] + 16 * index)[0]
    if data[string:data.index(b'\0', string)] != b'_dlsym':
        raise ValueError('Expected dlsym stub is bound to another symbol')


def patch(data, runtime_selectable=True):
    commands_end, first_section, segments, uuid = layout(data)
    profile = profile_for_uuid(uuid)
    _verify_dlsym_binding(data, profile)
    for address, expected in ((profile.window, ORIGINAL), (profile.provider, profile.provider_head),
                              (profile.mapping, profile.mapping_bytes), (profile.dlsym, profile.dlsym_head)):
        at = _offset(segments, address, len(expected))
        if data[at:at + len(expected)] != expected:
            raise ValueError(f'Key requester code differs at {address:#x}')
    call = _offset(segments, profile.request, 4)
    if not runtime_selectable:
        out=bytearray(data)
        struct.pack_into('<I',out,call,0x52800002)
        return bytes(out), {'caller':hex(profile.request),'original_mode':1,'initial_mode':0,
            'runtime_selectable':False,'implementation':'direct mov w2, #0; recovery rollback',
            'native_callbacks_and_persistence_unchanged':True}
    stub = trampoline(profile)
    target = _offset(segments, profile.key_cave, len(stub))
    verify_padding(data, target, len(stub))
    out = bytearray(data)
    out[target:target + len(stub)] = stub
    struct.pack_into('<I', out, call, branch(profile.request, profile.key_cave))
    return bytes(out), {
        'caller': hex(profile.request), 'trampoline': hex(profile.key_cave), 'trampoline_bytes': len(stub),
        'provider': hex(profile.provider), 'original_mode': 1, 'initial_mode': 0,
        'runtime_selectable': True, 'getter': SELECTOR_NAME[:-1].decode(),
        'native_callbacks_and_persistence_unchanged': True,
    }


def key_header(profile=None):
    if profile is None:
        return conditional_header(key_header)
    stub = trampoline(profile)
    as_bytes = lambda value: ','.join(f'0x{b:02x}' for b in value)
    return ('// Generated by tools/patch_key_request_mode.py; checked by the build.\n'
            '#pragma once\n#include <stdint.h>\n'
            f'static const uintptr_t SAPKeyModeCaveOffset=0x{profile.key_cave - PREFERRED:x};\n'
            f'static const uint8_t SAPKeyModeCallerHead[]={{{as_bytes(struct.pack("<I", branch(profile.request, profile.key_cave)))}}};\n'
            f'static const uint8_t SAPKeyModeTrampoline[]={{{as_bytes(stub)}}};\n')
