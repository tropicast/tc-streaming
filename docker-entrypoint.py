import copy
import json
import os
from pathlib import Path
import re
import secrets
import signal
import sys
import xml.etree.ElementTree as ET

RUNTIME_CONFIG = Path("/run/icecast/icecast.xml")
# Station limits (#8), written by the deploy from the control plane's
# desired state. Optional: without it every station gets the default cap.
STATIONS_FILE = Path(os.environ.get("ICECAST_STATIONS_FILE", "/etc/icecast/stations.json"))
STATION_ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")
FORMATS = ("mp3", "opus")
# Directory metadata (tc-dashboard#13): mount settings, and the "icy" v2 headers
# directories such as RadioBrowser read from the stream to refresh a listing.
DIRECTORY_TEXT = {"name": 400, "description": 512, "genre": 256}
DIRECTORY_URLS = ("homepage", "logo", "main_stream_url")
COUNTRY = re.compile(r"^[A-Z]{2}$")
LANGUAGES = re.compile(r"^[a-z]{2,3}(,[a-z]{2,3})*$")


def password(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"{name} must be set to a nonempty password")
    if any(
        not (
            ord(char) in (0x09, 0x0A, 0x0D)
            or 0x20 <= ord(char) <= 0xD7FF
            or 0xE000 <= ord(char) <= 0xFFFD
            or 0x10000 <= ord(char) <= 0x10FFFF
        )
        for char in value
    ):
        sys.exit(f"{name} contains characters that cannot be stored in XML")
    return value


def required(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"{name} must be set")
    return value


def configure_source_auth(tree):
    role = tree.find("./mount[@type='default']/authentication/role[@type='url']")
    if role is None:
        sys.exit("Icecast configuration is missing the source auth role")
    url = required("ICECAST_SOURCE_AUTH_URL")
    if not url.startswith(("http://", "https://")) or "@" in url:
        sys.exit("ICECAST_SOURCE_AUTH_URL must be an http(s) URL without credentials")
    values = {
        "client_add": url,
        "username": required("ICECAST_SOURCE_AUTH_USER"),
        "password": password("ICECAST_SOURCE_AUTH_PASSWORD"),
    }
    for name, value in values.items():
        option = role.find(f"./option[@name='{name}']")
        if option is None:
            sys.exit(f"Source auth role is missing option {name}")
        option.set("value", value)


def load_stations():
    """Validated station limits, or an empty set when the file is absent."""
    if not STATIONS_FILE.exists():
        return {"default": {}, "stations": {}}
    try:
        data = json.loads(STATIONS_FILE.read_text() or "{}")
    except json.JSONDecodeError as error:
        sys.exit(f"{STATIONS_FILE} is not valid JSON: {error}")
    default = data.get("default", {})
    stations = data.get("stations", {})
    if not isinstance(default, dict) or not isinstance(stations, dict):
        sys.exit(f"{STATIONS_FILE}: 'default' and 'stations' must be objects")
    for station_id, limits in stations.items():
        if not STATION_ID.match(station_id):
            sys.exit(f"{STATIONS_FILE}: invalid station id {station_id!r}")
        listeners = limits.get("max_listeners")
        if not isinstance(listeners, int) or listeners < 0:
            sys.exit(f"{STATIONS_FILE}: station {station_id} needs an integer max_listeners >= 0")
        for fmt in limits.get("formats", FORMATS):
            if fmt not in FORMATS:
                sys.exit(f"{STATIONS_FILE}: station {station_id} has unknown format {fmt!r}")
        if "directory" in limits:
            check_directory(station_id, limits["directory"])
    return {"default": default, "stations": stations}


def check_directory(station_id, directory):
    """Directory metadata is public text and URLs: reject anything else."""
    where = f"{STATIONS_FILE}: station {station_id} directory"
    if not isinstance(directory, dict) or not isinstance(directory.get("listed"), bool):
        sys.exit(f"{where} needs a boolean 'listed'")
    for key, value in directory.items():
        if key == "listed":
            continue
        if not isinstance(value, str) or any(ord(c) < 32 for c in value):
            sys.exit(f"{where}: {key} must be text without control characters")
        if key in DIRECTORY_TEXT:
            if len(value) > DIRECTORY_TEXT[key]:
                sys.exit(f"{where}: {key} is longer than {DIRECTORY_TEXT[key]}")
        elif key in DIRECTORY_URLS:
            if not re.match(r"^https?://[^\s]+$", value) or len(value) > 512:
                sys.exit(f"{where}: {key} must be an http(s) URL")
        elif key == "country_code":
            if not COUNTRY.match(value):
                sys.exit(f"{where}: country_code must be two capital letters")
        elif key == "language_codes":
            if not LANGUAGES.match(value):
                sys.exit(f"{where}: language_codes must be comma-separated ISO 639 codes")
        else:
            sys.exit(f"{where}: unknown key {key!r}")


def directory_settings(mount, directory):
    """Stream identity and directory headers of a listed station.

    Listed: icy-index-metadata 1 asks directories to update the listing from
    these headers. They come before any the source sends, and parsers read
    the first one, so the control plane's values win; <stream-name> also
    replaces the name a source sends, so a repeated icy-name matches.
    Delisted (listed false): icy-do-not-index 1 asks directories to drop it.
    """
    headers = {"icy-version": "2", "icy-index-metadata": "1"}
    if directory["listed"]:
        if directory.get("name"):
            ET.SubElement(mount, "stream-name").text = directory["name"]
        for key, header in (("name", "icy-name"), ("description", "icy-description"), ("genre", "icy-genre"),
                            ("homepage", "icy-url"), ("country_code", "icy-country-code"),
                            ("language_codes", "icy-language-codes"), ("logo", "icy-logo"),
                            ("main_stream_url", "icy-main-stream-url")):
            if directory.get(key):
                headers[header] = directory[key]
    else:
        headers["icy-do-not-index"] = "1"
    http_headers = ET.SubElement(mount, "http-headers")
    for name, value in headers.items():
        ET.SubElement(http_headers, "header", {"name": name, "value": value})


def apply_station_limits(tree, stations):
    """Rewrite the per-station <mount type="normal"> blocks.

    Each mount copies the default mount's source authentication, because a
    normal mount does not inherit it. Stations without an entry use the
    default mount and its cap.
    """
    root = tree.getroot()
    default_mount = root.find("./mount[@type='default']")
    if default_mount is None:
        sys.exit("Icecast configuration is missing the default mount")
    for mount in root.findall("./mount[@type='normal']"):
        if (mount.findtext("mount-name") or "").startswith("/stations/"):
            root.remove(mount)

    default_cap = stations["default"].get("max_listeners")
    cap = default_mount.find("max-listeners")
    if default_cap is not None:
        if cap is None:
            cap = ET.SubElement(default_mount, "max-listeners")
        cap.text = str(int(default_cap))

    auth = default_mount.find("authentication")
    position = list(root).index(default_mount)
    for station_id, limits in sorted(stations["stations"].items()):
        for fmt in limits.get("formats", FORMATS):
            mount = ET.Element("mount", {"type": "normal"})
            ET.SubElement(mount, "mount-name").text = f"/stations/{station_id}/live.{fmt}"
            ET.SubElement(mount, "max-listeners").text = str(limits["max_listeners"])
            if "directory" in limits:
                directory_settings(mount, limits["directory"])
            mount.append(copy.deepcopy(auth))
            root.insert(position, mount)
            position += 1


def write_config(tree):
    tmp = RUNTIME_CONFIG.with_suffix(".tmp")
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, RUNTIME_CONFIG)


def reload_stations():
    """Apply stations.json to the running Icecast without a restart.

    Re-renders the station mounts in the runtime config (which already holds
    the secrets) and sends SIGHUP to Icecast (PID 1). Live listeners and
    sources stay connected.
    """
    os.umask(0o077)
    tree = ET.parse(RUNTIME_CONFIG)
    stations = load_stations()
    apply_station_limits(tree, stations)
    write_config(tree)
    os.kill(1, signal.SIGHUP)
    print(f"Applied limits for {len(stations['stations'])} stations; Icecast reloaded.")


def main():
    if sys.argv[1:] == ["reload-stations"]:
        reload_stations()
        return
    os.umask(0o077)
    credentials = {
        "source-password": password("ICECAST_SOURCE_PASSWORD"),
        "admin-password": password("ICECAST_ADMIN_PASSWORD"),
        "relay-password": (
            password("ICECAST_RELAY_PASSWORD")
            if "ICECAST_RELAY_PASSWORD" in os.environ
            else secrets.token_hex(24)
        ),
    }
    tree = ET.parse("/etc/icecast/icecast.xml")
    hostname = os.environ.get("ICECAST_HOSTNAME")
    if hostname:
        tree.find("./hostname").text = hostname
    for tag, value in credentials.items():
        element = tree.find(f"./authentication/{tag}")
        if element is None:
            sys.exit(f"Icecast configuration is missing authentication/{tag}")
        element.text = value
    configure_source_auth(tree)
    apply_station_limits(tree, load_stations())
    write_config(tree)
    config = RUNTIME_CONFIG
    for name in (
        "ICECAST_SOURCE_PASSWORD",
        "ICECAST_ADMIN_PASSWORD",
        "ICECAST_RELAY_PASSWORD",
        "ICECAST_HOSTNAME",
        "ICECAST_SOURCE_AUTH_URL",
        "ICECAST_SOURCE_AUTH_USER",
        "ICECAST_SOURCE_AUTH_PASSWORD",
    ):
        os.environ.pop(name, None)
    os.execv("/usr/local/bin/icecast", ["icecast", "-c", str(config)])


if __name__ == "__main__":
    main()
