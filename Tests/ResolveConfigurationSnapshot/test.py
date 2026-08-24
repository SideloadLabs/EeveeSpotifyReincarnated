import hashlib
import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "layout/Library/Application Support/EeveeSpotify.bundle"


def read_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, offset
        shift += 7
        if shift >= 70:
            raise ValueError("invalid varint")
    raise ValueError("truncated varint")


def read_fields(data: bytes) -> list[tuple[int, int, object]]:
    fields = []
    offset = 0
    while offset < len(data):
        key, offset = read_varint(data, offset)
        number, wire_type = key >> 3, key & 7
        if number == 0:
            raise ValueError("invalid field number")
        if wire_type == 0:
            value, offset = read_varint(data, offset)
        elif wire_type == 1:
            value = data[offset : offset + 8]
            offset += 8
        elif wire_type == 2:
            length, offset = read_varint(data, offset)
            value = data[offset : offset + length]
            offset += length
        elif wire_type == 5:
            value = data[offset : offset + 4]
            offset += 4
        else:
            raise ValueError(f"unsupported wire type: {wire_type}")
        if offset > len(data):
            raise ValueError("truncated field")
        fields.append((number, wire_type, value))
    return fields


def inspect(path: pathlib.Path, expected_sha256: str, expected_assignments: int) -> None:
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected_sha256

    fields = read_fields(data)
    assignment_id = next(value for number, wire, value in fields if number == 1 and wire == 2)
    assignments = [value for number, wire, value in fields if number == 3 and wire == 2]

    assert len(assignment_id) == 44
    assert len(assignments) == expected_assignments

    for assignment in assignments:
        assignment_fields = read_fields(assignment)
        property_id = next(
            value for number, wire, value in assignment_fields if number == 1 and wire == 2
        )
        property_fields = read_fields(property_id)
        name = next(value for number, wire, value in property_fields if number == 2 and wire == 2)
        assert name

    print(f"{path.name}: {len(data)} bytes, {len(assignments)} assignments")


inspect(
    BUNDLE / "resolveconfiguration.bnk",
    "67739d75cf86e7d48dcddac0a0a36d5ccc1317f9ef3605b9e5fb0bdc0dd49dc5",
    873,
)
inspect(
    BUNDLE / "resolveconfiguration_9_1_76.bnk",
    "6b3ca5af9c686c6899386fa3900d8306608d2d2093b30964eaba06742123907f",
    1089,
)
