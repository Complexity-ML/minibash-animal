#!/usr/bin/env python3
import ctypes
import math
import struct
import sys
import xml.etree.ElementTree as ET


glib = ctypes.CDLL("libglib-2.0.so.0")

glib.g_variant_new_string.argtypes = [ctypes.c_char_p]
glib.g_variant_new_string.restype = ctypes.c_void_p
glib.g_variant_new_double.argtypes = [ctypes.c_double]
glib.g_variant_new_double.restype = ctypes.c_void_p
glib.g_variant_new_uint16.argtypes = [ctypes.c_uint16]
glib.g_variant_new_uint16.restype = ctypes.c_void_p
glib.g_variant_new_byte.argtypes = [ctypes.c_ubyte]
glib.g_variant_new_byte.restype = ctypes.c_void_p
glib.g_variant_new_uint64.argtypes = [ctypes.c_uint64]
glib.g_variant_new_uint64.restype = ctypes.c_void_p
glib.g_variant_new_tuple.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t]
glib.g_variant_new_tuple.restype = ctypes.c_void_p
glib.g_variant_new_dict_entry.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
glib.g_variant_new_dict_entry.restype = ctypes.c_void_p
glib.g_variant_builder_new.argtypes = [ctypes.c_char_p]
glib.g_variant_builder_new.restype = ctypes.c_void_p
glib.g_variant_builder_add_value.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
glib.g_variant_builder_add_value.restype = None
glib.g_variant_builder_end.argtypes = [ctypes.c_void_p]
glib.g_variant_builder_end.restype = ctypes.c_void_p
glib.g_variant_ref_sink.argtypes = [ctypes.c_void_p]
glib.g_variant_ref_sink.restype = ctypes.c_void_p
glib.g_variant_get_data_as_bytes.argtypes = [ctypes.c_void_p]
glib.g_variant_get_data_as_bytes.restype = ctypes.c_void_p
glib.g_bytes_get_data.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
glib.g_bytes_get_data.restype = ctypes.c_void_p

INVALID_IDX = 0xFFFF
FILETYPE_MAGIC = 0x5747687442443130

levels = {
    "gweather": 0,
    "region": 1,
    "country": 2,
    "state": 3,
    "city": 4,
    "location": 5,
    "named-timezone": 7,
}


def v_string(value):
    return glib.g_variant_new_string((value or "").encode())


def v_tuple(items):
    array = (ctypes.c_void_p * len(items))(*items)
    return glib.g_variant_new_tuple(array, len(items))


def v_str_array(items):
    builder = glib.g_variant_builder_new(b"as")
    for item in items:
        glib.g_variant_builder_add_value(builder, v_string(item))
    return glib.g_variant_builder_end(builder)


def v_uint16_array(items):
    builder = glib.g_variant_builder_new(b"aq")
    for item in items:
        glib.g_variant_builder_add_value(builder, glib.g_variant_new_uint16(item))
    return glib.g_variant_builder_end(builder)


def v_dict_sq(items):
    builder = glib.g_variant_builder_new(b"a{sq}")
    for key, value in items:
        entry = glib.g_variant_new_dict_entry(v_string(key), glib.g_variant_new_uint16(value))
        glib.g_variant_builder_add_value(builder, entry)
    return glib.g_variant_builder_end(builder)


def get_name(elem):
    name = elem.find("_name")
    if name is None:
        name = elem.find("name")
        msgctx = ""
    else:
        msgctx = name.get("msgctx", default="")
    if name is None:
        return "", ""
    return name.text or "", msgctx


def get_coordinates(elem):
    coordinates = elem.findtext("coordinates")
    if coordinates:
        return tuple(float(c) * math.pi / 180.0 for c in coordinates.split())
    return float("NaN"), float("NaN")


def calc_distance(loc_a, loc_b):
    radius = 6372.795
    c_a = get_coordinates(loc_a)
    c_b = get_coordinates(loc_b)
    if c_a == c_b:
        return 0
    return math.acos(
        math.cos(c_a[0]) * math.cos(c_b[0]) * math.cos(c_a[1] - c_b[1])
        + math.sin(c_a[0]) * math.sin(c_b[0])
    ) * radius


tree = ET.parse(sys.argv[1])
root = tree.getroot()
assert root.tag == "gweather"
assert root.attrib["format"] == "1.0"

locations = []
timezones = []
loc_by_metar = []
loc_by_country = []
all_ccodes = set()
parent_map = {child: parent for parent in root.iter() for child in parent}


def tz_variant(tz_new):
    obsoletes = [item.text or "" for item in tz_new.findall("obsoletes")]
    return v_tuple([v_tuple([v_string(x) for x in get_name(tz_new)]), v_str_array(obsoletes)])


def find_children(loc):
    children = []
    for child in loc.find("."):
        if child.tag in levels:
            children.append(locations.index(child))
    return children


def find_timezones(loc):
    zones = []
    for tz_list in loc.findall("timezones"):
        for tz_ in tz_list.findall("timezone"):
            zones.append(timezones.index(tz_))
    return zones


def loc_variant(loc):
    children = find_children(loc)
    children.sort(key=lambda c: calc_distance(loc, locations[c]))

    zones = find_timezones(loc)
    coordinate = get_coordinates(loc)

    tz_hint = loc.findtext("tz-hint")
    if tz_hint:
        for index, tz_ in enumerate(timezones):
            if tz_.get("id") == tz_hint:
                tz_hint = index
                break
        else:
            raise AssertionError("unresolved tz-hint")

    parent = parent_map.get(loc)
    try:
        parent_idx = locations.index(parent)
    except ValueError:
        parent_idx = None

    nearest_idx = None
    if loc.tag == "city" and not children:
        nearest = None
        nearest_dist = -1
        for sibling in parent.findall("location"):
            dist = calc_distance(loc, sibling)
            if dist > 100:
                continue
            if nearest is None or dist < nearest_dist:
                nearest = sibling
                nearest_dist = dist
        if nearest is not None:
            nearest_idx = locations.index(nearest)

    return v_tuple(
        [
            v_tuple([v_string(x) for x in get_name(loc)]),
            v_string(loc.findtext("zone", default="")),
            v_string(loc.findtext("radar", default="")),
            v_tuple([glib.g_variant_new_double(coordinate[0]), glib.g_variant_new_double(coordinate[1])]),
            v_string(loc.findtext("iso-code", default="")),
            v_string(loc.findtext("code", default="")),
            glib.g_variant_new_uint16(tz_hint if tz_hint is not None else INVALID_IDX),
            glib.g_variant_new_byte(levels[loc.tag]),
            glib.g_variant_new_uint16(nearest_idx if nearest_idx is not None else INVALID_IDX),
            glib.g_variant_new_uint16(parent_idx if parent_idx is not None else INVALID_IDX),
            v_uint16_array(children),
            v_uint16_array(zones),
        ]
    )


locations.append(root)
for location in root.iter("named-timezone"):
    locations.append(location)
    loc_by_metar.append(location)
    assert location.findtext("code") is not None
for location in root.iter("region"):
    locations.append(location)
for location in root.iter("country"):
    locations.append(location)
    loc_by_country.append(location)
    code = location.findtext("iso-code")
    assert code is not None
    assert code not in all_ccodes
    all_ccodes.add(code)
for location in root.iter("state"):
    locations.append(location)
for location in root.iter("city"):
    locations.append(location)
for location in root.iter("location"):
    locations.append(location)
    loc_by_metar.append(location)
    assert location.findtext("code") is not None

for timezone in root.iter("timezone"):
    timezones.append(timezone)
    assert timezone.get("id") is not None

timezones.sort(key=lambda tz: tz.get("id"))
loc_by_country.sort(key=lambda loc: loc.findtext("iso-code"))
loc_by_metar.sort(key=lambda loc: loc.findtext("code"))

timezones_builder = glib.g_variant_builder_new(b"a{s((ss)as)}")
for tz in timezones:
    entry = glib.g_variant_new_dict_entry(v_string(tz.get("id")), tz_variant(tz))
    glib.g_variant_builder_add_value(timezones_builder, entry)

locations_builder = glib.g_variant_builder_new(b"a((ss)ss(dd)ssqyqqaqaq)")
for loc in locations:
    glib.g_variant_builder_add_value(locations_builder, loc_variant(loc))

res = v_tuple(
    [
        glib.g_variant_new_uint64(FILETYPE_MAGIC),
        v_dict_sq([(loc.findtext("iso-code"), locations.index(loc)) for loc in loc_by_country]),
        v_dict_sq([(loc.findtext("code"), locations.index(loc)) for loc in loc_by_metar]),
        glib.g_variant_builder_end(timezones_builder),
        glib.g_variant_builder_end(locations_builder),
    ]
)

if struct.pack("h", 0x01)[0]:
    pass

res = glib.g_variant_ref_sink(res)
size = ctypes.c_size_t()
bytes_obj = glib.g_variant_get_data_as_bytes(res)
data_ptr = glib.g_bytes_get_data(bytes_obj, ctypes.byref(size))
with open(sys.argv[2], "wb") as out:
    out.write(ctypes.string_at(data_ptr, size.value))
