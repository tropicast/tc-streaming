import os
from pathlib import Path
import secrets
import sys
import xml.etree.ElementTree as ET


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


def main():
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
    config = Path("/run/icecast/icecast.xml")
    tree.write(config, encoding="utf-8", xml_declaration=True)
    os.chmod(config, 0o600)
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
