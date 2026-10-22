"""LAN address discovery, self-signed TLS certificate and QR code helpers."""

from __future__ import annotations

import datetime as dt
import ipaddress
import logging
import socket
import ssl
from pathlib import Path

log = logging.getLogger("net")


def _ip_rank(ip: str) -> int:
    """Lower is more likely the Wi-Fi/LAN address a phone can reach."""
    parts = [int(p) for p in ip.split(".")]
    if parts[0] == 127 or (parts[0] == 169 and parts[1] == 254):
        return 9
    if parts[0] == 192 and parts[1] == 168:
        rank = 0
    elif parts[0] == 10:
        rank = 1
    elif parts[0] == 172 and 16 <= parts[1] <= 31:
        rank = 4  # usually Docker / WSL / Hyper-V / TUN proxies
    elif parts[0] == 100 and 64 <= parts[1] <= 127:
        rank = 5  # CGNAT range: Tailscale and similar VPNs
    else:
        rank = 3
    if parts[3] == 1:
        rank += 2  # x.x.x.1 is typically the host side of a virtual adapter (VMware, Hyper-V)
    return rank


def lan_ips() -> list[str]:
    """Candidate IPv4 addresses a phone on the same Wi-Fi could reach, best first."""
    found: list[str] = []
    for target in ("8.8.8.8", "10.255.255.255"):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect((target, 80))  # UDP connect: picks a route, sends nothing
            found.append(s.getsockname()[0])
        except OSError:
            pass
        finally:
            s.close()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.append(str(info[4][0]))
    except OSError:
        pass
    uniq = [ip for i, ip in enumerate(found) if ip not in found[:i] and _ip_rank(ip) < 9]
    uniq.sort(key=_ip_rank)  # stable: keeps the default-route address first within a rank
    return uniq or ["127.0.0.1"]


def lan_ip() -> str:
    return lan_ips()[0]


def _cert_covers(cert_path: Path, ips: list[str]) -> bool:
    from cryptography import x509

    try:
        cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        have = {str(ip) for ip in san.get_values_for_type(x509.IPAddress)}
        not_expired = cert.not_valid_after_utc > dt.datetime.now(dt.UTC) + dt.timedelta(days=7)
        return not_expired and all(ip in have for ip in ips)
    except Exception:  # noqa: BLE001 - any parse problem means regenerate
        return False


def ensure_cert(cert_dir: Path, ips: list[str]) -> tuple[Path, Path]:
    """Create (or reuse) a self-signed certificate valid for the given IPs and localhost."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    cert_dir.mkdir(parents=True, exist_ok=True)
    cert_path = cert_dir / "cert.pem"
    key_path = cert_dir / "key.pem"
    if cert_path.exists() and key_path.exists() and _cert_covers(cert_path, ips):
        return cert_path, key_path

    log.info("generating self-signed certificate for %s", ", ".join(ips))
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Regina Sports Hub")])
    now = dt.datetime.now(dt.UTC)
    san = [x509.DNSName("localhost")] + [x509.IPAddress(ipaddress.ip_address(ip)) for ip in sorted(set(ips + ["127.0.0.1"]))]
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(days=825))
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_path.write_bytes(
        key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    )
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return cert_path, key_path


def ssl_context(cert_path: Path, key_path: Path) -> ssl.SSLContext:
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.load_cert_chain(str(cert_path), str(key_path))
    return ctx


def qr_rows(text: str) -> list[str]:
    """QR matrix as strings of '1' (dark) / '0' (light), including a 2-module quiet zone."""
    import qrcode

    qr = qrcode.QRCode(border=2, error_correction=qrcode.constants.ERROR_CORRECT_M)
    qr.add_data(text)
    qr.make(fit=True)
    return ["".join("1" if cell else "0" for cell in row) for row in qr.get_matrix()]


def qr_ascii(text: str) -> str:
    """Terminal-friendly QR using half-block characters (two rows per line)."""
    rows = qr_rows(text)
    lines = []
    for y in range(0, len(rows), 2):
        top = rows[y]
        bot = rows[y + 1] if y + 1 < len(rows) else "0" * len(top)
        line = []
        for a, b in zip(top, bot, strict=False):
            # Dark modules are drawn as spaces on a light background so phone cameras read it.
            if a == "1" and b == "1":
                line.append(" ")
            elif a == "1":
                line.append("▄")
            elif b == "1":
                line.append("▀")
            else:
                line.append("█")
        lines.append("".join(line))
    return "\n".join(lines)
